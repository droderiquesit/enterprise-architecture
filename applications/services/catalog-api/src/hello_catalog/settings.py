"""Configuration for hello-catalog-api (all from environment).

PG_HOST, PG_PORT (5432), PG_DATABASE (catalog), PG_USER, PG_AUTH (entra|password), PG_PASSWORD
(local only), PG_SSLMODE (require; ``disable`` for local containers), PG_POOL_MIN (1), PG_POOL_MAX (10),
PG_CONNECT_TIMEOUT_SECONDS (5), PG_STATEMENT_TIMEOUT_MS (5000)
REDIS_HOST (unset = cache disabled -> X-Cache: BYPASS), REDIS_PORT (10000 for Managed Redis),
REDIS_AUTH (entra|none|password), REDIS_PASSWORD (local only), REDIS_TLS (true), REDIS_CLUSTER (false;
set true for an OSS-cluster-policy Managed Redis), REDIS_REQUIRED (false: cache outage degrades to
BYPASS instead of failing readiness), CACHE_TTL_SECONDS (60), CACHE_PREFIX (catalog:)
MIGRATE_ON_STARTUP (true), SEED_ON_STARTUP (false)
"""

from __future__ import annotations

from dataclasses import dataclass

from hello_common.config import env_bool, env_choice, env_int, env_str


@dataclass(frozen=True)
class PgSettings:
    host: str
    port: int
    database: str
    user: str
    auth: str
    password: str | None
    sslmode: str
    pool_min: int
    pool_max: int
    connect_timeout: int
    statement_timeout_ms: int


@dataclass(frozen=True)
class RedisSettings:
    host: str | None
    port: int
    auth: str
    password: str | None
    tls: bool
    cluster: bool
    required: bool
    ttl_seconds: int
    prefix: str

    @property
    def enabled(self) -> bool:
        return bool(self.host)


@dataclass(frozen=True)
class Settings:
    pg: PgSettings
    redis: RedisSettings
    migrate_on_startup: bool
    seed_on_startup: bool


def load() -> Settings:
    auth = env_choice("PG_AUTH", "password", {"entra", "password"})
    pg = PgSettings(
        host=env_str("PG_HOST", "localhost"),
        port=env_int("PG_PORT", 5432, minimum=1, maximum=65535),
        database=env_str("PG_DATABASE", "catalog"),
        user=env_str("PG_USER", "postgres"),
        auth=auth,
        password=env_str("PG_PASSWORD") if auth == "password" else None,
        sslmode=env_str("PG_SSLMODE", "require"),
        pool_min=env_int("PG_POOL_MIN", 1, minimum=0, maximum=50),
        pool_max=env_int("PG_POOL_MAX", 10, minimum=1, maximum=100),
        connect_timeout=env_int("PG_CONNECT_TIMEOUT_SECONDS", 5, minimum=1, maximum=60),
        statement_timeout_ms=env_int("PG_STATEMENT_TIMEOUT_MS", 5000, minimum=100),
    )
    redis_auth = env_choice("REDIS_AUTH", "entra", {"entra", "none", "password"})
    redis = RedisSettings(
        host=env_str("REDIS_HOST"),
        port=env_int("REDIS_PORT", 10000, minimum=1, maximum=65535),
        auth=redis_auth,
        password=env_str("REDIS_PASSWORD") if redis_auth == "password" else None,
        tls=env_bool("REDIS_TLS", True),
        cluster=env_bool("REDIS_CLUSTER", False),
        required=env_bool("REDIS_REQUIRED", False),
        ttl_seconds=env_int("CACHE_TTL_SECONDS", 60, minimum=1, maximum=86400),
        prefix=env_str("CACHE_PREFIX", "catalog:"),
    )
    return Settings(pg=pg, redis=redis, migrate_on_startup=env_bool("MIGRATE_ON_STARTUP", True), seed_on_startup=env_bool("SEED_ON_STARTUP", False))
