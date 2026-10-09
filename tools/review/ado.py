"""Azure DevOps REST (api-version 7.1) for the reviewer: read the PR as DATA, publish review outputs.

Endpoints (Microsoft Learn REST reference, azure-devops-rest-7.1, checked 2026-10-09):
  GET  {org}/{project}/_apis/git/repositories/{repo}/pullrequests/{id}                        Pull Requests - Get Pull Request By Id
  GET  .../pullRequests/{id}/iterations                                                       Pull Request Iterations - List
  GET  .../pullRequests/{id}/iterations/{it}/changes?$top&$skip&$compareTo=0                   Pull Request Iteration Changes - Get
  GET  .../repositories/{repo}/items?path&versionDescriptor.version&versionDescriptor.versionType=commit&includeContent=true
  GET/POST .../pullRequests/{id}/threads ; PATCH .../threads/{tid} ; PATCH .../threads/{tid}/comments/{cid}
  GET/POST .../pullRequests/{id}/statuses                                                     Pull Request Statuses - Create
  GET  .../pullRequests/{id}/reviewers ; PUT .../reviewers/{reviewerId}                       Pull Request Reviewers - Create Pull Request Reviewer (vote)
  GET  {org}/{project}/_apis/policy/evaluations?artifactId=vstfs:///CodeReview/CodeReviewId/{projectId}/{prId}  (7.1-preview.1)
  GET  {org}/_apis/connectionData   (authenticated identity id; used only when ADO_REVIEWER_ID is not configured)

Authentication: Microsoft Entra access token for Azure DevOps (resource 499b84ac-1321-427f-aa17-267ca6975798,
scope "499b84ac-1321-427f-aa17-267ca6975798/.default") from the Function's user-assigned managed identity.
"""

from __future__ import annotations

import json
import logging
import random
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass

from .model import BuildStatus, FileChange

log = logging.getLogger("eh.review.ado")

API = "7.1"
POLICY_API = "7.1-preview.1"
ADO_SCOPE = "499b84ac-1321-427f-aa17-267ca6975798/.default"
BUILD_POLICY_TYPE = "0609b952-1397-4640-95ec-e00a01b2c241"  # "Build" (verify: GET _apis/policy/types)
STATUS_POLICY_TYPE = "cbdc66da-9728-4af8-aada-9a5a32e4a226"  # "Status" (verify: GET _apis/policy/types)
THREAD_ACTIVE, THREAD_FIXED = "active", "fixed"


class AdoError(Exception):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class AdoClient:
    def __init__(self, base_url: str, organization: str, project: str, token: Callable[[], str], timeout: float = 15.0, max_attempts: int = 4, opener=None):  # noqa: PLR0917
        self.base = base_url.rstrip("/")  # https://dev.azure.com (or a fake server in tests)
        parts = urllib.parse.urlsplit(self.base)
        if not (parts.scheme == "https" or (parts.scheme == "http" and parts.hostname in ("127.0.0.1", "localhost", "::1"))):
            raise ValueError("Azure DevOps base URL must be https (http only on loopback for the fake server)")
        self.org = organization
        self.project = project
        self._token = token
        self.timeout = timeout
        self.max_attempts = max_attempts
        self._opener = opener or urllib.request.build_opener()
        self.calls: list[str] = []

    def url(self, path: str, query: dict | None = None, org_level: bool = False, version: str = API) -> str:
        q = dict(query or {})
        q.setdefault("api-version", version)
        prefix = f"{self.base}/{urllib.parse.quote(self.org)}" + ("" if org_level else f"/{urllib.parse.quote(self.project)}")
        return f"{prefix}/_apis/{path}?{urllib.parse.urlencode(q, safe='$/')}"

    def request(  # noqa: PLR0917
        self, method: str, path: str, body: dict | None = None, query: dict | None = None, org_level: bool = False, version: str = API, accept_404: bool = False
    ):
        url = self.url(path, query, org_level, version)
        data = None if body is None else json.dumps(body).encode()
        for attempt in range(1, self.max_attempts + 1):
            req = urllib.request.Request(url, data=data, method=method)  # noqa: S310 - scheme checked (https, or http on loopback for the fake server)
            req.add_header("Authorization", f"Bearer {self._token()}")
            req.add_header("Accept", "application/json")
            if data is not None:
                req.add_header("Content-Type", "application/json")
            self.calls.append(f"{method} {path}")
            try:
                with self._opener.open(req, timeout=self.timeout) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as exc:
                status = exc.code
                if status == 404 and accept_404:
                    return None
                retry_after = exc.headers.get("Retry-After") if exc.headers else None
                if status in (429, 500, 502, 503, 504) and attempt < self.max_attempts:
                    delay = float(retry_after) if retry_after and retry_after.isdigit() else min(8.0, 0.5 * 2**attempt)
                    time.sleep(random.uniform(0, delay))
                    continue
                raise AdoError(f"{method} {path}: HTTP {status}", status) from None
            except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
                if attempt < self.max_attempts:
                    time.sleep(random.uniform(0, min(8.0, 0.5 * 2**attempt)))
                    continue
                raise AdoError(f"{method} {path}: {exc.__class__.__name__}") from None
        raise AdoError(f"{method} {path}: retries exhausted")


@dataclass
class PrRef:
    repository_id: str
    pull_request_id: int

    @property
    def base(self) -> str:
        return f"git/repositories/{self.repository_id}/pullRequests/{self.pull_request_id}"


class AdoPr:
    """Read access to one PR. Content is fetched by commit id: nothing is checked out or executed."""

    def __init__(self, client: AdoClient, ref: PrRef, max_file_bytes: int = 512000):
        self.c = client
        self.ref = ref
        self.max_file_bytes = max_file_bytes
        self._pr: dict | None = None

    def pr(self) -> dict:
        if self._pr is None:
            self._pr = self.c.request("GET", f"git/repositories/{self.ref.repository_id}/pullrequests/{self.ref.pull_request_id}")
        return self._pr

    def iterations(self) -> list[dict]:
        return self.c.request("GET", f"{self.ref.base}/iterations").get("value", [])

    def latest_iteration(self) -> dict:
        its = self.iterations()
        if not its:
            raise AdoError("pull request has no iterations")
        return max(its, key=lambda i: int(i["id"]))

    def iteration_changes(self, iteration_id: int) -> list[dict]:
        out, skip = [], 0
        while True:
            page = self.c.request("GET", f"{self.ref.base}/iterations/{iteration_id}/changes", query={"$top": 2000, "$skip": skip, "$compareTo": 0})
            out += page.get("changeEntries", [])
            nxt = page.get("nextSkip") or 0
            if not nxt or nxt <= skip:
                return out
            skip = nxt

    def item_text(self, path: str, commit: str) -> tuple:
        """(text|None, binary, too_large) of `path` at `commit` (Items - Get, includeContent)."""
        item = self.c.request(
            "GET",
            f"git/repositories/{self.ref.repository_id}/items",
            accept_404=True,
            query={
                "path": "/" + path.lstrip("/"),
                "versionDescriptor.version": commit,
                "versionDescriptor.versionType": "commit",
                "includeContent": "true",
                "$format": "json",
            },
        )
        if item is None:
            return None, False, False
        meta = item.get("contentMetadata") or {}
        if meta.get("isBinary"):
            return None, True, False
        content = item.get("content")
        if content is None:
            return None, False, False
        if len(content.encode()) > self.max_file_bytes:
            return None, False, True
        return content, False, False

    def file_changes(self, iteration: dict) -> list[FileChange]:
        head = iteration["sourceRefCommit"]["commitId"]
        base = (iteration.get("commonRefCommit") or iteration["targetRefCommit"])["commitId"]
        out = []
        for e in self.iteration_changes(int(iteration["id"])):
            item = e.get("item") or {}
            if item.get("isFolder") or item.get("gitObjectType") == "tree":
                continue
            path = (item.get("path") or "").lstrip("/")
            kinds = {k.strip() for k in str(e.get("changeType", "edit")).split(",")}
            old = (e.get("originalPath") or e.get("sourceServerItem") or "").lstrip("/") or None
            if old == path:
                old = None
            status = "D" if "delete" in kinds else "A" if "add" in kinds else "R" if "rename" in kinds else "M"
            ch = FileChange(path=path, status=status, old_path=old if status == "R" else None, change_tracking_id=e.get("changeTrackingId"))
            if status != "A":
                ch.base_text, b1, t1 = self.item_text(old or path, base)
            else:
                b1 = t1 = False
            if status != "D":
                ch.head_text, b2, t2 = self.item_text(path, head)
            else:
                b2 = t2 = False
            ch.binary, ch.too_large = b1 or b2, t1 or t2
            out.append(ch)
        return out

    def trusted_files(self, commit: str, paths: list[str]) -> dict[str, bytes]:
        files = {}
        for p in paths:
            text, _, _ = self.item_text(p, commit)
            if text is not None:
                files[p] = text.encode()
        return files

    def build_status(self, project_id: str) -> BuildStatus:
        artifact = f"vstfs:///CodeReview/CodeReviewId/{project_id}/{self.ref.pull_request_id}"
        evals = self.c.request("GET", "policy/evaluations", query={"artifactId": artifact}, version=POLICY_API)
        records = evals.get("value", evals if isinstance(evals, list) else [])
        builds = []
        for r in records:
            cfg = r.get("configuration") or {}
            typ = cfg.get("type") or {}
            if typ.get("id") != BUILD_POLICY_TYPE and typ.get("displayName") != "Build":
                continue
            if not cfg.get("isEnabled", True) or cfg.get("isDeleted"):
                continue
            ctx = r.get("context") or {}
            st = r.get("status")
            if st == "notApplicable":
                continue
            builds.append(
                {
                    "status": st,
                    "blocking": cfg.get("isBlocking", True),
                    "expired": bool(ctx.get("isExpired")),
                    "build_id": ctx.get("buildId"),
                    "policy_id": cfg.get("id"),
                }
            )
        required = [b for b in builds if b["blocking"]]
        if not required:
            return BuildStatus("unknown", builds)
        if any(b["status"] in ("rejected", "broken") for b in required):
            return BuildStatus("failed", builds)
        if all(b["status"] == "approved" and not b["expired"] for b in required):
            return BuildStatus("green", builds)
        return BuildStatus("pending", builds)


def reviewer_id(client: AdoClient, configured: str | None = None) -> str:
    if configured:
        return configured
    data = client.request("GET", "connectionData", org_level=True, version="7.1-preview.1")
    uid = (data.get("authenticatedUser") or {}).get("id")
    if not uid:
        raise AdoError("cannot determine the reviewer identity id (set ADO_REVIEWER_ID)")
    return uid
