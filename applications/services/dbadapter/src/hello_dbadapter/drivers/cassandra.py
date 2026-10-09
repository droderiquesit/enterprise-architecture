"""Cassandra driver for cosmos-cassandra (Azure Cosmos DB for Apache Cassandra) and cassandra-mi
(Azure Managed Instance for Apache Cassandra) using the Apache Cassandra Python driver
(``cassandra-driver`` 3.30, maintained under the Apache Software Foundation; ships cp313 wheels with
the libev reactor, verified to import and run on Python 3.13 - no fork needed).

Environment:
  CASSANDRA_CONTACT_POINTS  comma list (cosmos: <account>.cassandra.cosmos.azure.com; MI: node IPs)
  CASSANDRA_PORT            10350 for Cosmos, 9042 for MI/local
  CASSANDRA_USERNAME / CASSANDRA_PASSWORD  (Cosmos: account name + key; MI: CQL role) - secret refs
  CASSANDRA_TLS             true (default) | false (local)
  CASSANDRA_LOCAL_DC        load-balancing local DC (Cosmos: region display name e.g. "East US 2")
  CASSANDRA_KEYSPACE        default "adapter"; CASSANDRA_REPLICATION_FACTOR default 3 (1 locally)
  CASSANDRA_CREATE_KEYSPACE true (default)
Boundary: keyspace ``adapter`` / table ``records``.
"""

from __future__ import annotations

import os
from datetime import UTC
from typing import Any

from .base import Driver, Record, dumps, iso, loads, new_id, utcnow


class CassandraDriver(Driver):
    db_system = "cassandra"

    def __init__(self, family: str = "cosmos-cassandra", session: Any = None) -> None:
        self.family = family
        self._session = session
        self._cluster = None
        self.keyspace = os.environ.get("CASSANDRA_KEYSPACE", "adapter")
        self._ps: dict[str, Any] = {}

    def _connect(self) -> Any:
        import ssl

        from cassandra.auth import PlainTextAuthProvider
        from cassandra.cluster import EXEC_PROFILE_DEFAULT, Cluster, ExecutionProfile
        from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy

        points = [p.strip() for p in os.environ.get("CASSANDRA_CONTACT_POINTS", "localhost").split(",") if p.strip()]
        kwargs: dict[str, Any] = {"port": int(os.environ.get("CASSANDRA_PORT", "10350")), "connect_timeout": 10, "protocol_version": 4}
        if os.environ.get("CASSANDRA_USERNAME"):
            kwargs["auth_provider"] = PlainTextAuthProvider(os.environ["CASSANDRA_USERNAME"], os.environ.get("CASSANDRA_PASSWORD", ""))
        if os.environ.get("CASSANDRA_TLS", "true").lower() == "true":
            ctx = ssl.create_default_context()
            kwargs["ssl_context"] = ctx
        local_dc = os.environ.get("CASSANDRA_LOCAL_DC")
        lb = TokenAwarePolicy(DCAwareRoundRobinPolicy(local_dc=local_dc)) if local_dc else None
        profile = ExecutionProfile(request_timeout=10, load_balancing_policy=lb) if lb else ExecutionProfile(request_timeout=10)
        self._cluster = Cluster(points, execution_profiles={EXEC_PROFILE_DEFAULT: profile}, **kwargs)
        session = self._cluster.connect()
        if os.environ.get("CASSANDRA_CREATE_KEYSPACE", "true").lower() == "true":
            rf = int(os.environ.get("CASSANDRA_REPLICATION_FACTOR", "3"))
            session.execute(f"CREATE KEYSPACE IF NOT EXISTS {self.keyspace} WITH replication = {{'class': 'SimpleStrategy', 'replication_factor': {rf}}}")
        session.execute(
            f"CREATE TABLE IF NOT EXISTS {self.keyspace}.records (id text PRIMARY KEY, payload text, created_at timestamp, updated_at timestamp)"
        )
        return session

    async def open(self) -> None:
        if self._session is None:
            self._session = await self.in_thread(self._connect)

    async def close(self) -> None:
        if self._cluster is not None:
            await self.in_thread(self._cluster.shutdown)

    async def _exec(self, operation: str, cql: str, params: tuple = ()) -> list[Any]:
        self.fault_hook()
        with self.client_span(operation, **{"db.namespace": self.keyspace}):
            result = await self.in_thread(self._session.execute, cql, params)
            return list(result) if result is not None else []

    @staticmethod
    def _rec(row: Any) -> Record:
        def _ts(v):
            return iso(v.replace(tzinfo=UTC)) if v is not None and v.tzinfo is None else iso(v)

        return Record(row.id, loads(row.payload), _ts(row.created_at), _ts(row.updated_at))

    async def ping(self) -> None:
        await self._exec("SELECT", "SELECT release_version FROM system.local")

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        rid = record_id or new_id()
        now = utcnow().replace(microsecond=(utcnow().microsecond // 1000) * 1000)
        existing = await self.get(rid) if record_id else None
        created = existing.created_at if existing else iso(now)
        from datetime import datetime

        created_dt = datetime.fromisoformat(created.replace("Z", "+00:00")) if created else now
        await self._exec("INSERT", f"INSERT INTO {self.keyspace}.records (id, payload, created_at, updated_at) VALUES (%s, %s, %s, %s)", (rid, dumps(payload), created_dt, now))
        return Record(rid, payload, created, iso(now))

    async def get(self, record_id: str) -> Record | None:
        rows = await self._exec("SELECT", f"SELECT id, payload, created_at, updated_at FROM {self.keyspace}.records WHERE id = %s", (record_id,))
        return self._rec(rows[0]) if rows else None

    async def list(self, limit: int) -> list[Record]:
        rows = await self._exec("SELECT", f"SELECT id, payload, created_at, updated_at FROM {self.keyspace}.records LIMIT %s", (int(limit),))
        return sorted((self._rec(r) for r in rows), key=lambda r: r.created_at or "", reverse=True)

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        existing = await self.get(record_id)
        if existing is None:
            return None
        now = utcnow()
        await self._exec("UPDATE", f"UPDATE {self.keyspace}.records SET payload = %s, updated_at = %s WHERE id = %s", (dumps(payload), now, record_id))
        return Record(record_id, payload, existing.created_at, iso(now))

    async def delete(self, record_id: str) -> bool:
        if await self.get(record_id) is None:
            return False
        await self._exec("DELETE", f"DELETE FROM {self.keyspace}.records WHERE id = %s", (record_id,))
        return True
