"""Cache-aside over Azure Managed Redis (TLS, port 10000, Entra ID via redis-entraid).

Results reported in the ``X-Cache`` header and the ``hello.catalog.cache.requests`` metric
(attribute ``cache.result`` = hit|miss|bypass): BYPASS when the cache is disabled, erroring or the
``dependency_timeout`` fault fires - a cache outage never fails a read.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from hello_common.faults import FaultInjectedError, check_fault

from .settings import RedisSettings

log = logging.getLogger("hello_catalog.cache")

HIT, MISS, BYPASS = "HIT", "MISS", "BYPASS"


def build_client(settings: RedisSettings) -> Any:
    """redis.asyncio client (or cluster client) with Entra credential provider when REDIS_AUTH=entra."""
    import redis.asyncio as aioredis
    from redis.asyncio.cluster import RedisCluster

    kwargs: dict[str, Any] = {
        "host": settings.host,
        "port": settings.port,
        "ssl": settings.tls,
        "socket_timeout": 1.0,
        "socket_connect_timeout": 2.0,
        "decode_responses": True,
        "health_check_interval": 30,
    }
    if settings.auth == "entra":
        import os

        from redis_entraid.cred_provider import (
            create_from_default_azure_credential,
            create_from_managed_identity,
        )
        from redis_entraid.identity_provider import ManagedIdentityIdType, ManagedIdentityType

        client_id = os.environ.get("AZURE_CLIENT_ID")
        if client_id and (os.environ.get("AZURE_CREDENTIAL_MODE") or "default") == "managed_identity":
            kwargs["credential_provider"] = create_from_managed_identity(
                identity_type=ManagedIdentityType.USER_ASSIGNED,
                resource="https://redis.azure.com/",
                id_type=ManagedIdentityIdType.CLIENT_ID,
                id_value=client_id,
            )
        else:
            # DefaultAzureCredential honours AZURE_CLIENT_ID (managed / workload identity).
            kwargs["credential_provider"] = create_from_default_azure_credential(("https://redis.azure.com/.default",))
    elif settings.auth == "password" and settings.password:
        kwargs["password"] = settings.password
    if settings.cluster:
        kwargs.pop("health_check_interval", None)
        return RedisCluster(**kwargs)
    kwargs["max_connections"] = 50
    return aioredis.Redis(**kwargs)


class CatalogCache:
    def __init__(self, settings: RedisSettings, client: Any = None) -> None:
        self.settings = settings
        self.client = client if client is not None else (build_client(settings) if settings.enabled else None)

    @property
    def enabled(self) -> bool:
        return self.client is not None

    def key(self, sku: str) -> str:
        return f"{self.settings.prefix}product:{sku}"

    async def get(self, sku: str) -> tuple[str, dict | None]:
        if not self.enabled:
            return BYPASS, None
        try:
            check_fault("dependency_timeout")
            raw = await self.client.get(self.key(sku))
        except (FaultInjectedError, Exception) as exc:
            log.warning("cache read failed; bypassing", extra={"error.kind": type(exc).__name__, "cache.operation": "get"})
            return BYPASS, None
        if raw is None:
            return MISS, None
        try:
            return HIT, json.loads(raw)
        except ValueError:
            return MISS, None

    async def set(self, sku: str, value: dict) -> None:
        if not self.enabled:
            return
        try:
            await self.client.set(self.key(sku), json.dumps(value, default=str), ex=self.settings.ttl_seconds)
        except Exception as exc:
            log.warning("cache write failed", extra={"error.kind": type(exc).__name__, "cache.operation": "set"})

    async def invalidate(self, sku: str) -> None:
        if not self.enabled:
            return
        try:
            await self.client.delete(self.key(sku))
        except Exception as exc:
            log.warning("cache invalidate failed", extra={"error.kind": type(exc).__name__, "cache.operation": "delete"})

    async def ping(self) -> dict[str, Any]:
        if not self.enabled:
            return {"detail": "cache disabled (REDIS_HOST unset)"}
        try:
            await self.client.ping()
            return {"detail": "ok"}
        except Exception as exc:
            if self.settings.required:
                raise
            return {"detail": f"degraded: {type(exc).__name__} (reads bypass cache)"}

    async def close(self) -> None:
        if self.client is not None:
            try:
                await self.client.aclose()
            except Exception:  # pragma: no cover
                pass
