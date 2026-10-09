#!/usr/bin/env python3
"""HTTP smoke runner: reads endpoints from deployment contracts and polls the common service
contract endpoints (ADR §9: /healthz, /readyz, /version) with bounded retries.

    python3 tools/smoke/smoke.py --env dev --contracts <store> --selection selection.json \
        --out smoke-results.json [--timeout 600] [--interval 10] [--components a,b]

Endpoint discovery in a contract's `data`:
  endpoints: {name: url} or [{name, url}]     (preferred convention for deployment roots)
  any key ending in _url / _endpoint (http/https values) or _fqdn (https://<fqdn>)
Per endpoint the runner waits (bounded by --timeout overall and --attempts per probe) for HTTP 200 on
/healthz and /readyz and a JSON /version answer. Exit 1 when any probe fails or a selected deployment
has no published contract.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.store import open_store  # noqa: E402

PROBES = (("/healthz", False), ("/readyz", False), ("/version", True))


def discover(data, prefix: str = "") -> dict:
    found = {}
    if not isinstance(data, dict):
        return found
    eps = data.get("endpoints")
    if isinstance(eps, dict):
        found.update({f"{prefix}{k}": v for k, v in eps.items() if isinstance(v, str) and v.startswith("http")})
    elif isinstance(eps, list):
        for e in eps:
            if isinstance(e, dict) and str(e.get("url", "")).startswith("http"):
                found[f"{prefix}{e.get('name', e['url'])}"] = e["url"]
    for k, v in data.items():
        if k == "endpoints":
            continue
        if isinstance(v, str):
            if k.endswith(("_url", "_endpoint")) and v.startswith(("http://", "https://")):
                found[f"{prefix}{k}"] = v
            elif k.endswith("_fqdn") and v:
                found[f"{prefix}{k}"] = f"https://{v}"
        elif isinstance(v, dict):
            found.update(discover(v, f"{prefix}{k}."))
    return found


def probe(url: str, want_json: bool, attempts: int, interval: float, deadline: float, timeout: float = 10.0) -> dict:
    last = None
    for i in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "lab-smoke/1"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read(65536)
                if resp.status == 200:
                    if want_json:
                        doc = json.loads(body.decode("utf-8"))
                        return {"url": url, "ok": True, "attempts": i + 1, "version": doc}
                    return {"url": url, "ok": True, "attempts": i + 1}
                last = f"HTTP {resp.status}"
        except urllib.error.HTTPError as exc:
            last = f"HTTP {exc.code}"
        except (urllib.error.URLError, TimeoutError, ConnectionError, json.JSONDecodeError, OSError) as exc:
            last = f"{type(exc).__name__}: {exc}"
        if time.monotonic() + interval > deadline:
            break
        time.sleep(interval)
    return {"url": url, "ok": False, "attempts": i + 1, "error": last}


def select_components(selection: dict, only: list[str]) -> list[str]:
    if only:
        return only
    return sorted(cid for cid, e in selection["components"].items()
                  if e.get("plan") and e.get("apply_candidate") and e.get("layer_name") == "applications"
                  and e.get("kind") == "terraform")


def run(env: str, contracts, selection: dict, only: list[str], timeout: float, interval: float, attempts: int) -> dict:
    deadline = time.monotonic() + timeout
    results = {"env": env, "components": {}, "ok": True}
    for cid in select_components(selection, only):
        entry = selection["components"].get(cid, {})
        produced = entry.get("produces") or [cid]
        envelope = None
        for contract in produced:
            keys = [k for k in contracts.list(f"{env}/{contract}/") if k.endswith(".json")]
            if keys:
                envelope = contracts.get_json(sorted(keys)[-1])
                break
        if envelope is None:
            results["components"][cid] = {"status": "failed", "reason": "no published contract"}
            results["ok"] = False
            continue
        endpoints = discover(envelope.get("data") or {})
        if not endpoints:
            results["components"][cid] = {"status": "skipped", "reason": "contract publishes no HTTP endpoints"}
            continue
        probes = []
        for name, base in sorted(endpoints.items()):
            for path, want_json in PROBES:
                r = probe(base.rstrip("/") + path, want_json, attempts, interval, deadline)
                r["endpoint"] = name
                probes.append(r)
        ok = all(p["ok"] for p in probes)
        results["components"][cid] = {"status": "passed" if ok else "failed", "probes": probes}
        results["ok"] = results["ok"] and ok
    return results


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", required=True)
    ap.add_argument("--contracts", required=True)
    ap.add_argument("--selection", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--components", default="")
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--interval", type=float, default=10)
    ap.add_argument("--attempts", type=int, default=12)
    args = ap.parse_args(argv)
    selection = json.loads(Path(args.selection).read_text())
    only = [c for c in args.components.split(",") if c]
    results = run(args.env, open_store(args.contracts), selection, only, args.timeout, args.interval, args.attempts)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
    for cid, r in results["components"].items():
        print(f"{cid}: {r['status']} {r.get('reason', '')}")
    return 0 if results["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
