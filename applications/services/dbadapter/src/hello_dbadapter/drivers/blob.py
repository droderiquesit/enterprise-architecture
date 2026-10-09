"""Azure Blob Storage driver (azure-storage-blob async). One JSON blob per record.

Environment:
  BLOB_ACCOUNT_URL         https://<account>.blob.core.windows.net
  BLOB_AUTH                entra (default) | connection_string
  BLOB_CONNECTION_STRING   secret reference / Azurite (local)
  BLOB_CONTAINER           default "adapter"
Boundary: container ``adapter``, blobs ``records/<id>.json``.
"""

from __future__ import annotations

import json
import os
from typing import Any

from .base import Driver, Record, dumps, iso, new_id, utcnow

PREFIX = "records/"


class BlobDriver(Driver):
    db_system = "azure.blob"

    def __init__(self, family: str = "blob", container: Any = None) -> None:
        self.family = family
        self._container = container
        self._service = None

    async def open(self) -> None:
        if self._container is not None:
            return
        from azure.core.exceptions import ResourceExistsError
        from azure.storage.blob.aio import BlobServiceClient

        if os.environ.get("BLOB_AUTH", "entra").lower() == "connection_string":
            self._service = BlobServiceClient.from_connection_string(os.environ["BLOB_CONNECTION_STRING"])
        else:
            from hello_common.azure_auth import get_credential

            self._service = BlobServiceClient(os.environ["BLOB_ACCOUNT_URL"], credential=get_credential(async_=True))
        self._container = self._service.get_container_client(os.environ.get("BLOB_CONTAINER", "adapter"))
        try:
            await self._container.create_container()
        except ResourceExistsError:
            pass

    async def close(self) -> None:
        if self._service is not None:
            await self._service.close()

    @staticmethod
    def _name(rid: str) -> str:
        return f"{PREFIX}{rid}.json"

    async def ping(self) -> None:
        self.fault_hook()
        await self._container.get_container_properties()

    async def _read(self, rid: str) -> dict[str, Any] | None:
        from azure.core.exceptions import ResourceNotFoundError

        try:
            stream = await self._container.download_blob(self._name(rid))
            return json.loads(await stream.readall())
        except ResourceNotFoundError:
            return None

    async def _write(self, doc: dict[str, Any]) -> None:
        from azure.storage.blob import ContentSettings

        await self._container.upload_blob(self._name(doc["id"]), dumps(doc), overwrite=True, content_settings=ContentSettings(content_type="application/json"))

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        self.fault_hook()
        rid = record_id or new_id()
        now = iso(utcnow())
        existing = await self._read(rid) if record_id else None
        doc = {"id": rid, "payload": payload, "created_at": existing["created_at"] if existing else now, "updated_at": now}
        await self._write(doc)
        return Record(**doc)

    async def get(self, record_id: str) -> Record | None:
        self.fault_hook()
        doc = await self._read(record_id)
        return Record(**doc) if doc else None

    async def list(self, limit: int) -> list[Record]:
        self.fault_hook()
        out = []
        async for item in self._container.list_blobs(name_starts_with=PREFIX):
            doc = await self._read(item.name[len(PREFIX) : -5])
            if doc:
                out.append(Record(**doc))
            if len(out) >= limit:
                break
        return sorted(out, key=lambda r: r.created_at or "", reverse=True)

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        self.fault_hook()
        doc = await self._read(record_id)
        if doc is None:
            return None
        doc.update(payload=payload, updated_at=iso(utcnow()))
        await self._write(doc)
        return Record(**doc)

    async def delete(self, record_id: str) -> bool:
        from azure.core.exceptions import ResourceNotFoundError

        self.fault_hook()
        try:
            await self._container.delete_blob(self._name(record_id))
            return True
        except ResourceNotFoundError:
            return False
