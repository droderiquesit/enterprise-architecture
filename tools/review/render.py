"""Markdown for the PR summary thread and inline finding threads. Hidden HTML-comment markers identify the bot's
threads so they are updated in place (summary) or deduplicated/resolved by fingerprint (findings)."""

from __future__ import annotations

import re

from .model import Finding, ReviewResult

SUMMARY_MARKER = "<!-- eh-review:summary -->"
FINDING_MARKER_RE = re.compile(r"<!-- eh-review:finding fp=([0-9a-f]{16}) -->")
STATE_RE = re.compile(r"<!-- eh-review:state (?P<body>[^>]*) -->")
ICON = {"critical": "[CRITICAL]", "high": "[HIGH]", "medium": "[MEDIUM]", "low": "[LOW]", "info": "[INFO]"}
OUTCOME_TEXT = {
    "approve": "Approved by policy (vote 10)",
    "approve-with-suggestions": "Approved with suggestions (vote 5)",
    "no-vote": "No vote - human review required",
    "wait-for-author": "Waiting for author (vote -5)",
    "reject": "Rejected (vote -10)",
}


def _esc(text: str | None) -> str:
    """Neutralise markdown/HTML in untrusted text (file names, AI messages) so it cannot forge markers or links."""
    if not text:
        return ""
    return (text.replace("<", "&lt;").replace(">", "&gt;").replace("[", "&#91;").replace("]", "&#93;").replace("`", "'").replace("\r", " "))[:1200]


def state_marker(iteration: int | None, head: str, input_hash: str) -> str:
    return f"<!-- eh-review:state iteration={iteration or 0} head={head[:40]} inputs={input_hash} -->"


def parse_state(content: str) -> dict:
    m = STATE_RE.search(content or "")
    if not m:
        return {}
    return dict(kv.split("=", 1) for kv in m.group("body").split() if "=" in kv)


def summary(result: ReviewResult, iteration: int | None = None) -> str:
    d = result.decision
    lines = [
        SUMMARY_MARKER,
        state_marker(iteration, result.head, result.input_hash),
        "",
        f"## eh-review: {OUTCOME_TEXT[d.outcome]}",
        "",
        f"**Status `eh-review/policy`:** {d.status_state} - {_esc(d.status_description)}",
        "",
    ]
    if d.human_required and d.outcome not in ("reject", "wait-for-author"):
        lines += ["> A human reviewer must approve this PR (branch policy). The bot's vote is advisory.", ""]
    if d.reasons:
        lines += ["**Why**", *[f"- {_esc(r)}" for r in d.reasons], ""]
    lines += ["| Change class | Files |", "|---|---|"]
    for cls, paths in result.classes.items():
        shown = ", ".join(f"`{_esc(p)}`" for p in paths[:6]) + (f" (+{len(paths) - 6})" if len(paths) > 6 else "")
        lines.append(f"| {cls} | {shown} |")
    lines.append("")
    if result.components:
        lines.append("**Components:** " + ", ".join(f"`{c['id']}` ({c['layer']})" for c in result.components))
    if result.consumers:
        lines.append(
            "**Consumers affected:** "
            + ", ".join(f"`{c}`" for c in result.consumers[:25])
            + (f" (+{len(result.consumers) - 25})" if len(result.consumers) > 25 else "")
        )
    s = result.stats
    lines += [f"**Size:** {s['files']} files, {s['changed_lines']} changed lines", ""]
    if result.findings:
        lines += [f"**Findings ({len(result.findings)}):**", "", "| Severity | Rule | Location | Message |", "|---|---|---|---|"]
        for f in result.findings[:40]:
            loc = f"`{_esc(f.file)}`" + (f":{f.line}" if f.line else "") if f.file else "-"
            src = " (AI)" if f.source == "ai" else ""
            lines.append(f"| {ICON[f.severity]} | {f.rule}{src} | {loc} | {_esc(f.message)} |")
        if len(result.findings) > 40:
            lines.append(f"| | | | ... {len(result.findings) - 40} more |")
        lines.append("")
    else:
        lines += ["No findings.", ""]
    cp = result.copilot or {}
    if cp.get("evaluated"):
        if cp.get("active_threads"):
            files = ", ".join(f"`{_esc(f)}`" for f in cp.get("active_files", [])[:8])
            lines.append(
                f"**GitHub Copilot:** {cp['active_threads']} unresolved Copilot comment thread(s){' in ' + files if files else ''} - "
                "resolve them (fix, or reply and resolve) before this PR can be auto-approved."
            )
        elif cp.get("threads"):
            lines.append("**GitHub Copilot:** all Copilot comment threads are resolved.")
        else:
            lines.append("**GitHub Copilot:** no Copilot review comments yet" + (" (Copilot is listed as reviewer)." if cp.get("listed_as_reviewer") else "."))
        if cp.get("stale"):
            lines.append(
                "> Commits were pushed after Copilot's last review. Copilot does not re-review automatically: **request a fresh Copilot review** on the PR."
            )
        lines.append("")
    if result.ai.get("enabled"):
        lines.append(
            f"_AI review ({_esc(result.ai.get('model'))}): {result.ai.get('findings', 0)} finding(s); AI findings can only add comments or "
            "block - they never approve._"
        )
    lines.append(f"_Policy {result.policy_hash} (target branch) - head {result.head[:12]} - tools/review. The reviewer never runs PR code._")
    return "\n".join(lines)


def finding_comment(f: Finding) -> str:
    out = [
        f"<!-- eh-review:finding fp={f.fingerprint} -->",
        f"**{ICON[f.severity]} {f.rule}**{' (AI, untrusted)' if f.source == 'ai' else ''}",
        "",
        _esc(f.message),
    ]
    if f.suggestion:
        out += ["", f"**Suggested fix:** {_esc(f.suggestion)}"]
    out += ["", "_Resolved automatically when a later iteration no longer produces this finding._"]
    return "\n".join(out)


def finding_fp(content: str) -> str | None:
    m = FINDING_MARKER_RE.search(content or "")
    return m.group(1) if m else None
