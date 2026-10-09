"""Resilient httpx client factory: timeouts, pooled connections, bounded retries with full jitter.

Retries happen only for *idempotent* requests: GET, HEAD, OPTIONS, PUT, DELETE, and POST/PATCH
that carry an ``Idempotency-Key`` header. Retried conditions: connection errors, timeouts, and
HTTP 429/502/503/504 (``Retry-After`` honoured up to ``backoff_max``). Each attempt is its own
OTel client span (httpx instrumentation) and the W3C ``traceparent`` is injected automatically.

The ``dependency_timeout`` fault (hello_common.faults) is applied here: when it fires, the attempt
raises ``httpx.ReadTimeout`` without touching the network.
"""

from __future__ import annotations

import asyncio
import email.utils
import logging
import random
import time
from dataclasses import dataclass

import httpx

from .faults import REGISTRY, FaultRegistry

log = logging.getLogger("hello_common.http")

IDEMPOTENT_METHODS = frozenset({"GET", "HEAD", "OPTIONS", "PUT", "DELETE"})
RETRY_STATUS = frozenset({429, 502, 503, 504})


@dataclass(frozen=True)
class RetryPolicy:
    retries: int = 2
    backoff_base: float = 0.2
    backoff_max: float = 2.0

    def delay(self, attempt: int, response: httpx.Response | None = None, rng: random.Random | None = None) -> float:
        if response is not None:
            retry_after = _retry_after_seconds(response.headers.get("retry-after"))
            if retry_after is not None:
                return min(retry_after, self.backoff_max)
        cap = min(self.backoff_max, self.backoff_base * (2**attempt))
        return (rng or random).uniform(0, cap)  # full jitter


def _retry_after_seconds(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return max(0.0, float(value))
    except ValueError:
        try:
            dt = email.utils.parsedate_to_datetime(value)
            return max(0.0, dt.timestamp() - time.time())
        except Exception:
            return None


def is_retryable_request(request: httpx.Request) -> bool:
    method = request.method.upper()
    if method in IDEMPOTENT_METHODS:
        return True
    return method in ("POST", "PATCH") and bool(request.headers.get("idempotency-key"))


class RetryingAsyncTransport(httpx.AsyncBaseTransport):
    def __init__(self, inner: httpx.AsyncBaseTransport, policy: RetryPolicy, faults: FaultRegistry | None = None) -> None:
        self.inner = inner
        self.policy = policy
        self.faults = faults or REGISTRY

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        retryable = is_retryable_request(request)
        attempt = 0
        while True:
            try:
                if self.faults.check("dependency_timeout") is not None:
                    raise httpx.ReadTimeout("injected fault: dependency_timeout", request=request)
                response = await self.inner.handle_async_request(request)
            except (httpx.TransportError,) as exc:
                if not retryable or attempt >= self.policy.retries:
                    raise
                delay = self.policy.delay(attempt)
                log.info("retrying request after transport error", extra={"http.method": request.method, "attempt": attempt + 1, "error.kind": type(exc).__name__})
                await asyncio.sleep(delay)
                attempt += 1
                continue
            if retryable and response.status_code in RETRY_STATUS and attempt < self.policy.retries:
                delay = self.policy.delay(attempt, response)
                await response.aclose()
                log.info("retrying request after status", extra={"http.method": request.method, "attempt": attempt + 1, "http.status_code": response.status_code})
                await asyncio.sleep(delay)
                attempt += 1
                continue
            return response

    async def aclose(self) -> None:
        await self.inner.aclose()


class RetryingTransport(httpx.BaseTransport):
    def __init__(self, inner: httpx.BaseTransport, policy: RetryPolicy, faults: FaultRegistry | None = None) -> None:
        self.inner = inner
        self.policy = policy
        self.faults = faults or REGISTRY

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        retryable = is_retryable_request(request)
        attempt = 0
        while True:
            try:
                if self.faults.check("dependency_timeout") is not None:
                    raise httpx.ReadTimeout("injected fault: dependency_timeout", request=request)
                response = self.inner.handle_request(request)
            except httpx.TransportError:
                if not retryable or attempt >= self.policy.retries:
                    raise
                time.sleep(self.policy.delay(attempt))
                attempt += 1
                continue
            if retryable and response.status_code in RETRY_STATUS and attempt < self.policy.retries:
                delay = self.policy.delay(attempt, response)
                response.close()
                time.sleep(delay)
                attempt += 1
                continue
            return response

    def close(self) -> None:
        self.inner.close()


def _timeout(timeout: float, connect_timeout: float | None) -> httpx.Timeout:
    return httpx.Timeout(timeout, connect=connect_timeout if connect_timeout is not None else min(timeout, 2.0))


def _limits(max_connections: int, max_keepalive: int) -> httpx.Limits:
    return httpx.Limits(max_connections=max_connections, max_keepalive_connections=max_keepalive, keepalive_expiry=30.0)


def create_async_client(
    base_url: str = "",
    *,
    timeout: float = 5.0,
    connect_timeout: float | None = None,
    retries: int = 2,
    backoff_base: float = 0.2,
    backoff_max: float = 2.0,
    max_connections: int = 50,
    max_keepalive: int = 20,
    headers: dict[str, str] | None = None,
    inner_transport: httpx.AsyncBaseTransport | None = None,
    faults: FaultRegistry | None = None,
) -> httpx.AsyncClient:
    inner = inner_transport or httpx.AsyncHTTPTransport(limits=_limits(max_connections, max_keepalive), retries=0)
    transport = RetryingAsyncTransport(inner, RetryPolicy(retries, backoff_base, backoff_max), faults)
    return httpx.AsyncClient(base_url=base_url, timeout=_timeout(timeout, connect_timeout), transport=transport, headers=headers, follow_redirects=False)


def create_client(
    base_url: str = "",
    *,
    timeout: float = 5.0,
    connect_timeout: float | None = None,
    retries: int = 2,
    backoff_base: float = 0.2,
    backoff_max: float = 2.0,
    max_connections: int = 20,
    max_keepalive: int = 10,
    headers: dict[str, str] | None = None,
    inner_transport: httpx.BaseTransport | None = None,
    faults: FaultRegistry | None = None,
) -> httpx.Client:
    inner = inner_transport or httpx.HTTPTransport(limits=_limits(max_connections, max_keepalive), retries=0)
    transport = RetryingTransport(inner, RetryPolicy(retries, backoff_base, backoff_max), faults)
    return httpx.Client(base_url=base_url, timeout=_timeout(timeout, connect_timeout), transport=transport, headers=headers, follow_redirects=False)
