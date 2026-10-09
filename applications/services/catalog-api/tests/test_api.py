from decimal import Decimal

from fastapi.testclient import TestClient

from hello_catalog import settings as settings_mod
from hello_catalog.cache import CatalogCache
from hello_catalog.main import build_app
from hello_catalog.repository import InMemoryRepository
from hello_catalog.seed import seed_products

from conftest import FakeRedis, redis_settings


def _client(redis=None, enabled=True):
    s = settings_mod.load()
    rs = redis_settings() if enabled else redis_settings(host=None)
    cache = CatalogCache(rs, client=redis if enabled else None)
    repo = InMemoryRepository()
    app = build_app(s, repo=repo, cache=cache)
    return TestClient(app), repo, redis


def test_seed_is_deterministic():
    a, b = seed_products(), seed_products()
    assert [p.model_dump() for p in a] == [p.model_dump() for p in b]
    assert len(a) == 20 and a[0].sku == "SKU-0001" and a[-1].sku == "SKU-0020"
    assert all(p.unit_price > 0 for p in a)
    assert a[0].unit_price == Decimal("12.35")


def test_cache_aside_miss_then_hit():
    c, repo, redis = _client(FakeRedis())
    with c:
        assert c.post("/seed").json()["seeded"] == 20
        r1 = c.get("/products/SKU-0003")
        assert r1.status_code == 200 and r1.headers["X-Cache"] == "MISS"
        r2 = c.get("/products/SKU-0003")
        assert r2.headers["X-Cache"] == "HIT" and r2.json()["sku"] == "SKU-0003"
        assert repo.reads == 1
        assert redis.ttl["catalog:product:SKU-0003"] == 60


def test_upsert_invalidates_cache_and_is_idempotent():
    c, _, redis = _client(FakeRedis())
    with c:
        c.post("/seed")
        c.get("/products/SKU-0001")
        body = {"sku": "SKU-0001", "name": "Renamed", "unit_price": "9.99"}
        r = c.post("/products", json=body, headers={"Idempotency-Key": "k-1"})
        assert r.status_code == 200 and r.json()["name"] == "Renamed"
        assert "catalog:product:SKU-0001" not in redis.data
        assert c.post("/products", json=body, headers={"Idempotency-Key": "k-1"}).json() == r.json()
        assert c.post("/products", json={**body, "name": "x"}, headers={"Idempotency-Key": "k-1"}).status_code == 422
        assert c.get("/products/SKU-0001").json()["name"] == "Renamed"


def test_bypass_when_cache_disabled_or_down():
    c, _, _ = _client(enabled=False)
    with c:
        c.post("/seed")
        assert c.get("/products/SKU-0002").headers["X-Cache"] == "BYPASS"
        assert c.get("/readyz").status_code == 200
    c2, _, _ = _client(FakeRedis(fail=True))
    with c2:
        c2.post("/seed")
        r = c2.get("/products/SKU-0002")
        assert r.status_code == 200 and r.headers["X-Cache"] == "BYPASS"
        ready = c2.get("/readyz").json()
        assert "degraded" in ready["checks"]["redis"]["detail"]


def test_list_404_and_validation():
    c, _, _ = _client(FakeRedis())
    with c:
        c.post("/seed")
        lst = c.get("/products", params={"limit": 5}).json()
        assert lst["count"] == 5 and lst["items"][0]["sku"] == "SKU-0001"
        assert c.get("/products", params={"category": "tools"}).json()["count"] == 5
        nf = c.get("/products/SKU-9999")
        assert nf.status_code == 404 and nf.headers["content-type"] == "application/problem+json"
        assert c.get("/products/bad sku").status_code == 400
        assert c.post("/products", json={"sku": "SKU-1", "name": "x", "unit_price": -1}).status_code == 422


def test_db_error_fault_returns_503(monkeypatch):
    from hello_common.faults import REGISTRY

    c, _, _ = _client(FakeRedis())
    with c:
        c.post("/seed")
        REGISTRY.add("db_error", 1.0, 30)
        r = c.get("/products")
        assert r.status_code == 503 and r.json()["fault"] == "db_error"
        assert c.get("/readyz").status_code == 503


def test_version_endpoint():
    c, _, _ = _client(FakeRedis())
    with c:
        v = c.get("/version").json()
        assert v["service"] == "hello-catalog-api" and v["version"] == "1.0.0-test"
