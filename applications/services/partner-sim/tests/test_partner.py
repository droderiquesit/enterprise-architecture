import random

from fastapi.testclient import TestClient

from hello_partner_sim.main import build_app


def test_payment_is_idempotent_by_order():
    c = TestClient(build_app())
    r1 = c.post("/payments", json={"order_id": "o-1", "amount": 12.5})
    assert r1.status_code == 201 and r1.json()["status"] == "approved" and r1.json()["payment_id"].startswith("pay_")
    r2 = c.post("/payments", json={"order_id": "o-1", "amount": 12.5})
    assert r2.status_code == 200 and r2.headers["Idempotent-Replayed"] == "true" and r2.json() == r1.json()
    assert c.post("/payments", json={"order_id": "o-1", "amount": 99}).status_code == 409
    assert c.get(f"/payments/{r1.json()['payment_id']}").json()["order_id"] == "o-1"
    assert c.get("/payments/pay_missing").status_code == 404


def test_decline_rules(monkeypatch):
    c = TestClient(build_app())
    assert c.post("/payments", json={"order_id": "big", "amount": 20000}).json()["status"] == "declined"
    monkeypatch.setenv("PARTNER_DECLINE_RATE", "1")
    c2 = TestClient(build_app())
    assert c2.post("/payments", json={"order_id": "x", "amount": 1}).json()["status"] == "declined"


def test_transient_failure_not_recorded(monkeypatch):
    monkeypatch.setenv("PARTNER_FAILURE_RATE", "1")
    c = TestClient(build_app(random.Random(7)))
    r = c.post("/payments", json={"order_id": "o-2", "amount": 5})
    assert r.status_code == 503 and r.headers["content-type"] == "application/problem+json"
    assert c.app.state.store.get_order("o-2") is None


def test_validation_and_contract_endpoints():
    c = TestClient(build_app())
    assert c.post("/payments", json={"order_id": "", "amount": 1}).status_code == 422
    assert c.post("/payments", json={"order_id": "a", "amount": -1}).status_code == 422
    assert c.get("/healthz").status_code == 200 and c.get("/readyz").status_code == 200
    assert c.get("/version").json()["service"] == "hello-partner-sim"


def test_store_is_bounded(monkeypatch):
    monkeypatch.setenv("PARTNER_MAX_PAYMENTS", "10")
    c = TestClient(build_app())
    for i in range(15):
        c.post("/payments", json={"order_id": f"o{i}", "amount": 1})
    assert len(c.app.state.store.by_order) == 10 and len(c.app.state.store.by_id) == 10
