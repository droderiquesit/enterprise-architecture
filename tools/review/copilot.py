"""GitHub Copilot code review for Azure Repos (public preview) as the AI reviewer - read-only gating.

Copilot posts as reviewer "GitHub Copilot" with inline comment threads and always leaves a *Comment* review: it never
approves, never requests changes, does not satisfy required reviewers and does not block merge. It does NOT re-review
new commits automatically (a fresh review must be requested). The policy bot therefore only READS Copilot's threads:

  * active / pending Copilot threads  -> auto-approval withheld, status pending "resolve Copilot comments"
                                         (never wait-for-author, never reject: Copilot output can only gate)
  * commits pushed after Copilot's last comment -> summary asks for a fresh Copilot review
  * copilot.required_before_auto_approve -> no auto-approval until Copilot reviewed the CURRENT iteration

Detecting "Copilot reviewed the current iteration": there is no documented Copilot review-status API, so the bot uses
the documented observable signals - Copilot listed as a PR reviewer and/or Copilot-authored comment threads - and treats
the review as current when Copilot's newest comment is not older than the latest iteration's createdDate. This is a
heuristic (documented in docs/guides/automated-pr-review.md); a Copilot review that produced no comment at all on a new
iteration is indistinguishable from "not reviewed yet" and keeps the status pending until a human requests a review or
approves.

The Copilot identity is matched by configurable display/unique names and ids (`copilot.reviewer_names`,
`copilot.reviewer_ids`); no identity id is hard-coded.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field

BLOCKING_STATUSES = ("active", "pending")


@dataclass
class CopilotState:
    evaluated: bool = True
    listed_as_reviewer: bool = False
    threads: int = 0
    active_threads: int = 0
    active_files: list[str] = field(default_factory=list)
    last_comment: str | None = None  # ISO timestamp of Copilot's newest comment
    iteration_created: str | None = None
    reviewed_current: bool = False
    stale: bool = False  # commits pushed after Copilot's last review

    @property
    def reviewed_any(self) -> bool:
        return self.threads > 0


def _t(s: str | None) -> dt.datetime | None:
    if not s:
        return None
    try:
        s2 = s.replace("Z", "+00:00")
        head, _, tail = s2.partition(".")
        if tail:  # trim >6 fractional digits (Azure DevOps uses 7)
            frac = "".join(ch for ch in tail if ch.isdigit())
            tz = tail[len(frac) :]
            s2 = f"{head}.{frac[:6]}{tz}"
        t = dt.datetime.fromisoformat(s2)
        return t if t.tzinfo else t.replace(tzinfo=dt.UTC)
    except ValueError:
        return None


def is_copilot(identity: dict | None, cfg: dict) -> bool:
    if not identity:
        return False
    ids = {i.lower() for i in cfg.get("reviewer_ids", [])}
    names = {n.lower() for n in cfg.get("reviewer_names", [])}
    if identity.get("id") and str(identity["id"]).lower() in ids:
        return True
    return any(str(identity.get(k) or "").lower() in names for k in ("displayName", "uniqueName")) if names else False


def assess(threads: list[dict], reviewers: list[dict], iteration: dict, cfg: dict) -> CopilotState:
    st = CopilotState(iteration_created=iteration.get("createdDate"))
    st.listed_as_reviewer = any(is_copilot(r, cfg) for r in reviewers)
    newest: dt.datetime | None = None
    for t in threads:
        if t.get("isDeleted"):
            continue
        comments = [c for c in (t.get("comments") or []) if not c.get("isDeleted")]
        if not comments:
            continue
        first = min(comments, key=lambda c: int(c.get("id", 0)))
        if not is_copilot(first.get("author"), cfg):
            continue
        st.threads += 1
        if t.get("status") in BLOCKING_STATUSES:
            st.active_threads += 1
            fp = ((t.get("threadContext") or {}).get("filePath") or "").lstrip("/")
            if fp and fp not in st.active_files:
                st.active_files.append(fp)
        for c in comments:
            if is_copilot(c.get("author"), cfg):
                ts = _t(c.get("lastUpdatedDate") or c.get("publishedDate"))
                if ts and (newest is None or ts > newest):
                    newest = ts
    st.last_comment = newest.isoformat() if newest else None
    it_created = _t(iteration.get("createdDate"))
    if newest is not None:
        st.reviewed_current = it_created is None or newest >= it_created
        st.stale = not st.reviewed_current
    return st


def not_evaluated() -> CopilotState:
    return CopilotState(evaluated=False)
