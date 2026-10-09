#!/usr/bin/env python3
"""Azure Automation (Python 3) runbook: Enterprise Hello health probe.

Probes each base URL's /healthz and /readyz with a bounded timeout and prints one JSON line per probe
(ADR-0001 §9 log shape subset). Exits non-zero (job "Failed") when any probe fails. URLs come from the
runbook parameter PROBE_URLS (comma separated) set by the job schedule. Standard library only.
"""
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone


def probe(url: str, timeout: float = 5.0) -> dict:
    start = time.monotonic()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "hello-health-probe/1"}), timeout=timeout) as resp:
            status = resp.status
    except urllib.error.HTTPError as exc:
        status = exc.code
    except Exception as exc:  # noqa: BLE001 - report any network failure as a failed probe
        return {"url": url, "ok": False, "error": type(exc).__name__, "duration_ms": round((time.monotonic() - start) * 1000)}
    return {"url": url, "ok": status == 200, "status": status, "duration_ms": round((time.monotonic() - start) * 1000)}


def main(argv: list[str]) -> int:
    raw = argv[1] if len(argv) > 1 else ""
    bases = [u.strip().rstrip("/") for u in raw.split(",") if u.strip().startswith(("http://", "https://"))]
    failed = 0
    for base in bases:
        for path in ("/healthz", "/readyz"):
            result = probe(base + path)
            failed += 0 if result["ok"] else 1
            print(json.dumps({"timestamp": datetime.now(timezone.utc).isoformat(), "level": "INFO" if result["ok"] else "ERROR",
                              "message": "health probe", "logger": "health-probe", "service": "hello-health-probe", **result}))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
