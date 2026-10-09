"""Deterministic decision policy. The ONLY place an approval can come from.

Inputs are the change classes (from paths/content), findings (rules + AI), the PR build state, author and target
branch. AI findings participate exactly like rule findings of the same severity: they can only make the outcome
stricter, never looser (there is no input through which model output can add an approval).
"""

from __future__ import annotations

from typing import Dict, List

from .model import OUTCOMES, Decision, Finding, ReviewContext
from .policy import Policy


def decide(policy: Policy, classes: Dict[str, List[str]], findings: List[Finding], ctx: ReviewContext,
           stats: dict, human_approved: bool = False) -> Decision:
    dec = policy["decision"]
    reasons: List[str] = []
    blocking = set(dec["blocking_severities"])
    wait_sev = set(dec["wait_for_author_severities"])
    ai_wait_sev = set(policy["ai"]["blocking_severities"])

    definite = [f for f in findings if f.definite]
    violations = [f for f in findings if f.kind == "violation" and f.severity in wait_sev]
    ai_blockers = [f for f in findings if f.kind == "ai" and f.severity in ai_wait_sev]
    blockers = [f for f in findings if f.severity in blocking]

    # ---- auto-approvability (pure policy; every condition must hold)
    approvable_classes = set(dec["auto_approve_classes"])
    file_classes = set(classes)
    not_allowed = sorted(c for c in file_classes if c not in approvable_classes)
    never = sorted(c for c in file_classes if policy.never_approve(c))
    auto = True
    if not file_classes:
        auto = False
        reasons.append("no changed files")
    if not_allowed:
        auto = False
        reasons.append("change classes need a human: " + ", ".join(not_allowed))
    if never:
        reasons.append("never bot-approved (governance/identity/prod): " + ", ".join(never))
    if blockers:
        auto = False
        reasons.append(f"{len(blockers)} finding(s) at blocking severity ({', '.join(sorted({f.severity for f in blockers}))})")
    if policy.is_bot(ctx.author, ctx.author_id) or (ctx.author_id and ctx.author_id in ctx.bot_ids):
        auto = False
        reasons.append("PR authored by the reviewer identity")
    if policy.target_never_approved(ctx.target_branch):
        auto = False
        reasons.append(f"target branch {ctx.target_branch} is never bot-approved")
    if stats.get("files", 0) > dec["max_files_for_auto_approve"]:
        auto = False
        reasons.append(f"{stats.get('files')} files > max_files_for_auto_approve {dec['max_files_for_auto_approve']}")
    build = ctx.build.state
    if dec["require_build_green"] and build != "green":
        reasons.append(f"PR build validation is {build}")

    def make(outcome: str, state: str, desc: str, auto_ok: bool, human: bool) -> Decision:
        return Decision(outcome=outcome, vote=OUTCOMES[outcome], status_state=state, status_description=desc[:250],
                        auto_approvable=auto_ok, human_required=human, reasons=reasons)

    # ---- outcome (strictest first)
    if definite:
        reasons.insert(0, f"definite violation: {', '.join(sorted({f.rule for f in definite}))}")
        return make("reject", "failed", "Rejected: " + definite[0].message, False, True)
    if build == "failed":
        return make("wait-for-author", "failed", "PR build validation failed on the latest iteration", False, True)
    if violations or ai_blockers:
        n = len(violations) + len(ai_blockers)
        return make("wait-for-author", "failed", f"{n} issue(s) must be fixed by the author", False, True)
    if dec["require_build_green"] and build != "green":
        return make("no-vote", "pending", f"Waiting for PR build validation ({build})", False, not auto)
    if auto:
        low = [f for f in findings if f.severity in ("low",)]
        outcome = "approve-with-suggestions" if low else "approve"
        return make(outcome, "succeeded", "Auto-approved by policy (" + ", ".join(sorted(file_classes)) + ")", True, False)
    human_vote_outcome = "approve-with-suggestions" if dec["human_required_vote"] == 5 else "no-vote"
    if human_approved:
        return make(human_vote_outcome, "succeeded", "Human approval present; no blocking findings", False, True)
    return make(human_vote_outcome, "pending", "Human approval required: " + "; ".join(reasons[:2]), False, True)
