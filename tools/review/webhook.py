"""Azure DevOps Service Hook (Web Hooks consumer) request validation - pure Python, used by the Function.

1. size limit, then Basic authentication header compared in CONSTANT TIME (hmac.compare_digest) against the
   webhook secret(s) from Delinea DSV (current + optional previous for rotation). Nothing else is read before.
2. payload sanity: publisherId `tfs`, allowed eventType, organization (collection/account id), project id and
   repository id on the allowlist from trusted app settings.
3. replay protection: `createdDate` inside the window (default 10 min, 2 min clock skew) and the event `id` not
   seen within the window (bounded in-memory cache per instance; processing is idempotent per (PR, iteration),
   so a cross-instance replay can at most trigger a no-op re-review).
The payload only selects WHICH PR to review; everything else is re-read from Azure DevOps with the reviewer's
own identity (resourceDetailsToSend = minimal is recommended).
"""

from __future__ import annotations

import base64
import datetime as dt
import hmac
import json
import re
import threading
import time
from collections import OrderedDict
from collections.abc import Iterable
from dataclasses import dataclass

ALLOWED_EVENTS = ("git.pullrequest.created", "git.pullrequest.updated", "ms.vss-code.git-pullrequest-comment-event")
MAX_BODY = 256 * 1024
GUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
PR_URL = re.compile(r"/repositories/([0-9a-fA-F-]{36})/pullRequests/(\d+)", re.I)


class WebhookRejected(Exception):
    def __init__(self, status: int, reason: str):
        super().__init__(reason)
        self.status = status
        self.reason = reason  # safe to log: never contains header or body content


@dataclass(frozen=True)
class Allowlist:
    project_ids: frozenset
    repository_ids: frozenset
    account_ids: frozenset = frozenset()

    @classmethod
    def from_settings(cls, projects: str, repositories: str, accounts: str = "") -> Allowlist:
        def split(v: str) -> frozenset:
            return frozenset(x.strip().lower() for x in (v or "").split(",") if x.strip())

        return cls(split(projects), split(repositories), split(accounts))


@dataclass(frozen=True)
class ReviewJob:
    event_id: str
    event_type: str
    project_id: str
    repository_id: str
    pull_request_id: int
    created: str

    def to_message(self) -> str:
        return json.dumps(self.__dict__, sort_keys=True)

    @classmethod
    def from_message(cls, text: str) -> ReviewJob:
        d = json.loads(text)
        return cls(
            str(d["event_id"]),
            str(d["event_type"]),
            str(d["project_id"]).lower(),
            str(d["repository_id"]).lower(),
            int(d["pull_request_id"]),
            str(d.get("created", "")),
        )


class ReplayCache:
    def __init__(self, ttl_seconds: float = 900, max_entries: int = 10000):
        self.ttl = ttl_seconds
        self.max = max_entries
        self._seen: OrderedDict[str, float] = OrderedDict()
        self._lock = threading.Lock()

    def seen(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            while self._seen and next(iter(self._seen.values())) < now - self.ttl:
                self._seen.popitem(last=False)
            return key in self._seen

    def add(self, key: str) -> None:
        with self._lock:
            self._seen[key] = time.monotonic()
            self._seen.move_to_end(key)
            while len(self._seen) > self.max:
                self._seen.popitem(last=False)


def expected_headers(username: str, secrets: Iterable[str]) -> list:
    return [b"Basic " + base64.b64encode(f"{username}:{s}".encode()) for s in secrets if s]


def check_auth(header: str | None, username: str, secrets: Iterable[str]) -> None:
    candidates = expected_headers(username, secrets)
    if not candidates:
        raise WebhookRejected(503, "webhook secret not configured")
    got = (header or "").strip().encode()
    ok = False
    for exp in candidates:  # compare against every candidate: no early exit on the first match
        ok |= hmac.compare_digest(got, exp)
    if not ok:
        raise WebhookRejected(401, "invalid webhook credentials")


def _parse_time(s: str) -> dt.datetime:
    s = s.strip().replace("Z", "+00:00")
    m = re.match(r"^(.*\.\d{6})\d*(.*)$", s)  # ADO uses 7 fractional digits
    if m:
        s = m.group(1) + m.group(2)
    t = dt.datetime.fromisoformat(s)
    return t if t.tzinfo else t.replace(tzinfo=dt.UTC)


def validate(
    body: bytes,
    auth_header: str | None,
    *,
    username: str,
    secrets: Iterable[str],
    allow: Allowlist,
    replay: ReplayCache,
    window_seconds: int = 600,
    skew_seconds: int = 120,
    now: dt.datetime | None = None,
) -> ReviewJob:
    """Validate one delivery and return the job it selects; raises WebhookRejected. Only checks the replay cache:
    the caller adds the event id once the job was accepted (enqueued), so a failed enqueue can be redelivered."""
    if len(body) > MAX_BODY:
        raise WebhookRejected(413, "payload too large")
    check_auth(auth_header, username, secrets)
    try:
        ev = json.loads(body)
    except ValueError:
        raise WebhookRejected(400, "payload is not JSON") from None
    if not isinstance(ev, dict):
        raise WebhookRejected(400, "payload is not an object")
    if ev.get("publisherId") != "tfs":
        raise WebhookRejected(400, "unexpected publisherId")
    etype = ev.get("eventType")
    if etype not in ALLOWED_EVENTS:
        raise WebhookRejected(400, "event type not allowed")
    eid = str(ev.get("id") or "")
    if not GUID.match(eid):
        raise WebhookRejected(400, "missing event id")
    try:
        created = _parse_time(str(ev.get("createdDate") or ""))
    except ValueError:
        raise WebhookRejected(400, "missing or invalid createdDate") from None
    now = now or dt.datetime.now(dt.UTC)
    age = (now - created).total_seconds()
    if age > window_seconds or age < -skew_seconds:
        raise WebhookRejected(401, "event outside the replay window")
    containers = ev.get("resourceContainers") or {}
    project_id = str((containers.get("project") or {}).get("id") or "").lower()
    account_id = str((containers.get("account") or containers.get("collection") or {}).get("id") or "").lower()
    res = ev.get("resource") or {}
    if etype == "ms.vss-code.git-pullrequest-comment-event":
        res = res.get("pullRequest") or {}
    repo_id = str((res.get("repository") or {}).get("id") or "").lower()
    pr_id = res.get("pullRequestId")
    m = PR_URL.search(str(res.get("url") or ""))
    if m:
        repo_id = repo_id or m.group(1).lower()
        pr_id = pr_id or int(m.group(2))
    if allow.account_ids and account_id not in allow.account_ids:
        raise WebhookRejected(403, "organization not allowed")
    if project_id not in allow.project_ids:
        raise WebhookRejected(403, "project not allowed")
    if repo_id not in allow.repository_ids:
        raise WebhookRejected(403, "repository not allowed")
    try:
        pr = int(pr_id)
    except (TypeError, ValueError):
        raise WebhookRejected(400, "missing pullRequestId") from None
    if pr <= 0:
        raise WebhookRejected(400, "invalid pullRequestId")
    if replay.seen(eid):
        raise WebhookRejected(409, "duplicate event (replay)")
    return ReviewJob(eid, etype, project_id, repo_id, pr, created.isoformat())
