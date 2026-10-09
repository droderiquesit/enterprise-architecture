"""A fake Azure DevOps REST server (stdlib http.server) backed by a real local git repository.

It implements exactly the api-version 7.1 endpoints tools/review uses (see tools/review/ado.py) with response
shapes taken from the Microsoft Learn REST reference samples. Item content is served from the git repository with
`git cat-file`, so tests and the local end-to-end run review real commits.
"""

from __future__ import annotations

import json
import re
import subprocess
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional

BOT_ID = "99999999-9999-9999-9999-999999999999"
AUTHOR_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
HUMAN_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
PROJECT_ID = "11111111-1111-1111-1111-111111111111"
REPO_ID = "22222222-2222-2222-2222-222222222222"
ACCOUNT_ID = "33333333-3333-3333-3333-333333333333"
ORG, PROJECT = "example-org", "enterprise-hello"
BUILD_TYPE = "0609b952-1397-4640-95ec-e00a01b2c241"


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout


class FakeAdo:
    def __init__(self, repo: Path):
        self.repo = Path(repo)
        self.prs: Dict[int, dict] = {}
        self.calls: List[str] = []
        self.token_seen: Optional[str] = None
        self._lock = threading.Lock()
        self._thread_id = 100

    # -------------------------------------------------------------- state
    def add_pr(self, pr_id: int, base_ref: str, head_ref: str, target: str = "refs/heads/main", author: str = "dev@example.com",
               author_id: str = AUTHOR_ID, build: str = "approved") -> dict:
        pr = {"id": pr_id, "target": target, "author": author, "author_id": author_id, "iterations": [], "threads": [],
              "statuses": [], "reviewers": [], "build": build, "status": "active", "target_head": git(self.repo, "rev-parse", base_ref).strip()}
        self.prs[pr_id] = pr
        self.push(pr_id, base_ref, head_ref)
        return pr

    def push(self, pr_id: int, base_ref: str, head_ref: str, target_head: Optional[str] = None) -> int:
        """New iteration (a push to the source branch). Votes are reset as branch policy would do."""
        pr = self.prs[pr_id]
        base = git(self.repo, "merge-base", base_ref, head_ref).strip()
        head = git(self.repo, "rev-parse", head_ref).strip()
        if target_head:
            pr["target_head"] = git(self.repo, "rev-parse", target_head).strip()
        it_id = len(pr["iterations"]) + 1
        pr["iterations"].append({"id": it_id, "head": head, "base": base})
        for r in pr["reviewers"]:
            r["vote"] = 0
        return it_id

    def set_vote(self, pr_id: int, reviewer_id: str, vote: int, display: str = "Human Reviewer") -> None:
        pr = self.prs[pr_id]
        r = next((x for x in pr["reviewers"] if x["id"] == reviewer_id), None)
        if r is None:
            r = {"id": reviewer_id, "displayName": display, "vote": 0}
            pr["reviewers"].append(r)
        r["vote"] = vote

    def changes(self, base: str, head: str) -> List[dict]:
        out = git(self.repo, "diff", "--name-status", "-z", "-M", f"{base}..{head}")
        toks = [t for t in out.split("\0")]
        entries, i, tid = [], 0, 1
        while i < len(toks):
            st = toks[i]
            if not st:
                i += 1
                continue
            if st[0] in "RC":
                old, new = toks[i + 1], toks[i + 2]
                i += 3
                entries.append({"changeTrackingId": tid, "changeId": tid, "item": {"path": "/" + new}, "changeType": "rename, edit",
                                "originalPath": "/" + old})
            else:
                path = toks[i + 1]
                i += 2
                kind = {"A": "add", "D": "delete"}.get(st[0], "edit")
                entries.append({"changeTrackingId": tid, "changeId": tid, "item": {"path": "/" + path}, "changeType": kind})
            tid += 1
        return entries

    def item(self, path: str, commit: str) -> Optional[dict]:
        try:
            data = subprocess.run(["git", "-C", str(self.repo), "show", f"{commit}:{path.lstrip('/')}"], check=True, capture_output=True).stdout
        except subprocess.CalledProcessError:
            return None
        if b"\0" in data[:8000]:
            return {"path": path, "contentMetadata": {"isBinary": True}}
        return {"path": path, "commitId": commit, "content": data.decode("utf-8", "replace"), "contentMetadata": {"isBinary": False}}

    # -------------------------------------------------------------- server
    def start(self):
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):  # quiet
                pass

            def _send(self, code: int, body=None):
                raw = b"" if body is None else json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def _handle(self, method: str):
                auth = self.headers.get("Authorization", "")
                if not auth.startswith("Bearer "):
                    return self._send(401, {"message": "TF400813: unauthorized"})
                fake.token_seen = auth[7:]
                u = urllib.parse.urlsplit(self.path)
                q = dict(urllib.parse.parse_qsl(u.query))
                if not q.get("api-version", "").startswith("7.1"):
                    return self._send(400, {"message": "api-version 7.1 expected"})
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n)) if n else None
                with fake._lock:
                    fake.calls.append(f"{method} {u.path}")
                    code, resp = fake.route(method, u.path, q, body)
                self._send(code, resp)

            def do_GET(self):
                self._handle("GET")

            def do_POST(self):
                self._handle("POST")

            def do_PATCH(self):
                self._handle("PATCH")

            def do_PUT(self):
                self._handle("PUT")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self

    def stop(self):
        self.server.shutdown()

    # -------------------------------------------------------------- routes
    def route(self, method: str, path: str, q: dict, body):  # noqa: PLR0911, PLR0912
        p = urllib.parse.unquote(path)
        if p == f"/{ORG}/_apis/connectionData":
            return 200, {"authenticatedUser": {"id": BOT_ID, "providerDisplayName": "eh-id-pr-reviewer"}}
        if p == f"/{ORG}/{PROJECT}/_apis/policy/evaluations":
            m = re.search(r"/(\d+)$", q.get("artifactId", ""))
            pr = self.prs.get(int(m.group(1))) if m else None
            if not pr:
                return 200, {"value": [], "count": 0}
            return 200, {"count": 1, "value": [{
                "evaluationId": "e1", "status": pr["build"], "context": {"buildId": 42, "isExpired": False},
                "configuration": {"id": 7, "isEnabled": True, "isBlocking": True, "isDeleted": False,
                                  "type": {"id": BUILD_TYPE, "displayName": "Build"}}}]}
        m = re.match(rf"^/{ORG}/{PROJECT}/_apis/git/repositories/([^/]+)/items$", p)
        if m and method == "GET":
            item = self.item(q.get("path", ""), q.get("versionDescriptor.version", ""))
            return (200, item) if item else (404, {"message": "TF401174: item not found"})
        m = re.match(rf"^/{ORG}/{PROJECT}/_apis/git/repositories/([^/]+)/pullrequests/(\d+)(/.*)?$", p, re.I)
        if not m or m.group(1) != REPO_ID:
            return 404, {"message": "not found"}
        pr = self.prs.get(int(m.group(2)))
        if pr is None:
            return 404, {"message": "TF401180: pull request not found"}
        rest = m.group(3) or ""
        last = pr["iterations"][-1]
        if rest == "" and method == "GET":
            return 200, {"pullRequestId": pr["id"], "status": pr["status"], "title": f"PR {pr['id']}",
                         "repository": {"id": REPO_ID, "project": {"id": PROJECT_ID}}, "targetRefName": pr["target"],
                         "sourceRefName": "refs/heads/feature", "createdBy": {"id": pr["author_id"], "uniqueName": pr["author"]},
                         "lastMergeSourceCommit": {"commitId": last["head"]}}
        if rest == "/iterations":
            return 200, {"count": len(pr["iterations"]), "value": [
                {"id": it["id"], "sourceRefCommit": {"commitId": it["head"]}, "targetRefCommit": {"commitId": pr["target_head"]},
                 "commonRefCommit": {"commitId": it["base"]}} for it in pr["iterations"]]}
        mi = re.match(r"^/iterations/(\d+)/changes$", rest)
        if mi:
            it = pr["iterations"][int(mi.group(1)) - 1]
            entries = self.changes(it["base"], it["head"])
            skip, top = int(q.get("$skip", 0)), int(q.get("$top", 100))
            page = entries[skip: skip + top]
            nxt = skip + top if skip + top < len(entries) else 0
            return 200, {"changeEntries": page, "nextSkip": nxt, "nextTop": top if nxt else 0}
        if rest == "/threads" and method == "GET":
            return 200, {"count": len(pr["threads"]), "value": pr["threads"]}
        if rest == "/threads" and method == "POST":
            self._thread_id += 1
            t = {"id": self._thread_id, "status": body.get("status", "active"), "threadContext": body.get("threadContext"),
                 "pullRequestThreadContext": body.get("pullRequestThreadContext"), "isDeleted": False, "properties": {},
                 "comments": [dict(c, id=i + 1, author={"id": BOT_ID}, commentType="text") for i, c in enumerate(body["comments"])]}
            pr["threads"].append(t)
            return 200, t
        mt = re.match(r"^/threads/(\d+)$", rest)
        if mt and method == "PATCH":
            t = next(x for x in pr["threads"] if x["id"] == int(mt.group(1)))
            t.update({k: v for k, v in body.items() if k in ("status",)})
            return 200, t
        mc = re.match(r"^/threads/(\d+)/comments/(\d+)$", rest)
        if mc and method == "PATCH":
            t = next(x for x in pr["threads"] if x["id"] == int(mc.group(1)))
            c = next(x for x in t["comments"] if x["id"] == int(mc.group(2)))
            c["content"] = body["content"]
            return 200, c
        if rest == "/statuses" and method == "GET":
            return 200, {"count": len(pr["statuses"]), "value": pr["statuses"]}
        if rest == "/statuses" and method == "POST":
            s = dict(body, id=len(pr["statuses"]) + 1, createdBy={"id": BOT_ID})
            pr["statuses"].append(s)
            return 200, s
        if rest == "/reviewers" and method == "GET":
            return 200, {"count": len(pr["reviewers"]), "value": pr["reviewers"]}
        mr = re.match(r"^/reviewers/([0-9a-f-]+)$", rest)
        if mr and method == "PUT":
            self.set_vote(pr["id"], mr.group(1), int(body["vote"]), "eh-id-pr-reviewer")
            return 200, next(x for x in pr["reviewers"] if x["id"] == mr.group(1))
        return 404, {"message": f"unhandled {method} {rest}"}

    # -------------------------------------------------------------- helpers for assertions
    def bot_vote(self, pr_id: int) -> Optional[int]:
        r = next((x for x in self.prs[pr_id]["reviewers"] if x["id"] == BOT_ID), None)
        return None if r is None else r["vote"]

    def latest_status(self, pr_id: int) -> Optional[dict]:
        pr = self.prs[pr_id]
        it = pr["iterations"][-1]["id"]
        ours = [s for s in pr["statuses"] if s.get("iterationId") == it]
        return ours[-1] if ours else None
