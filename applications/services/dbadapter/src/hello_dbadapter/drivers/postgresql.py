"""PostgreSQL family driver (postgresql = Flexible Server, postgresql-elastic = Elastic Clusters (Citus),
horizondb = Azure HorizonDB (PostgreSQL-compatible; preview access required)) using psycopg 3 async pool.

Environment:
  PG_HOST, PG_PORT (5432), PG_DATABASE (adapter), PG_USER
  PG_AUTH       entra (default) | password  - entra: Entra access token (scope ossrdbms-aad) as password,
                fetched per new connection; pool connections recycled every 50 min
  PG_PASSWORD   password auth only (local containers)
  PG_SSLMODE    require (default) | verify-full | disable (local only)
  PG_POOL_MAX   default 10
Boundary: table ``adapter.records``. For postgresql-elastic the table is distributed by ``id`` with
``create_distributed_table`` when the Citus function is available (idempotent: skipped if already distributed).
"""

from __future__ import annotations

import asyncio
import logging
import os
from typing import Any

from .base import Driver, Record, iso, loads, new_id, utcnow

log = logging.getLogger("hello_dbadapter.postgresql")

DDL = [
    "CREATE SCHEMA IF NOT EXISTS adapter",
    """CREATE TABLE IF NOT EXISTS adapter.records (
         id text PRIMARY KEY,
         payload jsonb NOT NULL,
         created_at timestamptz NOT NULL DEFAULT now(),
         updated_at timestamptz NOT NULL DEFAULT now())""",
]
DISTRIBUTE = """
SELECT create_distributed_table('adapter.records', 'id')
WHERE to_regproc('create_distributed_table') IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM pg_dist_partition WHERE logicalrelid = 'adapter.records'::regclass)
"""
COLS = "id, payload, created_at, updated_at"


class PostgresDriver(Driver):
    db_system = "postgresql"

    def __init__(self, family: str = "postgresql", pool: Any = None, token_cache: Any = None) -> None:
        self.family = family
        self._pool = pool
        self._token_cache = token_cache
        self.distributed = False

    def _build_pool(self) -> Any:
        import psycopg
        from psycopg.conninfo import make_conninfo
        from psycopg_pool import AsyncConnectionPool

        auth = os.environ.get("PG_AUTH", "entra").lower()
        cache = None
        if auth == "entra":
            from hello_common.azure_auth import SCOPE_OSSRDBMS, TokenCache

            cache = self._token_cache or TokenCache(SCOPE_OSSRDBMS)

        class _Conn(psycopg.AsyncConnection):  # type: ignore[misc]
            @classmethod
            async def connect(cls, conninfo: str = "", **kwargs: Any):  # type: ignore[override]
                if cache is not None:
                    kwargs["password"] = await asyncio.to_thread(cache.get)
                return await super().connect(conninfo, **kwargs)

        conninfo = make_conninfo(
            host=os.environ.get("PG_HOST", "localhost"),
            port=int(os.environ.get("PG_PORT", "5432")),
            dbname=os.environ.get("PG_DATABASE", "adapter"),
            user=os.environ.get("PG_USER", "postgres"),
            sslmode=os.environ.get("PG_SSLMODE", "require"),
            connect_timeout=5,
            application_name=f"hello-dbadapter-{self.family}",
            options="-c statement_timeout=5000",
        )
        kwargs: dict[str, Any] = {"autocommit": True}
        if auth == "password" and os.environ.get("PG_PASSWORD"):
            kwargs["password"] = os.environ["PG_PASSWORD"]
        return AsyncConnectionPool(conninfo, connection_class=_Conn, kwargs=kwargs, min_size=1,
                                   max_size=int(os.environ.get("PG_POOL_MAX", "10")), timeout=5.0, max_lifetime=3000.0,
                                   max_idle=300.0, check=AsyncConnectionPool.check_connection, open=False, name=self.family)

    @property
    def pool(self) -> Any:
        if self._pool is None:
            self._pool = self._build_pool()
        return self._pool

    async def open(self) -> None:
        await self.pool.open(wait=True, timeout=15)
        async with self.pool.connection() as conn:
            for statement in DDL:
                await conn.execute(statement)
            if self.family == "postgresql-elastic":
                try:
                    await conn.execute(DISTRIBUTE)
                    cur = await conn.execute("SELECT count(*) FROM pg_dist_partition WHERE logicalrelid = 'adapter.records'::regclass")
                    self.distributed = bool((await cur.fetchone())[0])
                except Exception as exc:  # Citus not installed (e.g. plain PostgreSQL locally)
                    log.warning("create_distributed_table unavailable; table stays local", extra={"error.kind": type(exc).__name__})

    async def close(self) -> None:
        if self._pool is not None:
            await self._pool.close(timeout=5)

    async def _query(self, sql: str, params: tuple = (), fetch: str | None = None) -> Any:
        self.fault_hook()
        async with self.pool.connection() as conn:
            cur = await conn.execute(sql, params)
            if fetch == "one":
                return await cur.fetchone()
            if fetch == "all":
                return await cur.fetchall()
            return cur.rowcount

    async def ping(self) -> None:
        await self._query("SELECT 1", fetch="one")

    @staticmethod
    def _row(row: Any) -> Record:
        return Record(row[0], loads(row[1]), iso(row[2]), iso(row[3]))

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        from psycopg.types.json import Jsonb

        rid = record_id or new_id()
        ts = utcnow()
        row = await self._query(
            # timestamps are bound parameters: Citus rejects non-IMMUTABLE functions (now()) in DO UPDATE on distributed tables
            f"INSERT INTO adapter.records (id, payload, created_at, updated_at) VALUES (%s, %s, %s, %s) "
            f"ON CONFLICT (id) DO UPDATE SET payload = EXCLUDED.payload, updated_at = EXCLUDED.updated_at RETURNING {COLS}",
            (rid, Jsonb(payload), ts, ts), fetch="one")
        return self._row(row)

    async def get(self, record_id: str) -> Record | None:
        row = await self._query(f"SELECT {COLS} FROM adapter.records WHERE id = %s", (record_id,), fetch="one")
        return self._row(row) if row else None

    async def list(self, limit: int) -> list[Record]:
        rows = await self._query(f"SELECT {COLS} FROM adapter.records ORDER BY created_at DESC LIMIT %s", (limit,), fetch="all")
        return [self._row(r) for r in rows]

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        from psycopg.types.json import Jsonb

        row = await self._query(f"UPDATE adapter.records SET payload = %s, updated_at = %s WHERE id = %s RETURNING {COLS}", (Jsonb(payload), utcnow(), record_id), fetch="one")
        return self._row(row) if row else None

    async def delete(self, record_id: str) -> bool:
        return bool(await self._query("DELETE FROM adapter.records WHERE id = %s", (record_id,)))

    def describe(self) -> dict[str, Any]:
        doc = super().describe()
        doc["distributed"] = self.distributed
        return doc
