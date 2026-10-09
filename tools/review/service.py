"""Process one review job against Azure DevOps (used by the Function's queue trigger and by local e2e runs).

Trust boundaries
  * policy + component registry + schemas are read from the TARGET branch head of the iteration (trusted, protected
    branch), never from the PR source branch;
  * the PR diff is read as data (iteration changes + item content at the head / merge-base commits);
  * PR build validation results are READ (policy evaluations); the reviewer never builds or runs PR code;
  * a missing/invalid policy fails closed: status `error`, no vote.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Optional

from tools.changeset.registry import REGISTRY_PATH, REGISTRY_SCHEMA

from . import render
from .ado import AdoClient, AdoError, AdoPr, PrRef
from .analysis import MappingTree, TrustedBase
from .engine import ai_from_policy, review
from .model import ReviewContext
from .policy import POLICY_PATH, PolicyError, parse
from .publish import human_approved, publish, summary_thread

log = logging.getLogger("eh.review.service")


@dataclass
class Outcome:
    pull_request_id: int
    iteration: Optional[int]
    state: str                    # published | unchanged | skipped | error
    decision: Optional[str] = None
    vote: Optional[int] = None
    status: Optional[str] = None
    requeue: bool = False         # build pending: re-check later
    actions: tuple = ()
    detail: str = ""
    result: Optional[dict] = None


def _fail_closed(client: AdoClient, ref: PrRef, iteration: int, genre: str, name: str, why: str) -> None:
    client.request("POST", f"{ref.base}/statuses", {"state": "error", "description": why[:250],
                                                     "context": {"genre": genre, "name": name}, "iterationId": iteration})


def process(client: AdoClient, project_id: str, repository_id: str, pull_request_id: int, bot_id: str,
            env: Optional[dict] = None, ai_client=None, keep_result: bool = False) -> Outcome:
    ref = PrRef(repository_id, pull_request_id)
    pr = AdoPr(client, ref)
    info = pr.pr()
    if str((info.get("repository") or {}).get("id", "")).lower() != repository_id.lower():
        return Outcome(pull_request_id, None, "skipped", detail="repository mismatch")
    if info.get("status") != "active":
        return Outcome(pull_request_id, None, "skipped", detail=f"pull request is {info.get('status')}")
    it = pr.latest_iteration()
    iteration = int(it["id"])
    head = it["sourceRefCommit"]["commitId"]
    merge_base = (it.get("commonRefCommit") or it["targetRefCommit"])["commitId"]
    trusted_commit = it["targetRefCommit"]["commitId"]
    files = pr.trusted_files(trusted_commit, [POLICY_PATH, REGISTRY_PATH, REGISTRY_SCHEMA])
    if POLICY_PATH not in files:
        _fail_closed(client, ref, iteration, "eh-review", "policy", "Review policy missing on the target branch")
        return Outcome(pull_request_id, iteration, "error", detail="policy missing on target branch", status="error")
    try:
        policy = parse(files[POLICY_PATH].decode(), f"{POLICY_PATH}@{trusted_commit[:12]}")
    except PolicyError as exc:
        _fail_closed(client, ref, iteration, "eh-review", "policy", "Review policy on the target branch is invalid")
        return Outcome(pull_request_id, iteration, "error", detail=str(exc)[:300], status="error")
    schema = policy["observability"].get("manifest_schema")
    if schema:
        files.update(pr.trusted_files(trusted_commit, [schema]))
    base = TrustedBase(MappingTree(files, f"ado:{trusted_commit[:12]}"))
    pr.max_file_bytes = int(policy["limits"]["max_file_bytes"])

    created_by = info.get("createdBy") or {}
    threads = client.request("GET", f"{ref.base}/threads").get("value", [])
    reviewers = client.request("GET", f"{ref.base}/reviewers").get("value", [])
    approved = human_approved(reviewers, bot_id, created_by.get("id", ""))
    build = pr.build_status(project_id)
    ctx = ReviewContext(author=created_by.get("uniqueName", ""), author_id=created_by.get("id", ""), bot_ids=[bot_id],
                        target_branch=info.get("targetRefName", ""), build=build, head=head, base=merge_base,
                        pr_id=pull_request_id, iteration=iteration, title=info.get("title", ""))
    changes = pr.file_changes(it)
    result = review(changes, policy, base, ctx, ai_reviewer=ai_from_policy(policy, env, ai_client), human_approved=approved)

    st = summary_thread(threads, bot_id)
    prev = render.parse_state(((st or {}).get("comments") or [{}])[0].get("content", "")) if st else {}
    d = result.decision
    out = Outcome(pull_request_id, iteration, "unchanged", d.outcome, d.vote, d.status_state,
                  requeue=(build.state in ("pending", "unknown") and policy["decision"]["require_build_green"]
                           and d.outcome not in ("reject", "wait-for-author")),
                  result=result.to_dict() if keep_result else None)
    if prev.get("inputs") == result.input_hash and prev.get("iteration") == str(iteration):
        log.info("review unchanged", extra={"pr": pull_request_id, "iteration": iteration, "outcome": d.outcome})
        # the vote/status may still need to follow (e.g. a human approval flips status) - publish is diff-based
    try:
        actions = publish(client, ref, result, iteration, bot_id, policy, changes, threads=threads)
    except AdoError as exc:
        raise AdoError(f"publish failed: {exc}", exc.status) from None
    out.actions = tuple(actions)
    out.state = "published" if actions else "unchanged"
    log.info("review processed", extra={"pr": pull_request_id, "iteration": iteration, "outcome": d.outcome, "vote": d.vote,
                                        "status": d.status_state, "actions": len(actions), "findings": len(result.findings)})
    return out
