import pytest
from opentelemetry import trace

from hello_common.azure_auth import TokenCache
from hello_common.idempotency import IdempotencyCache, IdempotencyConflict, InvalidIdempotencyKey, validate_key
from hello_common.propagation import links_from_properties, normalize_properties, parse_traceparent
from hello_common.telemetry import ALLOWED_METRIC_ATTRIBUTES, build_resource
from hello_common.config import ServiceInfo


def test_parse_traceparent_and_links():
    tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    ctx = parse_traceparent(tp)
    assert ctx.trace_id == int("4bf92f3577b34da6a3ce929d0e0e4736", 16) and ctx.is_remote
    assert parse_traceparent("garbage") is None
    assert parse_traceparent("00-00000000000000000000000000000000-00f067aa0ba902b7-01") is None
    links = links_from_properties({b"traceparent": tp.encode(), b"tracestate": b"dd=s:1"})
    assert len(links) == 1 and links[0].context.span_id == int("00f067aa0ba902b7", 16)
    assert links_from_properties({"Diagnostic-Id": tp})[0].context.trace_id == ctx.trace_id
    assert links_from_properties({}) == []
    assert normalize_properties({b"a": b"b", "c": 1}) == {"a": "b", "c": "1"}


def test_consumer_span_link_not_parent(spans):
    tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    from opentelemetry.context import Context

    with trace.get_tracer("t").start_as_current_span("consume", context=Context(), links=links_from_properties({"traceparent": tp})):
        pass
    s = [x for x in spans() if x.name == "consume"][0]
    assert s.parent is None
    assert s.context.trace_id != int("4bf92f3577b34da6a3ce929d0e0e4736", 16)
    assert s.links[0].context.trace_id == int("4bf92f3577b34da6a3ce929d0e0e4736", 16)


def test_idempotency_cache():
    now = [0.0]
    cache = IdempotencyCache(ttl_seconds=10, max_entries=2, clock=lambda: now[0])
    assert cache.lookup("orders", "k", {"a": 1}) is None
    cache.store("orders", "k", {"a": 1}, 202, {"id": "1"})
    assert cache.lookup("orders", "k", {"a": 1}).body == {"id": "1"}
    with pytest.raises(IdempotencyConflict):
        cache.lookup("orders", "k", {"a": 2})
    now[0] = 11
    assert cache.lookup("orders", "k", {"a": 1}) is None
    for i in range(3):
        cache.store("s", str(i), {}, 200, i)
    assert cache.lookup("s", "0", {}) is None
    with pytest.raises(InvalidIdempotencyKey):
        validate_key("has space")
    assert validate_key(" abc ") == "abc"


def test_token_cache_refreshes_before_expiry():
    class Cred:
        calls = 0

        def get_token(self, scope):
            Cred.calls += 1

            class T:
                token = f"tok{Cred.calls}"
                expires_on = now[0] + 3600

            return T()

    now = [0.0]
    cache = TokenCache("scope/.default", Cred(), clock=lambda: now[0])
    assert cache.get() == "tok1"
    now[0] = 3000
    assert cache.get() == "tok1"
    now[0] = 3301
    assert cache.get() == "tok2"


def test_resource_attributes(monkeypatch):
    monkeypatch.setenv("OTEL_RESOURCE_ATTRIBUTES", "team=hello,domain=commerce,tier=backend")
    attrs = build_resource(ServiceInfo("svc", "1.0", "dev")).attributes
    assert attrs["service.name"] == "svc" and attrs["service.namespace"] == "enterprise-hello"
    assert attrs["deployment.environment.name"] == "dev" and attrs["deployment.environment"] == "dev"
    assert attrs["team"] == "hello" and attrs["tier"] == "backend"
    assert "order_id" not in ALLOWED_METRIC_ATTRIBUTES and "url.full" not in ALLOWED_METRIC_ATTRIBUTES
