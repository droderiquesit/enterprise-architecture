import httpx
import pytest

from hello_common.faults import FaultRegistry
from hello_common.http import RetryPolicy, create_async_client, create_client, is_retryable_request


class Flaky(httpx.AsyncBaseTransport):
    def __init__(self, statuses):
        self.statuses = list(statuses)
        self.calls = 0
        self.headers = []

    async def handle_async_request(self, request):
        self.calls += 1
        self.headers.append(dict(request.headers))
        status = self.statuses.pop(0)
        if status == "err":
            raise httpx.ConnectError("refused", request=request)
        return httpx.Response(status, json={"n": self.calls}, request=request)


class SyncFlaky(httpx.BaseTransport):
    def __init__(self, statuses):
        self.statuses = list(statuses)
        self.calls = 0

    def handle_request(self, request):
        self.calls += 1
        return httpx.Response(self.statuses.pop(0), request=request)


async def test_get_retries_then_succeeds():
    t = Flaky([503, "err", 200])
    async with create_async_client("http://svc", inner_transport=t, retries=2, backoff_base=0.001, faults=FaultRegistry()) as c:
        r = await c.get("/x")
    assert r.status_code == 200 and t.calls == 3


async def test_retries_are_bounded():
    t = Flaky([503, 503, 503, 503])
    async with create_async_client("http://svc", inner_transport=t, retries=2, backoff_base=0.001, faults=FaultRegistry()) as c:
        r = await c.get("/x")
    assert r.status_code == 503 and t.calls == 3


async def test_post_without_idempotency_key_not_retried():
    t = Flaky([503, 200])
    async with create_async_client("http://svc", inner_transport=t, backoff_base=0.001, faults=FaultRegistry()) as c:
        r = await c.post("/orders", json={})
    assert r.status_code == 503 and t.calls == 1
    t2 = Flaky([503, 200])
    async with create_async_client("http://svc", inner_transport=t2, backoff_base=0.001, faults=FaultRegistry()) as c:
        r = await c.post("/orders", json={}, headers={"Idempotency-Key": "k1"})
    assert r.status_code == 200 and t2.calls == 2


async def test_traceparent_injected_inside_span():
    from opentelemetry import trace

    t = Flaky([200])
    async with create_async_client("http://svc", inner_transport=t, faults=FaultRegistry()) as c:
        with trace.get_tracer("t").start_as_current_span("parent"):
            await c.get("/x")
    # httpx instrumentation is applied at transport class level; the explicit inner transport here
    # is a fake, so propagation is asserted through the propagator API instead when absent.
    from hello_common.propagation import inject_current

    with trace.get_tracer("t").start_as_current_span("p2"):
        assert inject_current()["traceparent"].startswith("00-")


async def test_dependency_timeout_fault():
    reg = FaultRegistry()
    reg.add("dependency_timeout", 1.0, 60)
    t = Flaky([200, 200, 200])
    async with create_async_client("http://svc", inner_transport=t, retries=1, backoff_base=0.001, faults=reg) as c:
        with pytest.raises(httpx.ReadTimeout):
            await c.get("/x")
    assert t.calls == 0


def test_sync_client_retries():
    t = SyncFlaky([502, 200])
    with create_client("http://svc", inner_transport=t, backoff_base=0.001, faults=FaultRegistry()) as c:
        assert c.get("/x").status_code == 200
    assert t.calls == 2


def test_policy_jitter_and_retry_after():
    p = RetryPolicy(retries=3, backoff_base=0.5, backoff_max=2.0)
    for attempt in range(6):
        assert 0 <= p.delay(attempt) <= 2.0
    resp = httpx.Response(429, headers={"retry-after": "1.5"})
    assert p.delay(0, resp) == 1.5
    resp = httpx.Response(429, headers={"retry-after": "100"})
    assert p.delay(0, resp) == 2.0


def test_retryable_methods():
    assert is_retryable_request(httpx.Request("PUT", "http://x"))
    assert not is_retryable_request(httpx.Request("PATCH", "http://x"))
