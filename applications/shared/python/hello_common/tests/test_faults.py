import random

from fastapi.testclient import TestClient

from hello_common.config import ServiceInfo
from hello_common.app import create_app
from hello_common.faults import FaultInjectedError, FaultRegistry, check_fault

INFO = ServiceInfo(service="faultsvc", version="1", env="test")


def _app(registry=None):
    app = create_app(INFO, fault_registry=registry)

    @app.get("/work")
    async def work():
        return {"ok": True}

    @app.get("/db")
    async def db():
        check_fault("db_error", registry)
        return {"ok": True}

    return app


def test_admin_404_when_disabled(monkeypatch):
    monkeypatch.delenv("FAULTS_ENABLED", raising=False)
    monkeypatch.setenv("FAULT_TOKEN", "t0ken")
    c = TestClient(_app())
    r = c.post("/admin/faults", headers={"X-Fault-Token": "t0ken"}, json={"type": "http_500", "rate": 1, "duration_seconds": 5})
    assert r.status_code == 404
    assert r.headers["content-type"].startswith("application/problem+json")


def test_admin_403_wrong_or_missing_token(monkeypatch):
    monkeypatch.setenv("FAULTS_ENABLED", "true")
    monkeypatch.setenv("FAULT_TOKEN", "t0ken")
    c = TestClient(_app())
    assert c.get("/admin/faults", headers={"X-Fault-Token": "nope"}).status_code == 403
    assert c.get("/admin/faults").status_code == 403
    monkeypatch.setenv("FAULT_TOKEN", "")
    assert c.get("/admin/faults", headers={"X-Fault-Token": ""}).status_code == 403  # fails closed


def test_http_500_fault_lifecycle(monkeypatch):
    monkeypatch.setenv("FAULTS_ENABLED", "true")
    monkeypatch.setenv("FAULT_TOKEN", "t0ken")
    reg = FaultRegistry()
    c = TestClient(_app(reg))
    h = {"X-Fault-Token": "t0ken"}
    r = c.post("/admin/faults", headers=h, json={"type": "http_500", "rate": 1.0, "duration_seconds": 30})
    assert r.status_code == 201 and r.json()["type"] == "http_500"
    assert c.get("/work").status_code == 500
    assert c.get("/healthz").status_code == 200  # probes exempt
    assert len(c.get("/admin/faults", headers=h).json()["faults"]) == 1
    assert c.delete("/admin/faults", headers=h).json() == {"cleared": 1}
    assert c.get("/work").status_code == 200


def test_validation_rejects_long_duration(monkeypatch):
    monkeypatch.setenv("FAULTS_ENABLED", "true")
    monkeypatch.setenv("FAULT_TOKEN", "t0ken")
    c = TestClient(_app())
    r = c.post("/admin/faults", headers={"X-Fault-Token": "t0ken"}, json={"type": "http_500", "rate": 1, "duration_seconds": 901})
    assert r.status_code == 422
    r = c.post("/admin/faults", headers={"X-Fault-Token": "t0ken"}, json={"type": "nuke", "rate": 1, "duration_seconds": 5})
    assert r.status_code == 422


def test_faults_expire():
    now = [1000.0]
    reg = FaultRegistry(clock=lambda: now[0])
    reg.add("latency", 1.0, 10, 5)
    assert reg.check("latency") is not None
    now[0] += 11
    assert reg.check("latency") is None and reg.active() == []


def test_rate_is_probabilistic():
    reg = FaultRegistry(rng=random.Random(1))
    reg.add("db_error", 0.5, 60)
    hits = sum(1 for _ in range(1000) if reg.check("db_error"))
    assert 400 < hits < 600


def test_db_error_hook_maps_to_503(monkeypatch):
    reg = FaultRegistry()
    reg.add("db_error", 1.0, 60)
    c = TestClient(_app(reg))
    r = c.get("/db")
    assert r.status_code == 503 and r.json()["fault"] == "db_error"
    try:
        check_fault("db_error", reg)
    except FaultInjectedError as exc:
        assert exc.fault_type == "db_error"


def test_latency_fault(monkeypatch):
    import time

    reg = FaultRegistry()
    reg.add("latency", 1.0, 60, latency_ms=150)
    c = TestClient(_app(reg))
    t = time.perf_counter()
    assert c.get("/work").status_code == 200
    assert time.perf_counter() - t >= 0.14
