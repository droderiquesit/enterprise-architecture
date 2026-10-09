import httpx
from fastapi.testclient import TestClient

from fake_bff import build
from hello_traffic.journeys import api_journey, discover_api_base, synthetic_headers
from hello_traffic.runner import run
from hello_traffic.settings import Settings, load


def _client(app):
    return TestClient(app, headers=synthetic_headers("t"))


def test_api_journey_fulfilled_with_idempotency_and_marker():
    app = build()
    with _client(app) as c:
        r = api_journey(c, ["SKU-0001"], poll_interval=0, roundtrip_adapters=True, sleep=lambda s: None)
    assert r.ok and r.final_status == "Fulfilled" and r.order_id
    post = [x for x in app.state.requests if x["method"] == "POST" and x["path"] == "/api/orders"][0]
    assert post["headers"]["idempotency-key"] and post["headers"]["x-synthetic"] == "hello-traffic"
    assert any(x["path"] == "/api/adapters/memory/roundtrip" for x in app.state.requests)


def test_api_journey_reports_failed_orders_and_errors():
    with _client(build(fail_sku="SKU-0002")) as c:
        r = api_journey(c, ["SKU-0002"], poll_interval=0, sleep=lambda s: None)
    assert not r.ok and r.final_status == "Failed"
    broken = httpx.Client(transport=httpx.MockTransport(lambda req: httpx.Response(503)), base_url="http://x")
    r2 = api_journey(broken, ["SKU-0001"], sleep=lambda s: None)
    assert not r2.ok and "HTTPStatusError" in r2.detail


def test_discover_api_base_from_frontend_config():
    t = httpx.MockTransport(lambda req: httpx.Response(200, json={"apiBaseUrl": "https://bff.example.com/"}))
    assert discover_api_base("https://fe.example.com/", httpx.Client(transport=t)) == "https://bff.example.com"
    t2 = httpx.MockTransport(lambda req: httpx.Response(200, json={"apiBaseUrl": ""}))
    assert discover_api_base("https://fe.example.com", httpx.Client(transport=t2)) == "https://fe.example.com"


def test_runner_rate_and_duration_are_bounded(monkeypatch):
    now = [0.0]
    calls = []

    def fake_api(client, skus, **kw):
        from hello_traffic.journeys import JourneyResult

        calls.append(now[0])
        return JourneyResult("api", len(calls) != 3, 5.0)

    s = Settings(frontend_url=None, api_base_url="http://bff", rps=0.5, duration=10, browser_journeys=0, order_timeout=5,
                 max_error_ratio=0.5, roundtrip_adapters=False, skus=["SKU-0001"])
    out = run(s, "t", sleep=lambda d: now.__setitem__(0, now[0] + d), clock=lambda: now[0], api_journey_fn=fake_api)
    assert out["journeys"] == 5 and len(calls) == 5 and now[0] <= 10.0  # 0.5 rps x 10 s, bounded by duration
    assert out["failed"] == 1 and out["ok"] is True


def test_settings_caps(monkeypatch):
    monkeypatch.setenv("TRAFFIC_DURATION_SECONDS", "600")
    assert load().duration == 600 and load().rps == 0.2 and load().browser_journeys == 2
    monkeypatch.setenv("TRAFFIC_DURATION_SECONDS", "601")
    import pytest

    from hello_common.config import ConfigError

    with pytest.raises(ConfigError):
        load()
