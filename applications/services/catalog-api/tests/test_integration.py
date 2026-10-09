"""Integration tests against real postgres:17-alpine and redis:7-alpine containers."""

import pytest
from fastapi.testclient import TestClient

from hello_common.testing import docker_available, run_container

pytestmark = [pytest.mark.integration, pytest.mark.skipif(not docker_available(), reason="docker not available")]

PG_IMAGE = "postgres:17-alpine"
REDIS_IMAGE = "redis:7-alpine"


def _pg_ready(c):
    return (
        c.exec("pg_isready", "-U", "postgres", "-d", "catalog").returncode == 0
        and c.exec("psql", "-U", "postgres", "-d", "catalog", "-c", "select 1").returncode == 0
    )


@pytest.fixture(scope="module")
def stack():
    with (
        run_container(PG_IMAGE, [5432], env={"POSTGRES_PASSWORD": "localonly", "POSTGRES_DB": "catalog"}, ready=_pg_ready) as pg,
        run_container(REDIS_IMAGE, [6379], ready=lambda c: c.exec("redis-cli", "ping").stdout.strip() == "PONG") as rd,
    ):
        yield pg, rd


def _env(monkeypatch, pg, rd):
    monkeypatch.setenv("PG_HOST", pg.host)
    monkeypatch.setenv("PG_PORT", str(pg.port(5432)))
    monkeypatch.setenv("PG_DATABASE", "catalog")
    monkeypatch.setenv("PG_USER", "postgres")
    monkeypatch.setenv("PG_AUTH", "password")
    monkeypatch.setenv("PG_PASSWORD", "localonly")
    monkeypatch.setenv("PG_SSLMODE", "disable")
    monkeypatch.setenv("REDIS_HOST", rd.host)
    monkeypatch.setenv("REDIS_PORT", str(rd.port(6379)))
    monkeypatch.setenv("REDIS_AUTH", "none")
    monkeypatch.setenv("REDIS_TLS", "false")


def test_end_to_end_with_postgres_and_redis(stack, monkeypatch):
    pg, rd = stack
    _env(monkeypatch, pg, rd)
    import time

    from hello_catalog.main import build_app

    with TestClient(build_app()) as c:
        for _ in range(30):
            if c.get("/readyz").status_code == 200:
                break
            time.sleep(0.5)
        ready = c.get("/readyz")
        assert ready.status_code == 200, ready.text
        assert c.post("/seed").json()["seeded"] == 20
        assert c.post("/seed").json()["seeded"] == 20  # idempotent
        lst = c.get("/products", params={"limit": 100}).json()
        assert lst["count"] == 20
        r1 = c.get("/products/SKU-0007")
        r2 = c.get("/products/SKU-0007")
        assert (r1.headers["X-Cache"], r2.headers["X-Cache"]) == ("MISS", "HIT")
        assert r1.json()["unit_price"] == r2.json()["unit_price"] == r2.json()["price"] == 56.45
        ttl = rd.exec("redis-cli", "ttl", "catalog:product:SKU-0007").stdout.strip()
        assert 0 < int(ttl) <= 60
        up = c.post("/products", json={"sku": "SKU-0007", "name": "Changed", "unit_price": "1.00"})
        assert up.status_code == 200
        assert c.get("/products/SKU-0007").headers["X-Cache"] == "MISS"
    # second app instance: migration is idempotent (advisory lock + IF NOT EXISTS + version table)
    with TestClient(build_app()) as c2:
        for _ in range(30):
            if c2.get("/readyz").status_code == 200:
                break
            time.sleep(0.5)
        assert c2.get("/products/SKU-0007").json()["name"] == "Changed"
    out = pg.exec("psql", "-U", "postgres", "-d", "catalog", "-tAc", "select count(*) from catalog.schema_migrations").stdout.strip()
    assert out == "1"
