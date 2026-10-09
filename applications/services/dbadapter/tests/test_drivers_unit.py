"""Every driver against a behavioural fake of its SDK, through the shared CRUD contract."""

import pytest

from conftest import exercise_contract
from fakes import (FakeBlobContainer, FakeCassandraSession, FakeCosmosContainer, FakeFileSystem, FakeGremlinClient, FakeKusto,
                   FakeLedger, FakeMssql, FakeMySql, FakeRedis, FakeSearchClient, FakeTableClient, FakeToken)
from hello_dbadapter.drivers import FAMILIES, UnknownFamily, create_driver, driver_class
from hello_dbadapter.drivers.base import NotSupported, key_id, seed_id


def test_every_family_resolves_to_a_driver_class():
    expected = {"sql", "sqlmi", "sqlvm", "postgresql", "postgresql-elastic", "horizondb", "mysql", "cosmos-nosql", "cosmos-mongo",
                "documentdb", "cosmos-cassandra", "cassandra-mi", "cosmos-gremlin", "cosmos-table", "table-storage", "redis", "ledger",
                "blob", "adls", "search", "adx", "memory"}
    assert set(FAMILIES) == expected
    for family in FAMILIES:
        assert driver_class(family).__name__.endswith("Driver")
    with pytest.raises(UnknownFamily):
        driver_class("oracle")


def test_deterministic_ids():
    assert seed_id(1) == seed_id(1) and seed_id(1) != seed_id(2)
    assert key_id("abc") == key_id("abc") and key_id("abc") != key_id("abd")


async def test_memory():
    await exercise_contract(create_driver("memory"))


@pytest.mark.parametrize("family", ["sql", "sqlmi", "sqlvm"])
async def test_mssql_family(family):
    fake = FakeMssql()
    drv = create_driver(family, connect=fake.connect, connection_string="Server=tcp:x,1433;")
    await exercise_contract(drv)
    assert any(s.startswith("IF SCHEMA_ID") for s in fake.statements)
    assert any(s.startswith("MERGE adapter.records WITH (HOLDLOCK)") for s in fake.statements)


def test_mssql_connection_string_modes():
    from hello_dbadapter.drivers.mssql import build_connection_string

    cs = build_connection_string({"SQL_SERVER": "eh-sql.database.windows.net", "AZURE_CLIENT_ID": "11111111-2222-3333-4444-555555555555"})
    assert "Server=tcp:eh-sql.database.windows.net,1433" in cs and "Authentication=ActiveDirectoryMSI" in cs
    assert "UID=11111111-2222-3333-4444-555555555555" in cs and "Encrypt=yes" in cs and "PWD" not in cs
    assert "Authentication=ActiveDirectoryDefault" in build_connection_string({"SQL_SERVER": "h"})
    pw = build_connection_string({"SQL_SERVER": "10.0.0.4,1433", "SQL_AUTH": "password", "SQL_USER": "u", "SQL_PASSWORD": "p", "SQL_TRUST_SERVER_CERTIFICATE": "yes"})
    assert "UID=u;PWD=p" in pw and "TrustServerCertificate=yes" in pw and "Authentication" not in pw
    assert build_connection_string({"SQL_CONNECTION_STRING": "raw;"}) == "raw;"
    with pytest.raises(ValueError):
        build_connection_string({})


async def test_mysql_with_entra_token(monkeypatch):
    monkeypatch.setenv("MYSQL_AUTH", "entra")
    monkeypatch.setenv("MYSQL_USER", "hello-dbadapter-mysql-id")
    fake, token = FakeMySql(), FakeToken()
    drv = create_driver("mysql", connect=fake.connect, token_cache=token)
    await exercise_contract(drv)
    assert fake.passwords[0] == "entra-token-1"
    assert fake.kwargs["ssl"]["ca"] and fake.kwargs["ssl_verify_identity"] is True
    assert len(fake.passwords) == 1  # pooled: one connection reused


async def test_cosmos_nosql():
    c = FakeCosmosContainer()
    await exercise_contract(create_driver("cosmos-nosql", container=c))
    assert all("payload" in i for i in c.items.values())


@pytest.mark.parametrize("family", ["cosmos-cassandra", "cassandra-mi"])
async def test_cassandra(family):
    await exercise_contract(create_driver(family, session=FakeCassandraSession()))


async def test_gremlin_uses_bindings():
    client = FakeGremlinClient()
    await exercise_contract(create_driver("cosmos-gremlin", client=client))
    for query, bindings in client.queries:
        for value in bindings.values():  # values travel only as bindings, never inside the traversal text
            assert isinstance(value, int) or str(value) not in query


@pytest.mark.parametrize("family", ["cosmos-table", "table-storage"])
async def test_tables(family):
    await exercise_contract(create_driver(family, table=FakeTableClient()))


async def test_redis_cache_semantics():
    r = FakeRedis()
    drv = create_driver("redis", client=r)
    await exercise_contract(drv)
    rec = await drv.create({"k": 1})
    assert r.t[f"adapter:record:{rec.id}"] == 300
    got = await drv.get(rec.id)
    assert drv.last_result == "hit" and got.extra["ttl_seconds"] == 300
    r.d.clear()  # simulate eviction
    assert await drv.get(rec.id) is None and drv.last_result == "miss"


async def test_ledger_is_append_only():
    led = FakeLedger()
    drv = create_driver("ledger", client=led)
    await drv.open()
    rec = await drv.create({"x": 1})
    assert rec.id == "2.10"
    assert (await drv.get("2.10")).payload == {"x": 1}
    assert await drv.get("9.99") is None
    with pytest.raises(NotSupported):
        await drv.update(rec.id, {})
    with pytest.raises(NotSupported):
        await drv.delete(rec.id)
    assert await drv.seed(3) == 2  # one entry exists already
    assert await drv.seed(3) == 0  # idempotent for append-only


async def test_blob():
    c = FakeBlobContainer()
    await exercise_contract(create_driver("blob", container=c))
    assert all(n.startswith("records/") and n.endswith(".json") for n in c.blobs)


async def test_adls():
    fs = FakeFileSystem()
    await exercise_contract(create_driver("adls", filesystem=fs))
    assert all(n.startswith("records/") for n in fs.files)


async def test_search():
    await exercise_contract(create_driver("search", client=FakeSearchClient()))


async def test_adx_version_log():
    k = FakeKusto()
    drv = create_driver("adx", client=k)
    await exercise_contract(drv)
    assert all(cmd.startswith(".ingest inline into table Records") for cmd in k.mgmt)
    assert any(r["deleted"] for r in k.rows)  # delete = tombstone row, history retained


async def test_db_error_fault_hook():
    from hello_common.faults import REGISTRY, FaultInjectedError

    drv = create_driver("redis", client=FakeRedis())
    REGISTRY.add("db_error", 1.0, 30)
    with pytest.raises(FaultInjectedError):
        await drv.create({"a": 1})


async def test_postgres_elastic_distributes_table():
    from hello_dbadapter.drivers.postgresql import PostgresDriver

    executed = []

    class Cur:
        async def fetchone(self):
            return (1,)

    class Conn:
        async def execute(self, sql, params=()):
            executed.append(" ".join(sql.split()))
            return Cur()

    class Ctx:
        async def __aenter__(self):
            return Conn()

        async def __aexit__(self, *a):
            return False

    class Pool:
        async def open(self, wait=True, timeout=None):
            pass

        def connection(self):
            return Ctx()

    drv = PostgresDriver(family="postgresql-elastic", pool=Pool())
    await drv.open()
    assert any("create_distributed_table('adapter.records', 'id')" in s for s in executed)
    assert drv.describe()["distributed"] is True
    executed.clear()
    await PostgresDriver(family="postgresql", pool=Pool()).open()
    assert not any("create_distributed_table" in s for s in executed)


def test_mongo_oidc_callback(monkeypatch):
    from hello_dbadapter.drivers import mongo

    class Cred:
        def get_token(self, scope):
            assert scope == "https://ossrdbms-aad.database.windows.net/.default"
            import time

            return type("T", (), {"token": "oidc-token", "expires_on": int(time.time()) + 3600})()

    monkeypatch.setattr("hello_common.azure_auth.get_credential", lambda **_: Cred())
    props = mongo.oidc_properties()
    result = props["OIDC_CALLBACK"].fetch(None)
    assert result.access_token == "oidc-token" and result.expires_in_seconds > 3000
