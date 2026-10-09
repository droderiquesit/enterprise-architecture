"""Driver integration tests against real local containers (marker: integration).

postgres:17-alpine (postgresql + horizondb code path), citusdata/citus:13.0 (postgresql-elastic, real
create_distributed_table), mysql:8.4, redis:7-alpine, mongo:8 (Mongo wire protocol stand-in for Cosmos
Mongo RU / DocumentDB), mcr.microsoft.com/mssql/server:2022-latest (sql/sqlmi/sqlvm via mssql-python),
mcr.microsoft.com/azure-storage/azurite (table-storage/cosmos-table code path + blob), cassandra:5.0
(cosmos-cassandra/cassandra-mi code path).
"""

from __future__ import annotations

import os
import socket

import pytest
from fastapi.testclient import TestClient

from conftest import exercise_contract
from hello_common.testing import docker_available, run_container
from hello_dbadapter.drivers import create_driver
from hello_dbadapter.main import build_app

pytestmark = [pytest.mark.integration, pytest.mark.skipif(not docker_available(), reason="docker not available")]

AZURITE_KEY = "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="  # public Azurite dev key


def _tcp(host, port):
    # docker-proxy accepts TCP before the service listens, so callers combine this with an in-container probe
    with socket.create_connection((host, port), timeout=2):
        return True


def _set(monkeypatch, **env):
    for k, v in env.items():
        monkeypatch.setenv(k, str(v))


async def _contract_and_app(family, monkeypatch, **driver_kwargs):
    monkeypatch.setenv("DB_FAMILY", family)
    drv = create_driver(family, **driver_kwargs)
    await exercise_contract(drv)
    await drv.close()
    with TestClient(build_app(family=family)) as c:
        assert c.get("/readyz").status_code == 200, c.get("/readyz").text
        rt = c.post("/roundtrip").json()
        assert rt["ok"] is True, rt
        assert c.post("/seed", params={"count": 3}).status_code == 200
        return rt


# ---------------------------------------------------------------- PostgreSQL / Citus
def _pg_ready(c):
    return c.exec("psql", "-U", "postgres", "-d", "adapter", "-c", "select 1").returncode == 0


@pytest.mark.parametrize("family,image", [("postgresql", "postgres:17-alpine"), ("horizondb", "postgres:17-alpine"),
                                          ("postgresql-elastic", "mirror.gcr.io/citusdata/citus:13.0")])
async def test_postgres_family(family, image, monkeypatch):
    with run_container(image, [5432], env={"POSTGRES_PASSWORD": "localonly", "POSTGRES_DB": "adapter"}, ready=_pg_ready) as pg:
        _set(monkeypatch, PG_HOST=pg.host, PG_PORT=pg.port(5432), PG_USER="postgres", PG_AUTH="password", PG_PASSWORD="localonly", PG_SSLMODE="disable", PG_DATABASE="adapter")
        await _contract_and_app(family, monkeypatch)
        if family == "postgresql-elastic":
            out = pg.exec("psql", "-U", "postgres", "-d", "adapter", "-tAc", "select count(*) from pg_dist_partition where logicalrelid='adapter.records'::regclass").stdout.strip()
            assert out == "1", "table must be distributed by create_distributed_table"


# ---------------------------------------------------------------- MySQL
async def test_mysql(monkeypatch):
    def ready(c):
        return c.exec("mysql", "-uroot", "-plocalonly", "-h127.0.0.1", "-e", "select 1", "adapter").returncode == 0

    with run_container("mysql:8.4", [3306], env={"MYSQL_ROOT_PASSWORD": "localonly", "MYSQL_DATABASE": "adapter"}, ready=ready, timeout=180) as my:
        _set(monkeypatch, MYSQL_HOST=my.host, MYSQL_PORT=my.port(3306), MYSQL_USER="root", MYSQL_AUTH="password", MYSQL_PASSWORD="localonly", MYSQL_SSL="false")
        await _contract_and_app("mysql", monkeypatch)


# ---------------------------------------------------------------- Redis
async def test_redis(monkeypatch):
    with run_container("redis:7-alpine", [6379], ready=lambda c: c.exec("redis-cli", "ping").stdout.strip() == "PONG") as rd:
        _set(monkeypatch, REDIS_HOST=rd.host, REDIS_PORT=rd.port(6379), REDIS_AUTH="none", REDIS_TLS="false")
        rt = await _contract_and_app("redis", monkeypatch)
        assert rt["cache"] == "hit"
        ttl = int(rd.exec("sh", "-c", "redis-cli --scan --pattern 'adapter:record:*' | head -1 | xargs redis-cli ttl").stdout.strip())
        assert 0 < ttl <= 300


# ---------------------------------------------------------------- Mongo wire (cosmos-mongo, documentdb)
@pytest.mark.parametrize("family", ["cosmos-mongo", "documentdb"])
async def test_mongo(family, monkeypatch):
    with run_container("mongo:8", [27017], ready=lambda c: _tcp(c.host, c.port(27017)) and c.exec("mongosh", "--quiet", "--eval", "db.runCommand({ping:1}).ok").stdout.strip() == "1") as mg:
        _set(monkeypatch, MONGO_URI=f"mongodb://{mg.host}:{mg.port(27017)}/", MONGO_AUTH="connection_string")
        await _contract_and_app(family, monkeypatch)


# ---------------------------------------------------------------- SQL Server (mssql-python)
@pytest.fixture(scope="module")
def mssql():
    pw = "Local0nly!Pass"

    def ready(c):
        r = c.exec("/opt/mssql-tools18/bin/sqlcmd", "-S", "localhost", "-U", "sa", "-P", pw, "-C", "-Q",
                   "IF DB_ID('adapter') IS NULL CREATE DATABASE adapter; SELECT 1")
        return r.returncode == 0

    with run_container("mcr.microsoft.com/mssql/server:2022-latest", [1433], env={"ACCEPT_EULA": "Y", "MSSQL_SA_PASSWORD": pw}, ready=ready, timeout=180) as c:
        yield c, pw


@pytest.mark.parametrize("family", ["sql", "sqlmi", "sqlvm"])
async def test_sql_family(family, mssql, monkeypatch):
    c, pw = mssql
    _set(monkeypatch, SQL_SERVER=f"{c.host},{c.port(1433)}", SQL_DATABASE="adapter", SQL_AUTH="password", SQL_USER="sa", SQL_PASSWORD=pw,
         SQL_TRUST_SERVER_CERTIFICATE="yes")
    await _contract_and_app(family, monkeypatch)


# ---------------------------------------------------------------- Azurite (tables, blob)
@pytest.fixture(scope="module")
def azurite():
    with run_container("mcr.microsoft.com/azure-storage/azurite:latest", [10000, 10002], ready=lambda c: c.logs().count("successfully listening") >= 2,
                       command=["azurite", "--blobHost", "0.0.0.0", "--tableHost", "0.0.0.0", "--skipApiVersionCheck", "--loose"]) as c:
        yield c


def _azurite_cs(c):
    return (f"DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey={AZURITE_KEY};"
            f"BlobEndpoint=http://{c.host}:{c.port(10000)}/devstoreaccount1;TableEndpoint=http://{c.host}:{c.port(10002)}/devstoreaccount1;")


@pytest.mark.parametrize("family", ["table-storage", "cosmos-table"])
async def test_tables(family, azurite, monkeypatch):
    _set(monkeypatch, TABLES_AUTH="connection_string", TABLES_CONNECTION_STRING=_azurite_cs(azurite), TABLES_TABLE=f"adapter{family.replace('-', '')}")
    await _contract_and_app(family, monkeypatch)


async def test_blob(azurite, monkeypatch):
    _set(monkeypatch, BLOB_AUTH="connection_string", BLOB_CONNECTION_STRING=_azurite_cs(azurite), BLOB_CONTAINER="adapter")
    await _contract_and_app("blob", monkeypatch)


# ---------------------------------------------------------------- Cassandra
async def test_cassandra(monkeypatch):
    def ready(c):
        return c.exec("cqlsh", "-e", "describe keyspaces").returncode == 0

    with run_container("mirror.gcr.io/library/cassandra:5.0", [9042], env={"MAX_HEAP_SIZE": "512M", "HEAP_NEWSIZE": "128M"}, ready=ready, timeout=240) as cs:
        _set(monkeypatch, CASSANDRA_CONTACT_POINTS=cs.host, CASSANDRA_PORT=cs.port(9042), CASSANDRA_TLS="false", CASSANDRA_REPLICATION_FACTOR="1")
        monkeypatch.delenv("CASSANDRA_USERNAME", raising=False)
        await _contract_and_app("cassandra-mi", monkeypatch)
        await _contract_and_app("cosmos-cassandra", monkeypatch)
