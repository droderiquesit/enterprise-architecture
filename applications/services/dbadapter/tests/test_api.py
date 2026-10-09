import subprocess
import sys

from fastapi.testclient import TestClient

from hello_dbadapter.drivers import create_driver
from hello_dbadapter.drivers.memory import MemoryDriver
from hello_dbadapter.main import build_app


class AppendOnly(MemoryDriver):
    append_only = True

    async def update(self, record_id, payload):
        from hello_dbadapter.drivers.base import NotSupported

        raise NotSupported("append-only")

    async def delete(self, record_id):
        from hello_dbadapter.drivers.base import NotSupported

        raise NotSupported("append-only")


def test_crud_and_idempotency(monkeypatch):
    with TestClient(build_app(create_driver("memory"))) as c:
        r = c.post("/records", json={"payload": {"n": 1}})
        assert r.status_code == 201
        rid = r.json()["id"]
        assert c.get(f"/records/{rid}").json()["payload"] == {"n": 1}
        assert c.put(f"/records/{rid}", json={"payload": {"n": 2}}).json()["payload"] == {"n": 2}
        assert c.get("/records", params={"limit": 5}).json()["count"] == 1
        assert c.delete(f"/records/{rid}").status_code == 204
        assert c.get(f"/records/{rid}").status_code == 404
        assert c.delete(f"/records/{rid}").status_code == 404
        a = c.post("/records", json={"payload": {"n": 9}}, headers={"Idempotency-Key": "order-42"}).json()
        b = c.post("/records", json={"payload": {"n": 9}}, headers={"Idempotency-Key": "order-42"}).json()
        assert a["id"] == b["id"] and c.get("/records").json()["count"] == 1
        assert c.post("/records", json={"payload": {}}, headers={"Idempotency-Key": "bad key"}).status_code == 400


def test_roundtrip_and_seed_and_info():
    with TestClient(build_app(create_driver("memory"))) as c:
        rt = c.post("/roundtrip").json()
        assert rt["ok"] is True and rt["family"] == "memory"
        assert set(rt["timings_ms"]) == {"write", "read", "update", "delete"}
        assert c.post("/seed", params={"count": 5}).json()["seeded"] == 5
        assert c.post("/seed", params={"count": 5}).json()["seeded"] == 5
        assert c.get("/records", params={"limit": 50}).json()["count"] == 5  # deterministic ids => idempotent
        info = c.get("/info").json()
        assert info["family"] == "memory" and info["ready"] is True
        assert c.get("/readyz").status_code == 200
        assert c.get("/version").json()["service"] == "hello-dbadapter-memory"


def test_append_only_returns_405():
    with TestClient(build_app(AppendOnly(family="ledger"))) as c:
        rid = c.post("/records", json={"payload": {"x": 1}}).json()["id"]
        r = c.put(f"/records/{rid}", json={"payload": {}})
        assert r.status_code == 405 and r.headers["content-type"] == "application/problem+json"
        assert c.delete(f"/records/{rid}").status_code == 405
        rt = c.post("/roundtrip").json()
        assert rt["ok"] is True and "not_supported" in rt["update"]


def test_not_ready_driver_returns_503():
    class Broken(MemoryDriver):
        async def open(self):
            raise ConnectionError("no route to host")

    with TestClient(build_app(Broken(family="postgresql"))) as c:
        r = c.get("/readyz")
        assert r.status_code == 503 and "ConnectionError" in r.text
        assert c.post("/records", json={"payload": {}}).status_code == 503


def test_db_error_fault_on_roundtrip(monkeypatch):
    from hello_common.faults import REGISTRY

    with TestClient(build_app(create_driver("memory"))) as c:
        REGISTRY.add("db_error", 1.0, 30)
        r = c.post("/roundtrip")
        assert r.status_code == 503 and r.json()["fault"] == "db_error"


def test_service_name_override(monkeypatch):
    monkeypatch.setenv("DB_SERVICE_NAME", "custom-adapter")
    with TestClient(build_app(create_driver("memory"))) as c:
        assert c.get("/version").json()["service"] == "custom-adapter"


def test_lazy_imports_only_load_selected_driver():
    code = r"""
import os, sys
os.environ['DB_FAMILY'] = '{family}'
from hello_dbadapter.drivers import create_driver
from hello_dbadapter.main import build_app
d = create_driver('{family}')
heavy = ['mssql_python', 'psycopg', 'pymysql', 'azure.cosmos', 'pymongo', 'cassandra', 'gremlin_python', 'azure.data.tables',
         'redis', 'azure.confidentialledger', 'azure.storage.blob', 'azure.storage.filedatalake', 'azure.search.documents', 'azure.kusto.data']
print(','.join(sorted(m for m in heavy if m in sys.modules)))
"""
    for family, allowed in [("memory", set()), ("cosmos-nosql", set()), ("postgresql", set())]:
        out = subprocess.run([sys.executable, "-c", code.replace("{family}", family)], capture_output=True, text=True, check=True).stdout.strip()
        loaded = set(filter(None, out.split(",")))
        assert loaded <= allowed, f"{family}: unexpected eager imports {loaded}"
