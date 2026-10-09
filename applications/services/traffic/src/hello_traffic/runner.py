"""Rate-controlled run: TRAFFIC_BROWSER_JOURNEYS browser journeys + API journeys at TRAFFIC_RPS for
TRAFFIC_DURATION_SECONDS (<= 600). API journeys run on a small thread pool so slow orders do not skew the rate."""

from __future__ import annotations

import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any

from hello_common.telemetry import meter

from .journeys import JourneyResult, api_journey, browser_journey, discover_api_base, make_api_client
from .settings import Settings

log = logging.getLogger("hello_traffic")
_m = meter("hello_traffic")
_journeys = _m.create_counter("hello.traffic.journeys", unit="{journey}", description="Synthetic journeys by kind and outcome")
_duration = _m.create_histogram("hello.traffic.journey.duration", unit="ms")


def _record(r: JourneyResult) -> None:
    outcome = "success" if r.ok else "failure"
    _journeys.add(1, {"journey": r.kind, "outcome": outcome})
    _duration.record(r.duration_ms, {"journey": r.kind, "outcome": outcome})
    (log.info if r.ok else log.warning)("journey finished", extra={"journey": r.kind, "outcome": outcome, "duration_ms": round(r.duration_ms, 1),
                                                                  "detail": r.detail, "order_id": r.order_id})


def run(s: Settings, version: str, *, sleep=time.sleep, clock=time.monotonic, api_journey_fn=api_journey, browser_journey_fn=browser_journey) -> dict[str, Any]:
    results: list[JourneyResult] = []
    api_base = s.api_base_url
    if not api_base and s.frontend_url:
        with make_api_client("", version) as c:
            api_base = discover_api_base(s.frontend_url, c)
    if s.browser_journeys and not s.frontend_url:
        raise ValueError("FRONTEND_URL is required for browser journeys")
    exe = os.environ.get("PW_CHROMIUM_EXECUTABLE") or None
    for _ in range(s.browser_journeys):
        r = browser_journey_fn(s.frontend_url, order_timeout=s.order_timeout, executable_path=exe)
        _record(r)
        results.append(r)
    if api_base and s.rps > 0 and s.duration > 0:
        interval = 1.0 / s.rps
        with make_api_client(api_base, version) as client, ThreadPoolExecutor(max_workers=8) as pool:
            futures = []
            start = clock()
            n = 0
            while clock() - start < s.duration:
                futures.append(pool.submit(api_journey_fn, client, s.skus, order_timeout=s.order_timeout, roundtrip_adapters=s.roundtrip_adapters))
                n += 1
                next_at = start + n * interval
                delay = next_at - clock()
                if delay > 0:
                    sleep(min(delay, max(0.0, s.duration - (clock() - start))))
            for f in futures:
                r = f.result()
                _record(r)
                results.append(r)
    total = len(results)
    failed = sum(1 for r in results if not r.ok)
    return {
        "journeys": total, "failed": failed, "error_ratio": round(failed / total, 3) if total else 0.0,
        "by_kind": {k: sum(1 for r in results if r.kind == k) for k in ("api", "browser")},
        "ok": total == 0 or failed / total <= s.max_error_ratio,
    }
