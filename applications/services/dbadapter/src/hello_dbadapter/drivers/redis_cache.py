"""Redis driver with *cache* semantics (Azure Managed Redis): every key has a TTL, eviction is
tolerated (a missing key is a cache miss, not an error) and roundtrip reports hit/miss.

Environment:
  REDIS_HOST, REDIS_PORT (10000), REDIS_TLS (true), REDIS_AUTH (entra|none|password), REDIS_PASSWORD
  REDIS_CLUSTER (false; true for OSS cluster policy), REDIS_TTL_SECONDS (300), REDIS_PREFIX ("adapter:")
Boundary: key prefix ``adapter:``.
"""

from __future__ import annotations

import json
import os
from typing import Any

from .base import Driver, Record, iso, new_id, utcnow


def build_client() -> Any:
    import redis.asyncio as aioredis
    from redis.asyncio.cluster import RedisCluster

    kwargs: dict[str, Any] = dict(
        host=os.environ.get("REDIS_HOST", "localhost"), port=int(os.environ.get("REDIS_PORT", "10000")),
        ssl=os.environ.get("REDIS_TLS", "true").lower() == "true", socket_timeout=2.0, socket_connect_timeout=3.0, decode_responses=True,
    )
    auth = os.environ.get("REDIS_AUTH", "entra").lower()
    if auth == "entra":
        from redis_entraid.cred_provider import create_from_default_azure_credential

        kwargs["credential_provider"] = create_from_default_azure_credential(("https://redis.azure.com/.default",))
    elif auth == "password":
        kwargs["password"] = os.environ.get("REDIS_PASSWORD")
    if os.environ.get("REDIS_CLUSTER", "false").lower() == "true":
        return RedisCluster(**kwargs)
    return aioredis.Redis(max_connections=20, **kwargs)


class RedisDriver(Driver):
    db_system = "redis"
    cache_semantics = True

    def __init__(self, family: str = "redis", client: Any = None) -> None:
        self.family = family
        self._client = client
        self.prefix = os.environ.get("REDIS_PREFIX", "adapter:")
        self.ttl = int(os.environ.get("REDIS_TTL_SECONDS", "300"))
        self.last_result = "n/a"

    async def open(self) -> None:
        if self._client is None:
            self._client = build_client()

    async def close(self) -> None:
        if self._client is not None:
            await self._client.aclose()

    def _key(self, rid: str) -> str:
        return f"{self.prefix}record:{rid}"

    async def ping(self) -> None:
        self.fault_hook()
        await self._client.ping()

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        self.fault_hook()
        rid = record_id or new_id()
        now = iso(utcnow())
        rec = Record(rid, payload, now, now)
        await self._client.set(self._key(rid), json.dumps(rec.to_dict()), ex=self.ttl)
        return rec

    async def get(self, record_id: str) -> Record | None:
        self.fault_hook()
        raw = await self._client.get(self._key(record_id))
        self.last_result = "hit" if raw else "miss"
        if not raw:
            return None
        doc = json.loads(raw)
        ttl = await self._client.ttl(self._key(record_id))
        return Record(doc["id"], doc["payload"], doc.get("created_at"), doc.get("updated_at"), extra={"ttl_seconds": ttl})

    async def list(self, limit: int) -> list[Record]:
        self.fault_hook()
        out: list[Record] = []
        async for key in self._client.scan_iter(match=f"{self.prefix}record:*", count=100):
            raw = await self._client.get(key)
            if raw:  # may have expired between SCAN and GET
                doc = json.loads(raw)
                out.append(Record(doc["id"], doc["payload"], doc.get("created_at"), doc.get("updated_at")))
            if len(out) >= limit:
                break
        return out

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        self.fault_hook()
        raw = await self._client.get(self._key(record_id))
        if not raw:
            return None
        doc = json.loads(raw)
        doc.update(payload=payload, updated_at=iso(utcnow()))
        await self._client.set(self._key(record_id), json.dumps(doc), ex=self.ttl)
        return Record(doc["id"], payload, doc.get("created_at"), doc["updated_at"])

    async def delete(self, record_id: str) -> bool:
        self.fault_hook()
        return bool(await self._client.delete(self._key(record_id)))
