"""SQL Server family driver (sql = Azure SQL Database, sqlmi = SQL Managed Instance, sqlvm = SQL Server on VM)
using Microsoft's GA ``mssql-python`` driver (bundled ODBC core, no msodbcsql install; Entra ID modes built in).

Environment:
  SQL_CONNECTION_STRING   full connection string (secret reference; overrides the parts below)
  SQL_SERVER              host[,port] e.g. eh-sql-adapter-dev.database.windows.net or 10.41.8.4,1433
  SQL_DATABASE            default "adapter"
  SQL_AUTH                entra (default) | password
                          entra => Authentication=ActiveDirectoryMSI;UID=$AZURE_CLIENT_ID (user-assigned MI)
                                   or ActiveDirectoryDefault when AZURE_CLIENT_ID is unset
  SQL_USER / SQL_PASSWORD SQL authentication (local containers, SQL Server on VM without Entra)
  SQL_ENCRYPT             yes (default) | strict | no
  SQL_TRUST_SERVER_CERTIFICATE  no (default); yes only for local/self-signed SQL Server on VM
  SQL_CONNECT_TIMEOUT     seconds, default 10
  SQL_POOL_MAX            default 20 (mssql-python built-in pooling)
Boundary: schema ``adapter``, table ``adapter.records`` (created idempotently).
"""

from __future__ import annotations

import os
from typing import Any

from .base import Driver, Record, dumps, iso, loads, new_id

DDL = [
    "IF SCHEMA_ID(N'adapter') IS NULL EXEC(N'CREATE SCHEMA adapter')",
    """IF OBJECT_ID(N'adapter.records', N'U') IS NULL
       CREATE TABLE adapter.records (
         id NVARCHAR(64) NOT NULL CONSTRAINT PK_adapter_records PRIMARY KEY,
         payload NVARCHAR(MAX) NOT NULL,
         created_at DATETIME2(3) NOT NULL CONSTRAINT DF_adapter_records_created DEFAULT SYSUTCDATETIME(),
         updated_at DATETIME2(3) NOT NULL CONSTRAINT DF_adapter_records_updated DEFAULT SYSUTCDATETIME())""",
]
UPSERT = """MERGE adapter.records WITH (HOLDLOCK) AS t
USING (SELECT ? AS id, ? AS payload) AS s ON t.id = s.id
WHEN MATCHED THEN UPDATE SET payload = s.payload, updated_at = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (id, payload) VALUES (s.id, s.payload);"""
SELECT_ONE = "SELECT id, payload, created_at, updated_at FROM adapter.records WHERE id = ?"


def build_connection_string(env: dict[str, str] | None = None) -> str:
    env = dict(os.environ if env is None else env)
    if env.get("SQL_CONNECTION_STRING"):
        return env["SQL_CONNECTION_STRING"]
    server = env.get("SQL_SERVER")
    if not server:
        raise ValueError("SQL_SERVER or SQL_CONNECTION_STRING is required")
    if "," not in server and ":" not in server:
        server = f"{server},1433"
    parts = [
        f"Server=tcp:{server}",
        f"Database={env.get('SQL_DATABASE', 'adapter')}",
        f"Encrypt={env.get('SQL_ENCRYPT', 'yes')}",
        f"TrustServerCertificate={env.get('SQL_TRUST_SERVER_CERTIFICATE', 'no')}",
        f"Connection Timeout={env.get('SQL_CONNECT_TIMEOUT', '10')}",
        "APP=hello-dbadapter",
    ]
    auth = env.get("SQL_AUTH", "entra").lower()
    if auth == "password":
        parts += [f"UID={env.get('SQL_USER', '')}", f"PWD={env.get('SQL_PASSWORD', '')}"]
    else:
        client_id = env.get("AZURE_CLIENT_ID")
        if client_id:
            parts += ["Authentication=ActiveDirectoryMSI", f"UID={client_id}"]
        else:
            parts += ["Authentication=ActiveDirectoryDefault"]
    return ";".join(parts) + ";"


class SqlDriver(Driver):
    db_system = "mssql"

    def __init__(self, family: str = "sql", connect: Any = None, connection_string: str | None = None) -> None:
        self.family = family
        self._conn_str = connection_string
        self._connect = connect

    def _connection(self):
        if self._connect is None:
            import mssql_python

            mssql_python.pooling(max_size=int(os.environ.get("SQL_POOL_MAX", "20")), idle_timeout=300)
            self._connect = mssql_python.connect
        if self._conn_str is None:
            self._conn_str = build_connection_string()
        return self._connect(self._conn_str, autocommit=True)

    def _exec(self, sql: str, params: tuple = (), fetch: str | None = None) -> Any:
        conn = self._connection()
        try:
            cur = conn.cursor()
            cur.execute(sql, params) if params else cur.execute(sql)
            if fetch == "one":
                return cur.fetchone()
            if fetch == "all":
                return cur.fetchall()
            return cur.rowcount
        finally:
            conn.close()

    async def _run(self, operation: str, sql: str, params: tuple = (), fetch: str | None = None) -> Any:
        self.fault_hook()
        with self.client_span(operation, **{"db.query.text": sql.split("\n")[0][:120], "db.namespace": os.environ.get("SQL_DATABASE", "adapter")}):
            return await self.in_thread(self._exec, sql, params, fetch)

    async def open(self) -> None:
        for statement in DDL:
            await self._run("DDL", statement)

    async def ping(self) -> None:
        await self._run("SELECT", "SELECT 1", fetch="one")

    @staticmethod
    def _row(row: Any) -> Record:
        rid, payload, created, updated = row[0], row[1], row[2], row[3]
        return Record(rid, loads(payload), iso(created), iso(updated))

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        rid = record_id or new_id()
        await self._run("MERGE", UPSERT, (rid, dumps(payload)))
        return await self.get(rid)  # type: ignore[return-value]

    async def get(self, record_id: str) -> Record | None:
        row = await self._run("SELECT", SELECT_ONE, (record_id,), fetch="one")
        return self._row(row) if row else None

    async def list(self, limit: int) -> list[Record]:
        rows = await self._run("SELECT", "SELECT TOP (?) id, payload, created_at, updated_at FROM adapter.records ORDER BY created_at DESC", (int(limit),), fetch="all")
        return [self._row(r) for r in rows]

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        count = await self._run("UPDATE", "UPDATE adapter.records SET payload = ?, updated_at = SYSUTCDATETIME() WHERE id = ?", (dumps(payload), record_id))
        if not count:
            return None
        return await self.get(record_id)

    async def delete(self, record_id: str) -> bool:
        count = await self._run("DELETE", "DELETE FROM adapter.records WHERE id = ?", (record_id,))
        return bool(count)
