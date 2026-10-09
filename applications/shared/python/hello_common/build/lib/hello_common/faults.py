"""Authenticated, auto-expiring, default-disabled fault injection (ADR-0001 §9).

Admin API (mounted by ``create_app``):

POST   /admin/faults   header X-Fault-Token, body
                       {"type": "http_500|latency|db_error|dependency_timeout", "rate": 0..1,
                        "latency_ms": int, "duration_seconds": 1..900}
GET    /admin/faults   list active faults
DELETE /admin/faults   clear all faults

* 404 for every admin call unless FAULTS_ENABLED == "true" (the endpoints look absent).
* 403 when the token is missing/wrong, or when FAULT_TOKEN is unset (fails closed). The token is
  compared with ``hmac.compare_digest`` (constant time).
* Every fault expires after ``duration_seconds`` (max 900) - nothing survives a restart either.

Hooks:
* ``http_500`` and ``latency`` are applied by the HTTP middleware to non-admin, non-health routes.
* ``db_error``: data layers call ``check_fault("db_error")`` before touching the database.
* ``dependency_timeout``: the shared httpx client factory raises ``httpx.ReadTimeout`` for
  outbound calls; non-HTTP dependencies call ``check_fault("dependency_timeout")``.
"""

from __future__ import annotations

import asyncio
import hmac
import logging
import os
import random
import threading
import time
import uuid
from dataclasses import asdict, dataclass
from typing import Literal

from fastapi import APIRouter, FastAPI, Header, Request
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field

from .problems import problem_response
from .telemetry import meter

log = logging.getLogger("hello_common.faults")

FaultType = Literal["http_500", "latency", "db_error", "dependency_timeout"]
FAULT_TYPES: tuple[str, ...] = ("http_500", "latency", "db_error", "dependency_timeout")
MAX_DURATION_SECONDS = 900
EXEMPT_PREFIXES = ("/healthz", "/readyz", "/version", "/admin/", "/api/healthz", "/api/version")


class FaultInjectedError(RuntimeError):
    """Raised by hooks when an injected fault fires."""

    def __init__(self, fault_type: str) -> None:
        self.fault_type = fault_type
        super().__init__(f"injected fault: {fault_type}")


@dataclass
class Fault:
    id: str
    type: str
    rate: float
    latency_ms: int
    created_at: float
    expires_at: float

    def public(self, now: float | None = None) -> dict[str, object]:
        now = now or time.time()
        doc = asdict(self)
        doc["remaining_seconds"] = max(0, int(self.expires_at - now))
        return doc


class FaultRegistry:
    def __init__(self, *, clock=time.time, rng: random.Random | None = None) -> None:
        self._faults: list[Fault] = []
        self._lock = threading.Lock()
        self._clock = clock
        self._rng = rng or random.Random()
        self._counter = meter("hello_common.faults").create_counter("hello.faults.injected", unit="{fault}", description="Injected faults that fired")

    def _prune(self) -> None:
        now = self._clock()
        self._faults = [f for f in self._faults if f.expires_at > now]

    def add(self, type_: str, rate: float, duration_seconds: int, latency_ms: int = 0) -> Fault:
        if type_ not in FAULT_TYPES:
            raise ValueError(f"unknown fault type {type_}")
        duration_seconds = max(1, min(int(duration_seconds), MAX_DURATION_SECONDS))
        now = self._clock()
        fault = Fault(
            id=str(uuid.uuid4()),
            type=type_,
            rate=max(0.0, min(float(rate), 1.0)),
            latency_ms=max(0, int(latency_ms)),
            created_at=now,
            expires_at=now + duration_seconds,
        )
        with self._lock:
            self._prune()
            self._faults.append(fault)
        log.warning("fault injection activated", extra={"fault.type": type_, "fault.rate": fault.rate, "fault.duration_seconds": duration_seconds})
        return fault

    def active(self) -> list[Fault]:
        with self._lock:
            self._prune()
            return list(self._faults)

    def clear(self) -> int:
        with self._lock:
            count = len(self._faults)
            self._faults.clear()
        if count:
            log.warning("fault injection cleared", extra={"fault.count": count})
        return count

    def check(self, type_: str) -> Fault | None:
        """Return the firing fault of this type (respecting rate) or None."""
        with self._lock:
            self._prune()
            candidates = [f for f in self._faults if f.type == type_]
        for fault in candidates:
            if fault.rate >= 1.0 or self._rng.random() < fault.rate:
                self._counter.add(1, {"fault.type": type_})
                return fault
        return None


REGISTRY = FaultRegistry()


def check_fault(type_: str, registry: FaultRegistry | None = None) -> None:
    """Hook for data layers: raises FaultInjectedError when a fault of this type fires."""
    if (registry or REGISTRY).check(type_) is not None:
        raise FaultInjectedError(type_)


def faults_enabled() -> bool:
    return (os.environ.get("FAULTS_ENABLED") or "false").strip().lower() == "true"


def token_valid(presented: str | None) -> bool:
    expected = os.environ.get("FAULT_TOKEN") or ""
    if not expected or presented is None:
        return False
    return hmac.compare_digest(presented.encode("utf-8"), expected.encode("utf-8"))


class FaultRequest(BaseModel):
    type: FaultType
    rate: float = Field(1.0, ge=0.0, le=1.0)
    latency_ms: int = Field(1000, ge=0, le=60000)
    duration_seconds: int = Field(60, ge=1, le=MAX_DURATION_SECONDS)


def build_router(registry: FaultRegistry | None = None) -> APIRouter:
    reg = registry or REGISTRY
    router = APIRouter(prefix="/admin", tags=["admin"])

    def _guard(token: str | None) -> Response | None:
        if not faults_enabled():
            return problem_response(404, "Not Found")
        if not token_valid(token):
            return problem_response(403, "Forbidden", "invalid or missing X-Fault-Token")
        return None

    @router.get("/faults")
    async def list_faults(x_fault_token: str | None = Header(default=None)):
        if (denied := _guard(x_fault_token)) is not None:
            return denied
        now = time.time()
        return {"faults": [f.public(now) for f in reg.active()]}

    @router.post("/faults", status_code=201)
    async def add_fault(request: Request, x_fault_token: str | None = Header(default=None)):
        # Guard first so a disabled/unauthenticated caller learns nothing from body validation.
        if (denied := _guard(x_fault_token)) is not None:
            return denied
        try:
            body = FaultRequest.model_validate(await request.json())
        except Exception as exc:
            return problem_response(422, "Validation failed", str(exc).splitlines()[0])
        fault = reg.add(body.type, body.rate, body.duration_seconds, body.latency_ms)
        return JSONResponse(fault.public(), status_code=201)

    @router.delete("/faults")
    async def clear_faults(x_fault_token: str | None = Header(default=None)):
        if (denied := _guard(x_fault_token)) is not None:
            return denied
        return {"cleared": reg.clear()}

    return router


def install_faults(app: FastAPI, registry: FaultRegistry | None = None) -> None:
    reg = registry or REGISTRY
    app.include_router(build_router(reg))

    @app.exception_handler(FaultInjectedError)
    async def _fault_error(request: Request, exc: FaultInjectedError):
        status = 504 if exc.fault_type == "dependency_timeout" else 503
        title = "Dependency timeout (injected)" if status == 504 else "Database error (injected)"
        return problem_response(status, title, str(exc), instance=request.url.path, fault=exc.fault_type)

    @app.middleware("http")
    async def _fault_middleware(request: Request, call_next):
        path = request.url.path
        if not path.startswith(EXEMPT_PREFIXES) and path not in ("/healthz", "/readyz", "/version"):
            latency = reg.check("latency")
            if latency is not None:
                await asyncio.sleep(latency.latency_ms / 1000.0)
            if reg.check("http_500") is not None:
                return problem_response(500, "Internal Server Error (injected)", "fault injection: http_500", instance=path, fault="http_500")
        return await call_next(request)
