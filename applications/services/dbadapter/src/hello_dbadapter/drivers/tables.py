"""Table driver for cosmos-table (Azure Cosmos DB for Table) and table-storage (Azure Table Storage)
using azure-data-tables (async).

Environment:
  TABLES_ENDPOINT          https://<account>.table.core.windows.net  |  https://<account>.table.cosmos.azure.com
  TABLES_AUTH              entra (default) | connection_string
  TABLES_CONNECTION_STRING secret reference / Azurite (local)
  TABLES_TABLE             default "adapterrecords"
Entities: PartitionKey "records", RowKey = record id, payload stored as a JSON string.
"""

from __future__ import annotations

import os
from typing import Any

from .base import Driver, Record, dumps, iso, loads, new_id, utcnow

PARTITION = "records"


class TablesDriver(Driver):
    db_system = "azure.tables"

    def __init__(self, family: str = "table-storage", table: Any = None) -> None:
        self.family = family
        self._table = table
        self.db_system = "cosmosdb" if family == "cosmos-table" else "azure.tables"

    async def open(self) -> None:
        if self._table is not None:
            return
        from azure.core.exceptions import ResourceExistsError
        from azure.data.tables.aio import TableClient

        name = os.environ.get("TABLES_TABLE", "adapterrecords")
        if os.environ.get("TABLES_AUTH", "entra").lower() == "connection_string":
            self._table = TableClient.from_connection_string(os.environ["TABLES_CONNECTION_STRING"], table_name=name)
        else:
            from hello_common.azure_auth import get_credential

            self._table = TableClient(endpoint=os.environ["TABLES_ENDPOINT"], table_name=name, credential=get_credential(async_=True))
        try:
            await self._table.create_table()
        except ResourceExistsError:
            pass

    async def close(self) -> None:
        if self._table is not None:
            await self._table.close()

    @staticmethod
    def _rec(e: dict[str, Any]) -> Record:
        return Record(e["RowKey"], loads(e.get("payload")), e.get("created_at"), e.get("updated_at"))

    async def ping(self) -> None:
        self.fault_hook()
        async for _ in self._table.query_entities(f"PartitionKey eq '{PARTITION}'", results_per_page=1, select=["RowKey"]):
            break

    async def _get_entity(self, rid: str) -> dict[str, Any] | None:
        from azure.core.exceptions import ResourceNotFoundError

        try:
            return await self._table.get_entity(PARTITION, rid)
        except ResourceNotFoundError:
            return None

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        from azure.data.tables import UpdateMode

        self.fault_hook()
        rid = record_id or new_id()
        now = iso(utcnow())
        existing = await self._get_entity(rid) if record_id else None
        entity = {
            "PartitionKey": PARTITION,
            "RowKey": rid,
            "payload": dumps(payload),
            "created_at": existing["created_at"] if existing else now,
            "updated_at": now,
        }
        await self._table.upsert_entity(entity, mode=UpdateMode.REPLACE)
        return self._rec(entity)

    async def get(self, record_id: str) -> Record | None:
        self.fault_hook()
        e = await self._get_entity(record_id)
        return self._rec(e) if e else None

    async def list(self, limit: int) -> list[Record]:
        self.fault_hook()
        out: list[Record] = []
        async for e in self._table.query_entities(f"PartitionKey eq '{PARTITION}'", results_per_page=min(int(limit), 1000)):
            out.append(self._rec(e))
            if len(out) >= limit:
                break
        return sorted(out, key=lambda r: r.created_at or "", reverse=True)

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        from azure.core import MatchConditions
        from azure.data.tables import UpdateMode

        self.fault_hook()
        e = await self._get_entity(record_id)
        if e is None:
            return None
        e["payload"] = dumps(payload)
        e["updated_at"] = iso(utcnow())
        await self._table.update_entity(e, mode=UpdateMode.REPLACE, etag=e.metadata["etag"], match_condition=MatchConditions.IfNotModified)
        return self._rec(e)

    async def delete(self, record_id: str) -> bool:
        self.fault_hook()
        if await self._get_entity(record_id) is None:
            return False
        await self._table.delete_entity(PARTITION, record_id)
        return True
