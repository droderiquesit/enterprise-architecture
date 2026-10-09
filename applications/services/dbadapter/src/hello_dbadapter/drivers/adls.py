"""Azure Data Lake Storage Gen2 driver (azure-storage-file-datalake async, hierarchical namespace).

Environment:
  ADLS_ACCOUNT_URL          https://<account>.dfs.core.windows.net
  ADLS_AUTH                 entra (default) | connection_string ; ADLS_CONNECTION_STRING (local/secret)
  ADLS_FILESYSTEM           default "adapter"
Boundary: filesystem ``adapter``, directory ``records/``, one ``<id>.json`` file per record.
"""

from __future__ import annotations

import json
import os
from typing import Any

from .base import Driver, Record, dumps, iso, new_id, utcnow

DIRECTORY = "records"


class AdlsDriver(Driver):
    db_system = "azure.datalake"

    def __init__(self, family: str = "adls", filesystem: Any = None) -> None:
        self.family = family
        self._fs = filesystem
        self._service = None

    async def open(self) -> None:
        if self._fs is not None:
            return
        from azure.core.exceptions import ResourceExistsError
        from azure.storage.filedatalake.aio import DataLakeServiceClient

        if os.environ.get("ADLS_AUTH", "entra").lower() == "connection_string":
            self._service = DataLakeServiceClient.from_connection_string(os.environ["ADLS_CONNECTION_STRING"])
        else:
            from hello_common.azure_auth import get_credential

            self._service = DataLakeServiceClient(os.environ["ADLS_ACCOUNT_URL"], credential=get_credential(async_=True))
        self._fs = self._service.get_file_system_client(os.environ.get("ADLS_FILESYSTEM", "adapter"))
        try:
            await self._fs.create_file_system()
        except ResourceExistsError:
            pass
        await self._fs.get_directory_client(DIRECTORY).create_directory()

    async def close(self) -> None:
        if self._service is not None:
            await self._service.close()

    @staticmethod
    def _path(rid: str) -> str:
        return f"{DIRECTORY}/{rid}.json"

    async def ping(self) -> None:
        self.fault_hook()
        await self._fs.get_file_system_properties()

    async def _read(self, rid: str) -> dict[str, Any] | None:
        from azure.core.exceptions import ResourceNotFoundError

        try:
            stream = await self._fs.get_file_client(self._path(rid)).download_file()
            return json.loads(await stream.readall())
        except ResourceNotFoundError:
            return None

    async def _write(self, doc: dict[str, Any]) -> None:
        await self._fs.get_file_client(self._path(doc["id"])).upload_data(dumps(doc), overwrite=True)

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
        async for path in self._fs.get_paths(path=DIRECTORY, recursive=False):
            if path.is_directory:
                continue
            doc = await self._read(path.name.rsplit("/", 1)[-1][:-5])
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
            await self._fs.get_file_client(self._path(record_id)).delete_file()
            return True
        except ResourceNotFoundError:
            return False
