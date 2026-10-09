"""Azure AI Search driver (azure-search-documents async). Records are documents in index ``adapter-records``.

Environment:
  SEARCH_ENDPOINT   https://<service>.search.windows.net
  SEARCH_AUTH       entra (default; Search Index Data Contributor + Search Service Contributor for index
                    creation) | key ; SEARCH_API_KEY (secret reference) for key auth
  SEARCH_INDEX      default "adapter-records"; SEARCH_CREATE_INDEX true (default)
Note: search is near-real-time - a document is retrievable by key immediately (get_document), but may
take ~1 s to appear in list (search) results.
"""

from __future__ import annotations

import os
from typing import Any

from .base import Driver, Record, dumps, iso, loads, new_id, utcnow


class SearchDriver(Driver):
    db_system = "azure.search"

    def __init__(self, family: str = "search", client: Any = None) -> None:
        self.family = family
        self._client = client
        self._index_client = None

    def _credential(self) -> Any:
        if os.environ.get("SEARCH_AUTH", "entra").lower() == "key":
            from azure.core.credentials import AzureKeyCredential

            return AzureKeyCredential(os.environ["SEARCH_API_KEY"])
        from hello_common.azure_auth import get_credential

        return get_credential(async_=True)

    async def open(self) -> None:
        if self._client is not None:
            return
        from azure.search.documents.aio import SearchClient
        from azure.search.documents.indexes.aio import SearchIndexClient
        from azure.search.documents.indexes.models import SearchFieldDataType, SearchIndex, SimpleField

        endpoint = os.environ["SEARCH_ENDPOINT"]
        name = os.environ.get("SEARCH_INDEX", "adapter-records")
        cred = self._credential()
        if os.environ.get("SEARCH_CREATE_INDEX", "true").lower() == "true":
            self._index_client = SearchIndexClient(endpoint, cred)
            index = SearchIndex(
                name=name,
                fields=[
                    SimpleField(name="id", type=SearchFieldDataType.String, key=True, filterable=True),
                    SimpleField(name="payload", type=SearchFieldDataType.String),
                    SimpleField(name="created_at", type=SearchFieldDataType.DateTimeOffset, sortable=True, filterable=True),
                    SimpleField(name="updated_at", type=SearchFieldDataType.DateTimeOffset, sortable=True),
                ],
            )
            await self._index_client.create_or_update_index(index)
        self._client = SearchClient(endpoint, name, cred)

    async def close(self) -> None:
        if self._client is not None:
            await self._client.close()
        if self._index_client is not None:
            await self._index_client.close()

    @staticmethod
    def _rec(doc: dict[str, Any]) -> Record:
        return Record(doc["id"], loads(doc.get("payload")), iso(doc.get("created_at")), iso(doc.get("updated_at")))

    async def ping(self) -> None:
        self.fault_hook()
        await self._client.get_document_count()

    async def _get(self, rid: str) -> dict[str, Any] | None:
        from azure.core.exceptions import ResourceNotFoundError

        try:
            return await self._client.get_document(key=rid)
        except ResourceNotFoundError:
            return None

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        self.fault_hook()
        rid = record_id or new_id()
        now = iso(utcnow())
        existing = await self._get(rid) if record_id else None
        doc = {"id": rid, "payload": dumps(payload), "created_at": iso(existing["created_at"]) if existing else now, "updated_at": now}
        await self._client.merge_or_upload_documents([doc])
        return self._rec(doc)

    async def get(self, record_id: str) -> Record | None:
        self.fault_hook()
        doc = await self._get(record_id)
        return self._rec(doc) if doc else None

    async def list(self, limit: int) -> list[Record]:
        self.fault_hook()
        results = await self._client.search(search_text="*", top=int(limit), order_by=["created_at desc"])
        return [self._rec(d) async for d in results]

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        self.fault_hook()
        doc = await self._get(record_id)
        if doc is None:
            return None
        doc = {"id": record_id, "payload": dumps(payload), "created_at": iso(doc.get("created_at")), "updated_at": iso(utcnow())}
        await self._client.merge_documents([doc])
        return self._rec(doc)

    async def delete(self, record_id: str) -> bool:
        self.fault_hook()
        if await self._get(record_id) is None:
            return False
        await self._client.delete_documents([{"id": record_id}])
        return True
