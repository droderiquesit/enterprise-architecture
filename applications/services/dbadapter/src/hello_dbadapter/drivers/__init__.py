"""Driver registry. Modules are imported lazily so one image holds every SDK but a running
instance only loads the driver (and SDK) of its own DB_FAMILY."""

from __future__ import annotations

import importlib

from .base import Driver

FAMILIES: dict[str, str] = {
    "memory": "hello_dbadapter.drivers.memory:MemoryDriver",
    "sql": "hello_dbadapter.drivers.mssql:SqlDriver",
    "sqlmi": "hello_dbadapter.drivers.mssql:SqlDriver",
    "sqlvm": "hello_dbadapter.drivers.mssql:SqlDriver",
    "postgresql": "hello_dbadapter.drivers.postgresql:PostgresDriver",
    "postgresql-elastic": "hello_dbadapter.drivers.postgresql:PostgresDriver",
    "horizondb": "hello_dbadapter.drivers.postgresql:PostgresDriver",
    "mysql": "hello_dbadapter.drivers.mysql:MySqlDriver",
    "cosmos-nosql": "hello_dbadapter.drivers.cosmos_nosql:CosmosNoSqlDriver",
    "cosmos-mongo": "hello_dbadapter.drivers.mongo:MongoDriver",
    "documentdb": "hello_dbadapter.drivers.mongo:MongoDriver",
    "cosmos-cassandra": "hello_dbadapter.drivers.cassandra:CassandraDriver",
    "cassandra-mi": "hello_dbadapter.drivers.cassandra:CassandraDriver",
    "cosmos-gremlin": "hello_dbadapter.drivers.gremlin:GremlinDriver",
    "cosmos-table": "hello_dbadapter.drivers.tables:TablesDriver",
    "table-storage": "hello_dbadapter.drivers.tables:TablesDriver",
    "redis": "hello_dbadapter.drivers.redis_cache:RedisDriver",
    "ledger": "hello_dbadapter.drivers.ledger:LedgerDriver",
    "blob": "hello_dbadapter.drivers.blob:BlobDriver",
    "adls": "hello_dbadapter.drivers.adls:AdlsDriver",
    "search": "hello_dbadapter.drivers.search:SearchDriver",
    "adx": "hello_dbadapter.drivers.adx:AdxDriver",
}


class UnknownFamily(ValueError):
    pass


def driver_class(family: str) -> type[Driver]:
    try:
        target = FAMILIES[family]
    except KeyError as exc:
        raise UnknownFamily(f"unknown DB_FAMILY {family!r}; expected one of {sorted(FAMILIES)}") from exc
    module_name, cls_name = target.split(":")
    return getattr(importlib.import_module(module_name), cls_name)


def create_driver(family: str, **kwargs) -> Driver:
    cls = driver_class(family)
    return cls(family=family, **kwargs)
