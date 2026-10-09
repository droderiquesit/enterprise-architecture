#!/usr/bin/env python3
"""Send a deployment marker to Datadog DORA Metrics (POST https://api.<site>/api/v2/dora/deployment).

Why a script: DataDog/datadog Terraform provider 4.25 has no DORA deployment / change-event resource.
Body (docs: https://docs.datadoghq.com/dora_metrics/setup/deployments/):
  {"data": {"attributes": {"service", "started_at", "finished_at" (Unix nanoseconds), "git": {"commit_sha",
   "repository_url"}, "env", "version", "team"?, "id"?, "custom_tags"?}}}
Auth header: DD-API-KEY (from the DD_API_KEY environment variable; never a CLI argument).

Exit codes: 0 sent (or --dry-run), 1 API error, 2 usage error. Retries 3x with backoff on 429/5xx.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

SITES = re.compile(r"^(datadoghq\.com|datadoghq\.eu|us3\.datadoghq\.com|us5\.datadoghq\.com|ap1\.datadoghq\.com|ap2\.datadoghq\.com|ddog-gov\.com)$")


def to_ns(value: str | None) -> int:
    """Accept Unix seconds / ms / ns or ISO-8601; return Unix nanoseconds."""
    if value is None or value == "":
        return time.time_ns()
    v = value.strip()
    if v.isdigit():
        n = int(v)
        if n < 10**11:
            return n * 10**9
        if n < 10**14:
            return n * 10**6
        return n
    dt = datetime.fromisoformat(v.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 10**9)


def build_payload(args: argparse.Namespace) -> dict:
    started, finished = to_ns(args.started_at), to_ns(args.finished_at)
    if finished < started:
        raise ValueError("finished_at is before started_at")
    attrs: dict = {
        "service": args.service, "env": args.env, "version": args.version,
        "started_at": started, "finished_at": finished,
    }
    if args.commit_sha or args.repository_url:
        if not (args.commit_sha and args.repository_url):
            raise ValueError("--commit-sha and --repository-url must be given together")
        attrs["git"] = {"commit_sha": args.commit_sha, "repository_url": args.repository_url}
    if args.team and args.team.strip():
        attrs["team"] = args.team
    if args.id:
        attrs["id"] = args.id
    tags = list(args.tag or [])
    if tags:
        attrs["custom_tags"] = tags
    return {"data": {"attributes": attrs}}


def send(site: str, api_key: str, payload: dict, attempts: int = 3, opener=urllib.request.urlopen, sleep=time.sleep) -> dict:
    req_body = json.dumps(payload).encode()
    url = f"https://api.{site}/api/v2/dora/deployment"
    last = None
    for i in range(attempts):
        req = urllib.request.Request(url, data=req_body, method="POST", headers={
            "DD-API-KEY": api_key, "Content-Type": "application/json", "Accept": "application/json"})
        try:
            with opener(req, timeout=15) as resp:
                return json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as exc:
            last = f"HTTP {exc.code}"
            if exc.code not in (429, 500, 502, 503, 504):
                break
        except urllib.error.URLError as exc:
            last = f"network error: {exc.reason}"
        sleep(2 ** i)
    raise RuntimeError(f"DORA deployment event failed: {last}")


def main(argv: list[str] | None = None, opener=urllib.request.urlopen) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--site", default=os.environ.get("DD_SITE", "datadoghq.com"))
    ap.add_argument("--service", required=True)
    ap.add_argument("--env", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--commit-sha")
    ap.add_argument("--repository-url")
    ap.add_argument("--team")
    ap.add_argument("--id", help="idempotency id (e.g. <pipeline run>-<service>)")
    ap.add_argument("--started-at", help="Unix s/ms/ns or ISO-8601 (default now)")
    ap.add_argument("--finished-at", help="Unix s/ms/ns or ISO-8601 (default now)")
    ap.add_argument("--tag", action="append", help="custom tag key:value (repeatable)")
    ap.add_argument("--dry-run", action="store_true", help="print the payload, send nothing")
    args = ap.parse_args(argv)
    if not SITES.match(args.site):
        print(f"ERROR: unknown Datadog site '{args.site}'", file=sys.stderr)
        return 2
    try:
        payload = build_payload(args)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    if args.dry_run:
        print(json.dumps(payload, indent=2))
        return 0
    api_key = os.environ.get("DD_API_KEY")
    if not api_key:
        print("ERROR: DD_API_KEY is not set", file=sys.stderr)
        return 2
    try:
        resp = send(args.site, api_key, payload, opener=opener)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({"sent": True, "service": args.service, "env": args.env, "version": args.version,
                      "response": resp}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
