"""MySQL driver (Azure Database for MySQL Flexible Server) using PyMySQL with a small bounded pool.

Environment:
  MYSQL_HOST, MYSQL_PORT (3306), MYSQL_DATABASE (adapter), MYSQL_USER
  MYSQL_AUTH      entra (default) | password - entra: Entra access token (scope ossrdbms-aad) sent as the
                  password (server uses mysql_clear_password over TLS); new connections get a fresh token
  MYSQL_PASSWORD  password auth only (local containers)
  MYSQL_SSL       true (default) | false (local only); MYSQL_SSL_CA (default system bundle)
  MYSQL_POOL_MAX  default 10
Boundary: table ``records`` in database ``adapter``.
"""

from __future__ import annotations

import os
import queue
import threading
import time
from typing import Any

from .base import Driver, Record, dumps, iso, loads, new_id

DDL = """CREATE TABLE IF NOT EXISTS records (
  id VARCHAR(64) NOT NULL PRIMARY KEY,
  payload JSON NOT NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB"""
COLS = "id, payload, created_at, updated_at"
MAX_CONN_AGE_SECONDS = 50 * 60


class _Pool:
    def __init__(self, factory, max_size: int) -> None:
        self._factory = factory
        self._idle: queue.LifoQueue = queue.LifoQueue()
        self._sem = threading.BoundedSemaphore(max_size)

    def acquire(self, timeout: float = 5.0):
        if not self._sem.acquire(timeout=timeout):
            raise TimeoutError("mysql pool exhausted")
        try:
            while True:
                try:
                    conn, born = self._idle.get_nowait()
                except queue.Empty:
                    return self._factory(), time.monotonic()
                if time.monotonic() - born > MAX_CONN_AGE_SECONDS:
                    _safe_close(conn)
                    continue
                return conn, born
        except Exception:
            self._sem.release()
            raise

    def release(self, item, broken: bool = False) -> None:
        conn, born = item
        if broken:
            _safe_close(conn)
        else:
            self._idle.put((conn, born))
        self._sem.release()

    def close(self) -> None:
        while True:
            try:
                conn, _ = self._idle.get_nowait()
            except queue.Empty:
                return
            _safe_close(conn)


def _safe_close(conn) -> None:
    try:
        conn.close()
    except Exception:
        pass


class MySqlDriver(Driver):
    db_system = "mysql"

    def __init__(self, family: str = "mysql", connect: Any = None, token_cache: Any = None) -> None:
        self.family = family
        self._connect = connect
        self._token_cache = token_cache
        self._pool: _Pool | None = None

    def _factory(self):
        import pymysql

        auth = os.environ.get("MYSQL_AUTH", "entra").lower()
        if auth == "entra":
            if self._token_cache is None:
                from hello_common.azure_auth import SCOPE_OSSRDBMS, TokenCache

                self._token_cache = TokenCache(SCOPE_OSSRDBMS)
            password = self._token_cache.get()
        else:
            password = os.environ.get("MYSQL_PASSWORD", "")
        kwargs: dict[str, Any] = dict(
            host=os.environ.get("MYSQL_HOST", "localhost"), port=int(os.environ.get("MYSQL_PORT", "3306")),
            user=os.environ.get("MYSQL_USER", "root"), password=password, database=os.environ.get("MYSQL_DATABASE", "adapter"),
            connect_timeout=5, read_timeout=10, write_timeout=10, autocommit=True, charset="utf8mb4",
        )
        if os.environ.get("MYSQL_SSL", "true").lower() == "true":
            kwargs["ssl"] = {"ca": os.environ.get("MYSQL_SSL_CA", "/etc/ssl/certs/ca-certificates.crt")}
            kwargs["ssl_verify_cert"] = True
            kwargs["ssl_verify_identity"] = True
        return (self._connect or pymysql.connect)(**kwargs)

    @property
    def pool(self) -> _Pool:
        if self._pool is None:
            self._pool = _Pool(self._factory, int(os.environ.get("MYSQL_POOL_MAX", "10")))
        return self._pool

    def _exec(self, sql: str, params: tuple = (), fetch: str | None = None) -> Any:
        item = self.pool.acquire()
        broken = False
        try:
            with item[0].cursor() as cur:
                cur.execute(sql, params or None)
                if fetch == "one":
                    return cur.fetchone()
                if fetch == "all":
                    return cur.fetchall()
                return cur.rowcount
        except Exception as exc:
            broken = exc.__class__.__name__ in ("OperationalError", "InterfaceError")
            raise
        finally:
            self.pool.release(item, broken)

    async def _q(self, sql: str, params: tuple = (), fetch: str | None = None) -> Any:
        self.fault_hook()
        return await self.in_thread(self._exec, sql, params, fetch)

    async def open(self) -> None:
        await self._q(DDL)

    async def close(self) -> None:
        if self._pool is not None:
            self._pool.close()

    async def ping(self) -> None:
        await self._q("SELECT 1", fetch="one")

    @staticmethod
    def _row(row: Any) -> Record:
        return Record(row[0], loads(row[1]), iso(row[2]), iso(row[3]))

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        rid = record_id or new_id()
        await self._q("INSERT INTO records (id, payload) VALUES (%s, %s) ON DUPLICATE KEY UPDATE payload = VALUES(payload)", (rid, dumps(payload)))
        return await self.get(rid)  # type: ignore[return-value]

    async def get(self, record_id: str) -> Record | None:
        row = await self._q(f"SELECT {COLS} FROM records WHERE id = %s", (record_id,), fetch="one")
        return self._row(row) if row else None

    async def list(self, limit: int) -> list[Record]:
        return [self._row(r) for r in await self._q(f"SELECT {COLS} FROM records ORDER BY created_at DESC LIMIT %s", (int(limit),), fetch="all")]

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        # rowcount 0 also when the payload is unchanged; confirm existence via get().
        await self._q("UPDATE records SET payload = %s WHERE id = %s", (dumps(payload), record_id))
        return await self.get(record_id)

    async def delete(self, record_id: str) -> bool:
        return bool(await self._q("DELETE FROM records WHERE id = %s", (record_id,)))
