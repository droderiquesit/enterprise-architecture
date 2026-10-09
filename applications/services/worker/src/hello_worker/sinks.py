"""Notification sinks: Azure Table Storage (idempotent upsert keyed by order id) or memory."""

from __future__ import annotations

from typing import Any, Protocol

from hello_common.faults import check_fault

PARTITION = "order"


class NotificationSink(Protocol):
    async def open(self) -> None: ...
    async def upsert(self, order_id: str, entity: dict[str, Any]) -> None: ...
    async def ping(self) -> None: ...
    async def close(self) -> None: ...


class MemorySink:
    def __init__(self) -> None:
        self.rows: dict[str, dict[str, Any]] = {}
        self.writes = 0

    async def open(self) -> None:
        return None

    async def upsert(self, order_id: str, entity: dict[str, Any]) -> None:
        check_fault("db_error")
        self.writes += 1
        self.rows[order_id] = {"PartitionKey": PARTITION, "RowKey": order_id, **entity}

    async def ping(self) -> None:
        return None

    async def close(self) -> None:
        return None


class TableSink:
    def __init__(self, settings: Any, client: Any = None) -> None:
        self.s = settings
        self._table = client

    async def open(self) -> None:
        if self._table is not None:
            return
        from azure.core.exceptions import ResourceExistsError
        from azure.data.tables.aio import TableClient

        if self.s.tables_connection_string:
            self._table = TableClient.from_connection_string(self.s.tables_connection_string, table_name=self.s.table_name)
        else:
            if not self.s.tables_endpoint:
                raise ValueError("TABLES_ENDPOINT or TABLES_CONNECTION_STRING is required in table mode")
            from hello_common.azure_auth import get_credential

            self._table = TableClient(endpoint=self.s.tables_endpoint, table_name=self.s.table_name, credential=get_credential(async_=True))
        try:
            await self._table.create_table()
        except ResourceExistsError:
            pass
        except Exception:  # identity may lack table-create rights; the platform layer creates the table
            pass

    async def upsert(self, order_id: str, entity: dict[str, Any]) -> None:
        from azure.data.tables import UpdateMode

        check_fault("db_error")
        await self._table.upsert_entity({"PartitionKey": PARTITION, "RowKey": order_id, **entity}, mode=UpdateMode.REPLACE)

    async def ping(self) -> None:
        async for _ in self._table.query_entities(f"PartitionKey eq '{PARTITION}'", results_per_page=1, select=["RowKey"]):
            break

    async def close(self) -> None:
        if self._table is not None:
            await self._table.close()
