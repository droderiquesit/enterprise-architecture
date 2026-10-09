"""MongoDB wire-protocol driver for cosmos-mongo (Azure Cosmos DB for MongoDB RU) and documentdb
(Azure DocumentDB, formerly Cosmos DB for MongoDB vCore) using pymongo's native asyncio client.

Environment:
  MONGO_URI          connection string. cosmos-mongo (RU) has no Entra data-plane auth -> secret
                     reference (dsv://..., Delinea DSV) resolved at start-up. documentdb + MONGO_AUTH=entra:
                     mongodb+srv://<cluster>.global.mongocluster.cosmos.azure.com/ (no credentials)
  MONGO_AUTH         connection_string (default) | entra  (documentdb only: MONGODB-OIDC with an
                     Azure Identity callback, scope https://ossrdbms-aad.database.windows.net/.default)
  MONGO_DATABASE     default "adapter";  MONGO_COLLECTION default "records"
Boundary: database ``adapter`` / collection ``records``.
"""

from __future__ import annotations

import os
from typing import Any

from .base import Driver, Record, iso, new_id, utcnow


def oidc_properties() -> dict[str, Any]:
    from pymongo.auth_oidc import OIDCCallback, OIDCCallbackContext, OIDCCallbackResult

    from hello_common.azure_auth import SCOPE_OSSRDBMS, get_credential

    class AzureIdentityCallback(OIDCCallback):
        def fetch(self, context: OIDCCallbackContext) -> OIDCCallbackResult:
            token = get_credential().get_token(SCOPE_OSSRDBMS)
            return OIDCCallbackResult(access_token=token.token, expires_in_seconds=max(0, int(token.expires_on) - int(__import__("time").time())))

    return {"OIDC_CALLBACK": AzureIdentityCallback()}


class MongoDriver(Driver):
    db_system = "mongodb"

    def __init__(self, family: str = "cosmos-mongo", collection: Any = None) -> None:
        self.family = family
        self._collection = collection
        self._client = None

    async def open(self) -> None:
        if self._collection is not None:
            return
        from pymongo import AsyncMongoClient

        uri = os.environ["MONGO_URI"]
        kwargs: dict[str, Any] = dict(
            serverSelectionTimeoutMS=5000,
            connectTimeoutMS=5000,
            socketTimeoutMS=10000,
            maxPoolSize=20,
            retryWrites=False,
            appname=f"hello-dbadapter-{self.family}",
        )
        if os.environ.get("MONGO_AUTH", "connection_string").lower() == "entra":
            kwargs.update(authMechanism="MONGODB-OIDC", authMechanismProperties=oidc_properties(), tls=True)
        self._client = AsyncMongoClient(uri, **kwargs)
        db = self._client[os.environ.get("MONGO_DATABASE", "adapter")]
        self._collection = db[os.environ.get("MONGO_COLLECTION", "records")]

    async def close(self) -> None:
        if self._client is not None:
            await self._client.close()

    @staticmethod
    def _rec(doc: dict[str, Any]) -> Record:
        return Record(str(doc["_id"]), doc.get("payload", {}), iso(doc.get("created_at")), iso(doc.get("updated_at")))

    async def ping(self) -> None:
        self.fault_hook()
        await self._collection.database.command("ping")

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        self.fault_hook()
        rid = record_id or new_id()
        now = utcnow()
        await self._collection.update_one({"_id": rid}, {"$set": {"payload": payload, "updated_at": now}, "$setOnInsert": {"created_at": now}}, upsert=True)
        return await self.get(rid)  # type: ignore[return-value]

    async def get(self, record_id: str) -> Record | None:
        self.fault_hook()
        doc = await self._collection.find_one({"_id": record_id})
        return self._rec(doc) if doc else None

    async def list(self, limit: int) -> list[Record]:
        self.fault_hook()
        # No server-side sort: Cosmos RU requires an index for ORDER BY; sort the bounded page client-side.
        docs = await self._collection.find({}).limit(int(limit)).to_list(length=int(limit))
        return sorted((self._rec(d) for d in docs), key=lambda r: r.created_at or "", reverse=True)

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        self.fault_hook()
        res = await self._collection.update_one({"_id": record_id}, {"$set": {"payload": payload, "updated_at": utcnow()}})
        if res.matched_count == 0:
            return None
        return await self.get(record_id)

    async def delete(self, record_id: str) -> bool:
        self.fault_hook()
        return (await self._collection.delete_one({"_id": record_id})).deleted_count == 1
