#!/usr/bin/env python3
"""Send Datadog DORA deployment events for components deployed in this run.

    DD_API_KEY=... python3 tools/report/deployment_marker.py --evidence evidence.json --site datadoghq.com \
        --repository-url <git url> [--out markers.json] [--dry-run]

API: POST https://api.<site>/api/v2/dora/deployment (header DD-API-KEY), body
{"data": {"attributes": {service, env, started_at, finished_at, git: {commit_sha, repository_url},
version, custom_tags}}} (docs.datadoghq.com/api/latest/dora-metrics/). Only components with status
deployed/verified are sent. The API key is read from the environment and never printed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def _epoch(ts: str | None) -> int:
    if not ts:
        return int(time.time())
    return int(dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp())


def payloads(evidence: dict, repository_url: str) -> list[dict]:
    out = []
    for cid, c in sorted(evidence.get("components", {}).items()):
        if c.get("status") not in ("deployed", "verified"):
            continue
        finished = _epoch((c.get("record") or {}).get("finished_at"))
        out.append({"data": {"attributes": {
            "service": cid,
            "env": evidence.get("environment"),
            "started_at": _epoch((c.get("record") or {}).get("started_at")) if (c.get("record") or {}).get("started_at") else finished,
            "finished_at": finished,
            "version": (evidence.get("commit") or "unknown")[:12],
            "git": {"commit_sha": evidence.get("commit"), "repository_url": repository_url},
            "custom_tags": [f"component:{cid}", f"run_id:{evidence.get('run_id')}", "managed_by:azure-pipelines",
                            "application:enterprise-hello"],
        }}})
    return out


def send(site: str, api_key: str, body: dict, attempts: int = 3) -> int:
    url = f"https://api.{site}/api/v2/dora/deployment"
    data = json.dumps(body).encode()
    last = 0
    for i in range(attempts):
        req = urllib.request.Request(url, data=data, method="POST",
                                     headers={"Content-Type": "application/json", "DD-API-KEY": api_key})
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return resp.status
        except urllib.error.HTTPError as exc:
            last = exc.code
            if exc.code < 500 and exc.code != 429:
                return exc.code
        except (urllib.error.URLError, TimeoutError, OSError):
            last = -1
        time.sleep(2 ** i)
    return last


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--evidence", required=True)
    ap.add_argument("--site", default=os.environ.get("DD_SITE", "datadoghq.com"))
    ap.add_argument("--repository-url", required=True)
    ap.add_argument("--out")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    evidence = json.loads(Path(args.evidence).read_text())
    bodies = payloads(evidence, args.repository_url)
    results = []
    api_key = os.environ.get("DD_API_KEY", "")
    for b in bodies:
        svc = b["data"]["attributes"]["service"]
        if args.dry_run or not api_key:
            results.append({"service": svc, "sent": False, "reason": "dry-run" if args.dry_run else "DD_API_KEY not set"})
            continue
        status = send(args.site, api_key, b)
        results.append({"service": svc, "sent": status in (200, 202), "http_status": status})
    if args.out:
        Path(args.out).write_text(json.dumps({"markers": results, "payloads": bodies}, indent=2) + "\n")
    for r in results:
        print(f"{r['service']}: {'sent' if r['sent'] else 'not sent'} {r.get('http_status', r.get('reason', ''))}")
    return 0 if all(r["sent"] for r in results) or args.dry_run else 1


if __name__ == "__main__":
    sys.exit(main())
