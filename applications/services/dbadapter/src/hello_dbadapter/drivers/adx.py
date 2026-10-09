"""Azure Data Explorer (Kusto) driver. ADX is append-oriented, so the adapter models records as an
append-only version log and resolves the latest version at query time:

  table Records (id:string, payload:dynamic, created_at:datetime, updated_at:datetime, deleted:bool)
  latest = Records | where id == X | summarize arg_max(updated_at, *) by id | where not(deleted)

create/update append a version row; delete appends a tombstone (deleted=true).

Environment:
  ADX_CLUSTER_URI   https://<cluster>.<region>.kusto.windows.net
  ADX_DATABASE      default "adapter";  ADX_TABLE default "Records"
  ADX_WRITE_MODE    inline (default; `.ingest inline` control command - immediately queryable, fine for
                    lab volumes) | streaming (azure-kusto-ingest ManagedStreamingIngestClient; requires
                    streaming ingestion enabled on the cluster/database)
  ADX_CREATE_TABLE  true (default; needs Database Admin/Ingestor+table create rights)
Auth: Entra ID via azure-identity (DefaultAzureCredential / AZURE_CLIENT_ID).
"""

from __future__ import annotations

import io
import json
import os
from typing import Any

from .base import Driver, Record, iso, new_id, utcnow


def _kql_str(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def _csv_field(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


class AdxDriver(Driver):
    db_system = "azure.kusto"

    def __init__(self, family: str = "adx", client: Any = None, ingest_client: Any = None) -> None:
        self.family = family
        self._client = client
        self._ingest = ingest_client
        self.database = os.environ.get("ADX_DATABASE", "adapter")
        self.table = os.environ.get("ADX_TABLE", "Records")
        self.mode = os.environ.get("ADX_WRITE_MODE", "inline").lower()

    def _build(self) -> None:
        from azure.kusto.data import KustoClient, KustoConnectionStringBuilder

        from hello_common.azure_auth import get_credential

        cluster = os.environ["ADX_CLUSTER_URI"]
        kcsb = KustoConnectionStringBuilder.with_azure_token_credential(cluster, get_credential())
        self._client = KustoClient(kcsb)
        if self.mode == "streaming":
            from azure.kusto.ingest import ManagedStreamingIngestClient

            self._ingest = ManagedStreamingIngestClient(kcsb)
        if os.environ.get("ADX_CREATE_TABLE", "true").lower() == "true":
            self._client.execute_mgmt(self.database, f".create-merge table {self.table} (id:string, payload:dynamic, created_at:datetime, updated_at:datetime, deleted:bool)")

    async def open(self) -> None:
        if self._client is None:
            await self.in_thread(self._build)

    async def close(self) -> None:
        if self._client is not None:
            await self.in_thread(self._client.close)

    async def _query(self, kql: str) -> list[dict[str, Any]]:
        self.fault_hook()
        with self.client_span("query", **{"db.namespace": self.database}):
            resp = await self.in_thread(self._client.execute_query, self.database, kql)
        table = resp.primary_results[0]
        return [r.to_dict() for r in table]

    async def _append(self, rid: str, payload: dict[str, Any], created: str, updated: str, deleted: bool) -> None:
        self.fault_hook()
        line = ",".join([_csv_field(rid), _csv_field(json.dumps(payload, separators=(",", ":"))), created, updated, "true" if deleted else "false"])
        with self.client_span("ingest", **{"db.namespace": self.database}):
            if self.mode == "streaming" and self._ingest is not None:
                from azure.kusto.data.data_format import DataFormat
                from azure.kusto.ingest import IngestionProperties

                props = IngestionProperties(database=self.database, table=self.table, data_format=DataFormat.CSV)
                await self.in_thread(self._ingest.ingest_from_stream, io.BytesIO((line + "\n").encode()), props)
            else:
                await self.in_thread(self._client.execute_mgmt, self.database, f".ingest inline into table {self.table} <|\n{line}")

    def _latest(self, where: str = "") -> str:
        return f"{self.table} {where}| summarize arg_max(updated_at, *) by id | where deleted == false"

    @staticmethod
    def _rec(row: dict[str, Any]) -> Record:
        payload = row.get("payload")
        if isinstance(payload, str):
            payload = json.loads(payload)
        return Record(row["id"], payload or {}, iso(row.get("created_at")), iso(row.get("updated_at")))

    async def ping(self) -> None:
        await self._query(f"{self.table} | take 1 | count")

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        rid = record_id or new_id()
        now = iso(utcnow())
        existing = await self.get(rid) if record_id else None
        created = existing.created_at if existing else now
        await self._append(rid, payload, created, now, False)
        return Record(rid, payload, created, now)

    async def get(self, record_id: str) -> Record | None:
        rows = await self._query(self._latest(f"| where id == {_kql_str(record_id)} "))
        return self._rec(rows[0]) if rows else None

    async def list(self, limit: int) -> list[Record]:
        rows = await self._query(self._latest() + f" | top {int(limit)} by created_at desc")
        return [self._rec(r) for r in rows]

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        existing = await self.get(record_id)
        if existing is None:
            return None
        now = iso(utcnow())
        await self._append(record_id, payload, existing.created_at, now, False)
        return Record(record_id, payload, existing.created_at, now)

    async def delete(self, record_id: str) -> bool:
        existing = await self.get(record_id)
        if existing is None:
            return False
        await self._append(record_id, existing.payload, existing.created_at, iso(utcnow()), True)
        return True
