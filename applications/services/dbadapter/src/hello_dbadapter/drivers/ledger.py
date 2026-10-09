"""Azure Confidential Ledger driver - APPEND-ONLY: PUT/DELETE are rejected (HTTP 405).

Environment:
  LEDGER_ENDPOINT      https://<ledger-name>.confidential-ledger.azure.com
  LEDGER_COLLECTION    default "adapter"
  LEDGER_IDENTITY_URL  default https://identity.confidential-ledger.core.azure.com (TLS cert discovery)
Auth: Entra ID (managed identity via DefaultAzureCredential / AZURE_CLIENT_ID); the identity must be a
ledger user with Contributor role (assigned by the platform layer).
Record id = ledger transaction id (e.g. "2.41"); the request's id is ignored because entries are immutable.
"""

from __future__ import annotations

import os
import tempfile
from typing import Any
from urllib.parse import urlparse

from .base import Driver, NotSupported, Record, dumps, iso, loads, utcnow


class LedgerDriver(Driver):
    db_system = "azure.confidentialledger"
    append_only = True

    def __init__(self, family: str = "ledger", client: Any = None) -> None:
        self.family = family
        self._client = client
        self.collection = os.environ.get("LEDGER_COLLECTION", "adapter")

    def _build(self) -> Any:
        from azure.confidentialledger import ConfidentialLedgerClient
        from azure.confidentialledger.certificate import ConfidentialLedgerCertificateClient

        from hello_common.azure_auth import get_credential

        endpoint = os.environ["LEDGER_ENDPOINT"]
        ledger_id = urlparse(endpoint).hostname.split(".")[0]
        identity = ConfidentialLedgerCertificateClient(os.environ.get("LEDGER_IDENTITY_URL", "https://identity.confidential-ledger.core.azure.com"))
        cert = identity.get_ledger_identity(ledger_id=ledger_id)["ledgerTlsCertificate"]
        path = os.path.join(tempfile.gettempdir(), f"{ledger_id}-tls.pem")
        with open(path, "w", encoding="ascii") as fh:
            fh.write(cert)
        return ConfidentialLedgerClient(endpoint=endpoint, credential=get_credential(), ledger_certificate_path=path)

    async def open(self) -> None:
        if self._client is None:
            self._client = await self.in_thread(self._build)

    async def close(self) -> None:
        if self._client is not None:
            await self.in_thread(self._client.close)

    async def ping(self) -> None:
        self.fault_hook()
        await self.in_thread(self._client.get_current_ledger_entry, collection_id=self.collection)

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        self.fault_hook()
        now = iso(utcnow())
        contents = dumps({"payload": payload, "created_at": now})
        result = await self.in_thread(lambda: self._client.begin_create_ledger_entry({"contents": contents}, collection_id=self.collection).result())
        tx = result["transactionId"]
        return Record(tx, payload, now, now, extra={"transaction_id": tx, "state": result.get("state")})

    async def get(self, record_id: str) -> Record | None:
        from azure.core.exceptions import HttpResponseError, ResourceNotFoundError

        self.fault_hook()
        try:
            result = await self.in_thread(lambda: self._client.begin_get_ledger_entry(record_id, collection_id=self.collection).result())
        except (ResourceNotFoundError, HttpResponseError) as exc:
            if isinstance(exc, ResourceNotFoundError) or getattr(exc, "status_code", None) in (400, 404):
                return None
            raise
        entry = result.get("entry") or {}
        doc = loads(entry.get("contents"))
        return Record(record_id, doc.get("payload", {}), doc.get("created_at"), doc.get("created_at"), extra={"transaction_id": record_id})

    async def list(self, limit: int) -> list[Record]:
        self.fault_hook()

        def _list() -> list[Record]:
            out = []
            for entry in self._client.list_ledger_entries(collection_id=self.collection):
                doc = loads(entry.get("contents"))
                out.append(Record(entry["transactionId"], doc.get("payload", {}), doc.get("created_at"), doc.get("created_at")))
                if len(out) >= limit:
                    break
            return out

        return await self.in_thread(_list)

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        raise NotSupported("ledger is append-only")

    async def delete(self, record_id: str) -> bool:
        raise NotSupported("ledger is append-only")

    async def seed(self, count: int) -> int:
        existing = await self.list(count)
        missing = max(0, count - len(existing))
        for i in range(len(existing) + 1, len(existing) + missing + 1):
            await self.create({"seed": i, "name": f"record-{i:03d}", "family": self.family})
        return missing
