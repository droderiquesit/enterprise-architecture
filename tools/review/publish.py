"""Publish a ReviewResult to the PR, diff-based and idempotent (re-running with the same result writes nothing).

summary   ONE bot thread (first comment carries SUMMARY_MARKER), content replaced in place per iteration
findings  one inline thread per finding fingerprint; existing threads are reused (never duplicated across
          iterations), re-activated if a fixed finding comes back, and set to `fixed` when a later iteration no
          longer produces the finding
status    PR status genre/name (default eh-review/policy) posted on the iteration
vote      reviewers API PUT for the bot identity, only when it differs from the current vote

Only threads whose FIRST comment was authored by the bot identity are considered: a human comment that copies a
marker cannot hijack or resolve anything.
"""

from __future__ import annotations

from . import render
from .ado import THREAD_ACTIVE, THREAD_FIXED, AdoClient, PrRef
from .model import FileChange, ReviewResult


def _first(thread: dict) -> dict:
    comments = [c for c in (thread.get("comments") or []) if not c.get("isDeleted")]
    return min(comments, key=lambda c: int(c.get("id", 0))) if comments else {}


def bot_threads(threads: list[dict], bot_id: str) -> list[dict]:
    out = []
    for t in threads:
        if t.get("isDeleted"):
            continue
        first = _first(t)
        if (first.get("author") or {}).get("id") == bot_id:
            out.append(t)
    return out


def summary_thread(threads: list[dict], bot_id: str) -> dict | None:
    for t in bot_threads(threads, bot_id):
        if render.SUMMARY_MARKER in (_first(t).get("content") or ""):
            return t
    return None


def human_approved(reviewers: list[dict], bot_id: str, author_id: str) -> bool:
    """A non-author, non-bot, non-group reviewer voted approve / approve-with-suggestions (vote >= 5).
    Branch policy must reset votes on new pushes, so a vote present now applies to the latest iteration."""
    for r in reviewers:
        if r.get("id") in (bot_id, author_id) or r.get("isContainer"):
            continue
        if int(r.get("vote", 0)) >= 5:
            return True
    return False


def publish(  # noqa: PLR0917
    client: AdoClient, ref: PrRef, result: ReviewResult, iteration: int, bot_id: str, policy, changes: list[FileChange], threads: list[dict] | None = None
) -> list[str]:
    actions: list[str] = []
    b = ref.base
    if threads is None:
        threads = client.request("GET", f"{b}/threads").get("value", [])
    mine = bot_threads(threads, bot_id)

    # ---- summary
    text = render.summary(result, iteration)
    want_status = "closed" if result.decision.status_state == "succeeded" else THREAD_ACTIVE
    st = summary_thread(threads, bot_id)
    if st is None:
        client.request("POST", f"{b}/threads", {"comments": [{"parentCommentId": 0, "content": text, "commentType": 1}], "status": want_status})
        actions.append("summary:create")
    else:
        first = _first(st)
        if (first.get("content") or "") != text:
            client.request("PATCH", f"{b}/threads/{st['id']}/comments/{first['id']}", {"content": text})
            actions.append("summary:update")
        if st.get("status") != want_status:
            client.request("PATCH", f"{b}/threads/{st['id']}", {"status": want_status})
            actions.append(f"summary:status:{want_status}")

    # ---- inline findings
    existing: dict[str, dict] = {}
    for t in mine:
        fp = render.finding_fp(_first(t).get("content") or "")
        if fp:
            existing[fp] = t
    tracking = {c.path: c.change_tracking_id for c in changes}
    deleted = {c.path for c in changes if c.status == "D"}
    limit = int(policy["limits"]["max_inline_threads"])
    current = [f for f in result.findings if f.file][:limit]
    current_fps = {f.fingerprint for f in result.findings}
    for f in current:
        t = existing.get(f.fingerprint)
        if t is not None:
            if t.get("status") != THREAD_ACTIVE:
                client.request("PATCH", f"{b}/threads/{t['id']}", {"status": THREAD_ACTIVE})
                actions.append(f"finding:reactivate:{f.fingerprint}")
            continue
        ctx: dict = {"filePath": "/" + f.file}
        if f.line:
            side = "left" if f.file in deleted else "right"
            ctx[f"{side}FileStart"] = {"line": f.line, "offset": 1}
            ctx[f"{side}FileEnd"] = {"line": f.line, "offset": 1}
        body = {"comments": [{"parentCommentId": 0, "content": render.finding_comment(f), "commentType": 1}], "status": THREAD_ACTIVE, "threadContext": ctx}
        if tracking.get(f.file):
            body["pullRequestThreadContext"] = {
                "changeTrackingId": tracking[f.file],
                "iterationContext": {"firstComparingIteration": 1, "secondComparingIteration": iteration},
            }
        client.request("POST", f"{b}/threads", body)
        actions.append(f"finding:create:{f.fingerprint}")
    for fp, t in existing.items():
        if fp not in current_fps and t.get("status") == THREAD_ACTIVE:
            client.request("PATCH", f"{b}/threads/{t['id']}", {"status": THREAD_FIXED})
            actions.append(f"finding:resolve:{fp}")

    # ---- PR status (iteration-scoped)
    genre, name = policy["status"]["genre"], policy["status"]["name"]
    statuses = client.request("GET", f"{b}/statuses").get("value", [])
    ours = [
        s
        for s in statuses
        if (s.get("context") or {}).get("genre") == genre
        and (s.get("context") or {}).get("name") == name
        and (s.get("createdBy") or {}).get("id") in (bot_id, None)
        and s.get("iterationId") == iteration
    ]
    latest = max(ours, key=lambda s: int(s.get("id", 0)), default=None)
    d = result.decision
    if latest is None or latest.get("state") != d.status_state or latest.get("description") != d.status_description:
        body = {"state": d.status_state, "description": d.status_description, "context": {"genre": genre, "name": name}, "iterationId": iteration}
        if policy["status"].get("target_url"):
            body["targetUrl"] = policy["status"]["target_url"]
        client.request("POST", f"{b}/statuses", body)
        actions.append(f"status:{d.status_state}")

    # ---- vote
    reviewers = client.request("GET", f"{b}/reviewers").get("value", [])
    mine_r = next((r for r in reviewers if r.get("id") == bot_id), None)
    current_vote = int(mine_r.get("vote", 0)) if mine_r else None
    if current_vote != d.vote and not (current_vote is None and d.vote == 0):
        client.request("PUT", f"{b}/reviewers/{bot_id}", {"vote": d.vote, "id": bot_id})
        actions.append(f"vote:{d.vote}")
    return actions
