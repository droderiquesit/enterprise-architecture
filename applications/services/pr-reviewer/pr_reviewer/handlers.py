"""Request/queue handlers of eh-pr-reviewer, free of azure.functions types so they are unit-testable.

webhook  POST /api/ado-webhook  -> authenticate + sanity + replay checks -> enqueue ReviewJob -> 202 (fast)
process  queue message          -> per-PR lease -> tools.review.service.process -> re-check later while the PR
                                   build is pending (bounded) ; failures raise so the Functions queue trigger
                                   retries with its visibility back-off and moves poison messages aside.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Callable, Optional, Protocol, Tuple

from tools.review.ado import ADO_SCOPE, AdoClient, reviewer_id
from tools.review.service import process
from tools.review.webhook import ReplayCache, ReviewJob, WebhookRejected, validate

from .settings import Settings

log = logging.getLogger("pr_reviewer")
_replay = ReplayCache(ttl_seconds=3600)
_reviewer_id: Optional[str] = None


class Queue(Protocol):
    def send(self, text: str, delay_seconds: int = 0) -> None: ...


class Lease(Protocol):
    def acquire(self, key: str) -> Optional[object]: ...
    def release(self, handle: object) -> None: ...


# ------------------------------------------------------------------------------------------------ wiring
def token_provider(settings: Settings) -> Callable[[], str]:
    if settings.ado_auth == "static":            # local fake server / tests only
        tok = os.environ.get("ADO_STATIC_TOKEN", "")
        return lambda: tok
    from azure.identity import ManagedIdentityCredential

    cred = ManagedIdentityCredential(client_id=settings.client_id) if settings.client_id else ManagedIdentityCredential()

    def get() -> str:
        return cred.get_token(ADO_SCOPE).token   # azure-identity caches and refreshes the token

    return get


def ado_client(settings: Settings) -> AdoClient:
    return AdoClient(settings.ado_base_url, settings.organization, settings.project, token_provider(settings))


class StorageQueue:
    """Azure Storage queue via the managed identity (no keys). Message text is JSON (host.json messageEncoding none)."""

    def __init__(self, settings: Settings):
        from azure.identity import ManagedIdentityCredential
        from azure.storage.queue import QueueClient

        cred = ManagedIdentityCredential(client_id=settings.client_id) if settings.client_id else ManagedIdentityCredential()
        self.q = QueueClient(settings.queue_service_uri, settings.queue_name, credential=cred)

    def send(self, text: str, delay_seconds: int = 0) -> None:
        self.q.send_message(text, visibility_timeout=delay_seconds or None, time_to_live=24 * 3600)


class BlobLease:
    """Per-PR mutual exclusion (blob lease, 60 s) so two instances never publish the same PR concurrently."""

    def __init__(self, settings: Settings):
        from azure.identity import ManagedIdentityCredential
        from azure.storage.blob import ContainerClient

        cred = ManagedIdentityCredential(client_id=settings.client_id) if settings.client_id else ManagedIdentityCredential()
        self.c = ContainerClient.from_container_url(settings.lock_container_uri, credential=cred)

    def acquire(self, key: str):
        from azure.core.exceptions import HttpResponseError, ResourceExistsError

        blob = self.c.get_blob_client(f"{key}.lock")
        try:
            blob.upload_blob(b"", overwrite=False)
        except ResourceExistsError:
            pass
        try:
            return blob.acquire_lease(lease_duration=60)
        except HttpResponseError:
            return None

    def release(self, handle) -> None:
        try:
            handle.release()
        except Exception:  # noqa: BLE001 - an expired lease is fine
            log.debug("lease release failed")


# ------------------------------------------------------------------------------------------------ handlers
def health() -> Tuple[int, dict]:
    return 200, {"status": "ok"}


def ready(settings: Settings) -> Tuple[int, dict]:
    problems = settings.problems()
    return (503 if problems else 200), {"status": "not-ready" if problems else "ready", "problems": problems}


def webhook(body: bytes, auth_header: Optional[str], settings: Settings, queue: Queue,
            replay: ReplayCache = _replay) -> Tuple[int, dict]:
    try:
        job = validate(body, auth_header, username=settings.webhook_username, secrets=settings.webhook_secrets,
                       allow=settings.allow, replay=replay, window_seconds=settings.replay_window_seconds)
    except WebhookRejected as exc:
        if exc.status == 409:          # duplicate delivery: acknowledged, nothing to do
            log.info("webhook duplicate ignored")
            return 200, {"status": "duplicate"}
        log.warning("webhook rejected", extra={"reason": exc.reason, "http_status": exc.status})
        return exc.status, {"error": exc.reason}
    queue.send(json.dumps({"job": json.loads(job.to_message()), "attempt": 0}))
    replay.add(job.event_id)
    log.info("review queued", extra={"pr": job.pull_request_id, "event_type": job.event_type, "event_id": job.event_id})
    return 202, {"status": "queued", "pullRequestId": job.pull_request_id}


def process_message(text: str, settings: Settings, queue: Queue, lease: Optional[Lease] = None,
                    client: Optional[AdoClient] = None, env: Optional[dict] = None, ai_client=None) -> dict:
    global _reviewer_id
    msg = json.loads(text)
    job = ReviewJob.from_message(json.dumps(msg["job"]))
    attempt = int(msg.get("attempt", 0))
    if job.project_id != settings.project_id or job.repository_id not in settings.allow.repository_ids:
        log.warning("queue message for a repository outside the allowlist dropped")
        return {"state": "dropped"}
    client = client or ado_client(settings)
    if _reviewer_id is None or settings.reviewer_id:
        _reviewer_id = reviewer_id(client, settings.reviewer_id)
    handle = None
    if lease is not None:
        handle = lease.acquire(f"pr-{job.repository_id}-{job.pull_request_id}")
        if handle is None:
            queue.send(json.dumps({"job": msg["job"], "attempt": attempt}), delay_seconds=30)
            return {"state": "locked-requeued"}
    try:
        out = process(client, settings.project_id, job.repository_id, job.pull_request_id, _reviewer_id, env=env, ai_client=ai_client)
    finally:
        if handle is not None:
            lease.release(handle)
    if out.requeue and attempt < settings.max_rechecks:
        queue.send(json.dumps({"job": msg["job"], "attempt": attempt + 1}), delay_seconds=settings.recheck_seconds)
    return {"state": out.state, "decision": out.decision, "vote": out.vote, "status": out.status, "iteration": out.iteration,
            "requeued": bool(out.requeue and attempt < settings.max_rechecks), "actions": list(out.actions)}
