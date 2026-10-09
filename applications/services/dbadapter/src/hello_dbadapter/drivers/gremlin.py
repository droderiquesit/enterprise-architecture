"""Azure Cosmos DB for Apache Gremlin driver (gremlinpython, GraphSON v2 as required by Cosmos DB).

Environment:
  GREMLIN_ENDPOINT   wss://<account>.gremlin.cosmos.azure.com:443/
  GREMLIN_DATABASE   default "adapter";  GREMLIN_GRAPH default "records" (partition key /pk)
  GREMLIN_KEY        account key (secret reference) - the Gremlin wire protocol has no Entra token auth
Boundary: database ``adapter`` / graph ``records``; each record is a vertex label ``record``.
Bindings are used for all values (no string-built traversals).
"""

from __future__ import annotations

import os
from typing import Any

from .base import Driver, Record, dumps, iso, loads, new_id, utcnow

PK = "records"


class GremlinDriver(Driver):
    db_system = "cosmosdb"

    def __init__(self, family: str = "cosmos-gremlin", client: Any = None) -> None:
        self.family = family
        self._client = client

    async def open(self) -> None:
        if self._client is not None:
            return
        from gremlin_python.driver import client, serializer

        db = os.environ.get("GREMLIN_DATABASE", "adapter")
        graph = os.environ.get("GREMLIN_GRAPH", "records")
        self._client = client.Client(
            os.environ["GREMLIN_ENDPOINT"], "g",
            username=f"/dbs/{db}/colls/{graph}", password=os.environ["GREMLIN_KEY"],
            message_serializer=serializer.GraphSONSerializersV2d0(), pool_size=4,
        )

    async def close(self) -> None:
        if self._client is not None:
            await self.in_thread(self._client.close)

    async def _submit(self, operation: str, query: str, bindings: dict[str, Any]) -> list[Any]:
        self.fault_hook()
        with self.client_span(operation, **{"db.query.text": query[:120]}):
            return await self.in_thread(lambda: self._client.submit(query, bindings).all().result(timeout=15))

    @staticmethod
    def _prop(v: dict[str, Any], name: str) -> Any:
        props = v.get("properties", {}).get(name)
        if isinstance(props, list) and props:
            return props[0].get("value")
        return None

    def _rec(self, v: dict[str, Any]) -> Record:
        return Record(v["id"], loads(self._prop(v, "payload")), self._prop(v, "created_at"), self._prop(v, "updated_at"))

    async def ping(self) -> None:
        await self._submit("count", "g.V().limit(1).count()", {})

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        rid = record_id or new_id()
        now = iso(utcnow())
        existing = await self.get(rid) if record_id else None
        if existing:
            return await self.update(rid, payload)  # type: ignore[return-value]
        q = "g.addV('record').property('id', rid).property('pk', pk).property('payload', payload).property('created_at', ts).property('updated_at', ts)"
        rows = await self._submit("addV", q, {"rid": rid, "pk": PK, "payload": dumps(payload), "ts": now})
        return self._rec(rows[0])

    async def get(self, record_id: str) -> Record | None:
        rows = await self._submit("V", "g.V(rid).has('pk', pk)", {"rid": record_id, "pk": PK})
        return self._rec(rows[0]) if rows else None

    async def list(self, limit: int) -> list[Record]:
        rows = await self._submit("V", "g.V().hasLabel('record').has('pk', pk).order().by('created_at', decr).limit(n)", {"pk": PK, "n": int(limit)})
        return [self._rec(r) for r in rows]

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        rows = await self._submit("property", "g.V(rid).has('pk', pk).property('payload', payload).property('updated_at', ts)",
                                  {"rid": record_id, "pk": PK, "payload": dumps(payload), "ts": iso(utcnow())})
        return self._rec(rows[0]) if rows else None

    async def delete(self, record_id: str) -> bool:
        rows = await self._submit("drop", "g.V(rid).has('pk', pk).sideEffect(drop()).count()", {"rid": record_id, "pk": PK})
        return bool(rows and rows[0])
