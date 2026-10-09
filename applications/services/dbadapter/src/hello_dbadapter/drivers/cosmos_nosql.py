"""Azure Cosmos DB for NoSQL driver (azure-cosmos async SDK, Entra data-plane RBAC).

Environment:
  COSMOS_ENDPOINT    https://<account>.documents.azure.com:443/
  COSMOS_DATABASE    default "adapter";  COSMOS_CONTAINER default "records" (partition key /id)
  COSMOS_AUTH        entra (default) | key ; COSMOS_KEY only for the local emulator
  COSMOS_CREATE_IF_MISSING  false (default; with Entra RBAC the data plane cannot create databases -
                     the platform layer owns them); true for the emulator
Boundary: database ``adapter`` / container ``records``.
"""

from __future__ import annotations

import os
from typing import Any

from .base import Driver, Record, iso, new_id, utcnow


class CosmosNoSqlDriver(Driver):
    db_system = "cosmosdb"

    def __init__(self, family: str = "cosmos-nosql", container: Any = None) -> None:
        self.family = family
        self._container = container
        self._client = None

    async def open(self) -> None:
        if self._container is not None:
            return
        from azure.cosmos import PartitionKey
        from azure.cosmos.aio import CosmosClient

        endpoint = os.environ["COSMOS_ENDPOINT"]
        if os.environ.get("COSMOS_AUTH", "entra").lower() == "key":
            credential: Any = os.environ["COSMOS_KEY"]
        else:
            from hello_common.azure_auth import get_credential

            credential = get_credential(async_=True)
        self._client = CosmosClient(endpoint, credential=credential, connection_timeout=5)
        db_name = os.environ.get("COSMOS_DATABASE", "adapter")
        container_name = os.environ.get("COSMOS_CONTAINER", "records")
        if os.environ.get("COSMOS_CREATE_IF_MISSING", "false").lower() == "true":
            db = await self._client.create_database_if_not_exists(db_name)
            self._container = await db.create_container_if_not_exists(container_name, partition_key=PartitionKey(path="/id"))
        else:
            self._container = self._client.get_database_client(db_name).get_container_client(container_name)

    async def close(self) -> None:
        if self._client is not None:
            await self._client.close()

    @staticmethod
    def _rec(item: dict[str, Any]) -> Record:
        return Record(item["id"], item.get("payload", {}), item.get("created_at"), item.get("updated_at"))

    async def ping(self) -> None:
        self.fault_hook()
        await self._container.read()

    async def _read(self, record_id: str) -> dict[str, Any] | None:
        from azure.cosmos.exceptions import CosmosResourceNotFoundError

        try:
            return await self._container.read_item(item=record_id, partition_key=record_id)
        except CosmosResourceNotFoundError:
            return None

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        self.fault_hook()
        rid = record_id or new_id()
        now = iso(utcnow())
        existing = await self._read(rid) if record_id else None
        item = {"id": rid, "payload": payload, "created_at": existing["created_at"] if existing else now, "updated_at": now}
        return self._rec(await self._container.upsert_item(item))

    async def get(self, record_id: str) -> Record | None:
        self.fault_hook()
        item = await self._read(record_id)
        return self._rec(item) if item else None

    async def list(self, limit: int) -> list[Record]:
        self.fault_hook()
        query = "SELECT TOP @n c.id, c.payload, c.created_at, c.updated_at FROM c ORDER BY c.created_at DESC"
        items = [i async for i in self._container.query_items(query, parameters=[{"name": "@n", "value": int(limit)}])]
        return [self._rec(i) for i in items]

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        self.fault_hook()
        item = await self._read(record_id)
        if item is None:
            return None
        item.update(payload=payload, updated_at=iso(utcnow()))
        return self._rec(await self._container.replace_item(item=record_id, body=item))

    async def delete(self, record_id: str) -> bool:
        from azure.cosmos.exceptions import CosmosResourceNotFoundError

        self.fault_hook()
        try:
            await self._container.delete_item(item=record_id, partition_key=record_id)
            return True
        except CosmosResourceNotFoundError:
            return False
