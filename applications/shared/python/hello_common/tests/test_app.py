import asyncio
import re

from fastapi.testclient import TestClient

from hello_common.app import create_app
from hello_common.config import ServiceInfo
from hello_common.problems import Problem

INFO = ServiceInfo(service="appsvc", version="3.1.0", env="test", commit="deadbeef", build_time="2026-10-09T00:00:00Z")


def test_health_version_and_traceparent(spans):
    app = create_app(INFO, readiness={"ok": lambda: None})

    @app.get("/thing")
    async def thing():
        return {"x": 1}

    c = TestClient(app)
    assert c.get("/healthz").json() == {"status": "ok"}
    v = c.get("/version").json()
    assert v["service"] == "appsvc" and v["version"] == "3.1.0" and v["commit"] == "deadbeef" and v["runtime"].startswith("python")
    incoming = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
    r = c.get("/thing", headers={"traceparent": incoming})
    assert re.fullmatch(r"00-0af7651916cd43dd8448eb211c80319c-[0-9a-f]{16}-01", r.headers["traceparent"])
    server = [s for s in spans() if s.kind.name == "SERVER"]
    assert server and server[-1].context.trace_id == int("0af7651916cd43dd8448eb211c80319c", 16)
    assert server[-1].parent.span_id == int("b7ad6b7169203331", 16)


def test_readyz_reports_failures_and_timeouts(monkeypatch):
    import hello_common.app as appmod

    monkeypatch.setattr(appmod, "READINESS_TIMEOUT_SECONDS", 0.2)

    async def slow():
        await asyncio.sleep(1)

    def broken():
        raise ConnectionError("db down")

    c = TestClient(create_app(INFO, readiness={"db": broken, "cache": slow, "fine": lambda: {"detail": "x"}}))
    r = c.get("/readyz")
    assert r.status_code == 503
    body = r.json()
    assert body["checks"]["db"]["status"] == "fail" and "db down" in body["checks"]["db"]["error"]
    assert "timeout" in body["checks"]["cache"]["error"]
    assert body["checks"]["fine"]["status"] == "ok"
    ok = TestClient(create_app(INFO, readiness={"fine": lambda: None})).get("/readyz")
    assert ok.status_code == 200 and ok.json()["status"] == "ready"


def test_problem_json_for_errors():
    app = create_app(INFO)

    @app.get("/teapot")
    async def teapot():
        raise Problem(418, detail="short and stout", hint="tip")

    @app.get("/crash")
    async def crash():
        raise RuntimeError("password=supersecret")

    c = TestClient(app, raise_server_exceptions=False)
    r = c.get("/teapot")
    assert r.status_code == 418 and r.headers["content-type"] == "application/problem+json"
    assert r.json()["detail"] == "short and stout" and r.json()["hint"] == "tip"
    r = c.get("/missing")
    assert r.status_code == 404 and r.json()["status"] == 404
    r = c.get("/crash")
    assert r.status_code == 500 and "supersecret" not in r.text
