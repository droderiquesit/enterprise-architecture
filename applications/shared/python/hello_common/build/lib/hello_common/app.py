"""FastAPI application factory implementing the common Enterprise Hello service contract.

* GET /healthz  - liveness: 200 whenever the process is serving.
* GET /readyz   - runs every registered readiness check concurrently with a 2 s timeout each;
                  503 problem+json listing the failing checks.
* GET /version  - {"service","version","commit","build_time","runtime"}.
* /admin/faults - fault injection (hello_common.faults), default disabled.
* W3C trace context in (FastAPI instrumentation) and out (``traceparent`` response header).
* One structured access-log line per request (health probes logged at DEBUG only).
"""

from __future__ import annotations

import asyncio
import inspect
import logging
import time
from collections.abc import Awaitable, Callable
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from .config import ServiceInfo, listen_port
from .faults import FaultRegistry, install_faults
from .logging import configure_logging
from .problems import install_problem_handlers, problem_response
from .propagation import inject_current
from .telemetry import setup_telemetry

ReadinessCheck = Callable[[], Any] | Callable[[], Awaitable[Any]]
READINESS_TIMEOUT_SECONDS = 2.0
_PROBE_PATHS = frozenset({"/healthz", "/readyz", "/version"})

access_log = logging.getLogger("hello.access")


def bootstrap(info: ServiceInfo) -> None:
    """Logging + telemetry, once per process (safe to call repeatedly)."""
    configure_logging(info)
    setup_telemetry(info)


async def _run_check(name: str, check: ReadinessCheck, limit_s: float) -> dict[str, Any]:
    started = time.perf_counter()
    try:
        if inspect.iscoroutinefunction(check):
            result = await asyncio.wait_for(check(), limit_s)
        else:
            result = await asyncio.wait_for(asyncio.to_thread(check), limit_s)
            if inspect.isawaitable(result):
                result = await asyncio.wait_for(result, limit_s)
        doc: dict[str, Any] = {"status": "ok"}
        if isinstance(result, dict):
            doc.update(result)
    except TimeoutError:
        doc = {"status": "fail", "error": f"timeout after {limit_s:.0f}s"}
    except Exception as exc:  # readiness must report, never raise
        doc = {"status": "fail", "error": f"{type(exc).__name__}: {exc}"[:300]}
    doc["duration_ms"] = round((time.perf_counter() - started) * 1000, 1)
    return {name: doc}


def create_app(
    info: ServiceInfo,
    *,
    readiness: dict[str, ReadinessCheck] | None = None,
    lifespan: Any = None,
    title: str | None = None,
    fault_registry: FaultRegistry | None = None,
    instrument: bool = True,
) -> FastAPI:
    bootstrap(info)
    app = FastAPI(title=title or info.service, version=info.version, lifespan=lifespan, docs_url="/docs", redoc_url=None)
    app.state.service_info = info
    app.state.readiness = dict(readiness or {})

    install_problem_handlers(app)
    install_faults(app, fault_registry)

    @app.middleware("http")
    async def _access_log_and_traceparent(request: Request, call_next):
        started = time.perf_counter()
        response = None
        try:
            response = await call_next(request)
            return response
        finally:
            duration_ms = round((time.perf_counter() - started) * 1000, 2)
            status = response.status_code if response is not None else 500
            if response is not None:
                carrier = inject_current()
                if "traceparent" in carrier:
                    response.headers["traceparent"] = carrier["traceparent"]
            route = request.scope.get("route")
            fields = {
                "http.method": request.method,
                "http.route": getattr(route, "path", request.url.path),
                "http.status_code": status,
                "duration_ms": duration_ms,
                "network.client.ip": request.client.host if request.client else None,
                "http.useragent": (request.headers.get("user-agent") or "")[:200],
            }
            level = logging.DEBUG if request.url.path in _PROBE_PATHS else (logging.WARNING if status >= 500 else logging.INFO)
            access_log.log(level, "%s %s %s", request.method, fields["http.route"], status, extra=fields)

    @app.get("/healthz", tags=["health"])
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/readyz", tags=["health"])
    async def readyz():
        checks = app.state.readiness
        results: dict[str, Any] = {}
        for item in await asyncio.gather(*(_run_check(n, c, READINESS_TIMEOUT_SECONDS) for n, c in checks.items())):
            results.update(item)
        failed = sorted(name for name, doc in results.items() if doc["status"] != "ok")
        if failed:
            return problem_response(503, "Not Ready", f"failing checks: {', '.join(failed)}", instance="/readyz", checks=results)
        return JSONResponse({"status": "ready", "checks": results})

    @app.get("/version", tags=["health"])
    async def version() -> dict[str, str]:
        return info.version_document()

    if instrument:
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

        FastAPIInstrumentor.instrument_app(app, excluded_urls="healthz,readyz,version")
    return app


def run(app: FastAPI, port: int | None = None, host: str = "0.0.0.0") -> None:  # noqa: S104 - containers listen on all interfaces
    import uvicorn

    uvicorn.run(
        app,
        host=host,
        port=port or listen_port(),
        log_config=None,
        access_log=False,
        proxy_headers=True,
        forwarded_allow_ips="*",
        timeout_graceful_shutdown=20,
        timeout_keep_alive=30,
    )
