"""Review engine: FileChanges (data) + trusted policy/registry + PR context -> ReviewResult.

Nothing from the change is executed: rules read text, YAML and JSON only. The engine is used identically by the
CLI (`python3 -m tools.review`, local git) and by the Azure Function (Azure DevOps REST data).
"""

from __future__ import annotations

from tools.changeset import globs

from . import secrets_scan, terraform_rules
from .analysis import TrustedBase, classify
from .decide import decide
from .diffing import line_diff
from .model import SEVERITY_RANK, FileChange, Finding, ReviewContext, ReviewResult
from .policy import Policy

CODE_CLASSES = ("code", "terraform")


def _dedupe(findings: list[Finding]) -> list[Finding]:
    seen: dict[str, Finding] = {}
    for f in findings:
        if f.fingerprint not in seen:
            seen[f.fingerprint] = f
    return sorted(seen.values(), key=lambda f: (SEVERITY_RANK[f.severity], f.file or "", f.line or 0, f.rule))


def review(changes: list[FileChange], policy: Policy, base: TrustedBase, ctx: ReviewContext, ai_reviewer=None, human_approved: bool = False) -> ReviewResult:  # noqa: PLR0917
    findings: list[Finding] = []
    files: list[dict] = []
    classes: dict[str, list[str]] = {}
    total_changed = 0
    limits = policy["limits"]
    direct: dict[str, list[str]] = {}
    shared_modules = set()
    notes = list(base.notes)

    for ch in changes:
        d = line_diff(ch)
        total_changed += d.changed_lines
        cls, f_cls, extra = classify(policy, base, ch, d.added)
        findings += f_cls
        classes.setdefault(cls, []).append(ch.path)
        owners = sorted({o for p in ch.paths for o in base.owners_of(p)})
        for o in owners:
            direct.setdefault(o, []).append(ch.path)
        if extra.get("shared_module"):
            shared_modules.add(extra["shared_module"])
        if ch.head_text is not None and not ch.binary:
            findings += secrets_scan.scan(ch.path, d.added, policy["secrets"])
        findings += terraform_rules.scan(ch, d, policy["terraform"])
        if any(policy.owner_protected(p) for p in ch.paths) and not policy.is_owner(ctx.author, ctx.author_id):
            findings.append(
                Finding(
                    rule="policy.tamper",
                    severity="critical",
                    kind="violation",
                    category="governance",
                    message=f"`{ch.path}` is owner-protected review policy and the PR author is not a policy owner.",
                    file=ch.path,
                    definite=True,
                    evidence=f"tamper:{ch.path}",
                    suggestion="Policy changes must be authored by a listed owner (.review/policy.yaml `owners`).",
                )
            )
        files.append(
            {
                "path": ch.path,
                "old_path": ch.old_path,
                "status": ch.status,
                "class": cls,
                "components": owners,
                "added": len(d.added),
                "removed": len(d.removed),
                "binary": ch.binary,
                "too_large": ch.too_large,
                **({"bumps": extra["bumps"]} if extra.get("bumps") else {}),
            }
        )

    # size
    if total_changed > limits["max_changed_lines"] or len(changes) > limits["max_files"]:
        findings.append(
            Finding(
                rule="change.large-diff",
                severity="medium",
                kind="quality",
                category="size",
                message=f"Large change: {len(changes)} files, {total_changed} changed lines "
                f"(limits {limits['max_files']} files / {limits['max_changed_lines']} lines).",
                evidence="large-diff",
                suggestion="Split the PR by component so each part can be reviewed (and rolled back) alone.",
            )
        )

    # missing tests: a component's code changed but none of its test files did
    reg = base.registry
    if reg is not None:
        for cid, paths in sorted(direct.items()):
            c = reg.components.get(cid)
            if not c or c.kind == "docs":
                continue
            code = [p for p in paths if next((f["class"] for f in files if f["path"] == p), "") in CODE_CLASSES]
            tests = [f for f in files if globs.under(f["path"], c.path) and f["class"] == "tests"]
            if code and not tests:
                findings.append(
                    Finding(
                        rule="quality.missing-tests",
                        severity="low",
                        kind="quality",
                        category="tests",
                        message=f"{cid}: code changed ({len(code)} file(s)) without a test change.",
                        file=code[0],
                        evidence=f"missing-tests:{cid}",
                        suggestion=f"Add or update tests under {c.path}/tests (unit tests / terraform test with mock providers).",
                    )
                )

    ai_meta: dict = {"enabled": False}
    if ai_reviewer is not None:
        ai_findings, ai_meta = ai_reviewer.review(changes, ctx.head, policy.hash)
        findings += ai_findings

    findings = _dedupe(findings)
    consumers: list[str] = []
    layers: list[str] = []
    components = []
    if reg is not None and base.graph is not None:
        cons = base.graph.transitive_consumers(list(direct), include_implicit=False) - set(direct)
        consumers = sorted(cons)
        for cid in sorted(direct):
            c = reg.components[cid]
            components.append({"id": cid, "layer": c.layer, "kind": c.kind, "paths": sorted(direct[cid])})
        layers = sorted({reg.components[c].layer for c in direct})
    if shared_modules:
        notes.append("shared Terraform modules changed: " + ", ".join(sorted(shared_modules)))
    stats = {
        "files": len(changes),
        "changed_lines": total_changed,
        "findings": {s: sum(1 for f in findings if f.severity == s) for s in ("critical", "high", "medium", "low", "info")},
    }
    decision = decide(policy, classes, findings, ctx, stats, human_approved=human_approved)
    return ReviewResult(
        head=ctx.head,
        base=ctx.base,
        policy_hash=policy.hash,
        files=files,
        components=components,
        consumers=consumers,
        layers=layers,
        classes={k: sorted(v) for k, v in sorted(classes.items())},
        findings=findings,
        decision=decision,
        stats=stats,
        ai=ai_meta,
        notes=notes,
    )


def ai_from_policy(policy: Policy, env: dict | None = None, client=None):
    """AiReviewer when the policy enables it AND a key is configured (env var named by ai.api_key_env)."""
    import os

    cfg = policy["ai"]
    if not cfg.get("enabled"):
        return None
    key = (env or os.environ).get(cfg["api_key_env"])
    if key and key.startswith("dsv://"):
        key = None  # unresolved reference (hello_common.secrets.resolve_env not run)
    if not key and client is None:
        return None
    from .ai import AiReviewer

    return AiReviewer(cfg, api_key=key, client=client)
