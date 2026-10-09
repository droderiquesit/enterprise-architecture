"""Product persistence: PostgreSQL (psycopg 3 async pool) or in-memory (tests / local UI work)."""

from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime
from typing import Any, Protocol

from hello_common.faults import check_fault

from .models import Product, ProductIn, with_price
from .settings import PgSettings

log = logging.getLogger("hello_catalog.repository")

MIGRATION_LOCK_ID = 724001
MIGRATIONS: list[tuple[int, list[str]]] = [
    (
        1,
        [
            "CREATE SCHEMA IF NOT EXISTS catalog",
            """CREATE TABLE IF NOT EXISTS catalog.products (
                   sku          text PRIMARY KEY,
                   name         text NOT NULL,
                   description  text NOT NULL DEFAULT '',
                   unit_price   numeric(12,2) NOT NULL CHECK (unit_price > 0),
                   currency     char(3) NOT NULL DEFAULT 'USD',
                   category     text NOT NULL DEFAULT 'general',
                   active       boolean NOT NULL DEFAULT true,
                   created_at   timestamptz NOT NULL DEFAULT now(),
                   updated_at   timestamptz NOT NULL DEFAULT now()
               )""",
            "CREATE INDEX IF NOT EXISTS products_category_idx ON catalog.products (category)",
        ],
    ),
]

_COLUMNS = "sku, name, description, unit_price, currency, category, active, updated_at"
_UPSERT = f"""
INSERT INTO catalog.products (sku, name, description, unit_price, currency, category, active, updated_at)
VALUES (%(sku)s, %(name)s, %(description)s, %(unit_price)s, %(currency)s, %(category)s, %(active)s, now())
ON CONFLICT (sku) DO UPDATE SET
    name = EXCLUDED.name, description = EXCLUDED.description, unit_price = EXCLUDED.unit_price,
    currency = EXCLUDED.currency, category = EXCLUDED.category, active = EXCLUDED.active, updated_at = now()
RETURNING {_COLUMNS}
"""


def _row_to_product(row: tuple[Any, ...]) -> Product:
    sku, name, description, unit_price, currency, category, active, updated_at = row
    return with_price(Product(sku=sku, name=name, description=description, unit_price=float(unit_price), currency=currency.strip(),
                              category=category, active=active, updated_at=updated_at))


class ProductRepository(Protocol):
    async def open(self) -> None: ...
    async def close(self) -> None: ...
    async def migrate(self) -> None: ...
    async def ping(self) -> None: ...
    async def list(self, limit: int, offset: int, category: str | None) -> list[Product]: ...
    async def get(self, sku: str) -> Product | None: ...
    async def upsert(self, product: ProductIn) -> Product: ...
    async def upsert_many(self, products: list[ProductIn]) -> int: ...


class InMemoryRepository:
    def __init__(self) -> None:
        self._items: dict[str, Product] = {}
        self.reads = 0

    async def open(self) -> None:
        return None

    async def close(self) -> None:
        return None

    async def migrate(self) -> None:
        return None

    async def ping(self) -> None:
        check_fault("db_error")

    async def list(self, limit: int, offset: int, category: str | None) -> list[Product]:
        check_fault("db_error")
        items = sorted(self._items.values(), key=lambda p: p.sku)
        if category:
            items = [p for p in items if p.category == category]
        return items[offset : offset + limit]

    async def get(self, sku: str) -> Product | None:
        check_fault("db_error")
        self.reads += 1
        return self._items.get(sku)

    async def upsert(self, product: ProductIn) -> Product:
        check_fault("db_error")
        stored = Product(**product.model_dump(), updated_at=datetime.now(UTC))
        stored.unit_price = float(product.unit_price)
        with_price(stored)
        self._items[product.sku] = stored
        return stored

    async def upsert_many(self, products: list[ProductIn]) -> int:
        for p in products:
            await self.upsert(p)
        return len(products)


class PostgresRepository:
    """psycopg 3 AsyncConnectionPool. With PG_AUTH=entra the password is a fresh Entra access token
    (scope https://ossrdbms-aad.database.windows.net/.default) fetched for every *new* connection, and
    connections are recycled (max_lifetime) well before token expiry."""

    def __init__(self, settings: PgSettings, application_name: str, token_cache: Any = None) -> None:
        import psycopg
        from psycopg.conninfo import make_conninfo
        from psycopg_pool import AsyncConnectionPool

        self.settings = settings
        if settings.auth == "entra" and token_cache is None:
            from hello_common.azure_auth import SCOPE_OSSRDBMS, TokenCache

            token_cache = TokenCache(SCOPE_OSSRDBMS)
        cache = token_cache if settings.auth == "entra" else None

        class _Conn(psycopg.AsyncConnection):  # type: ignore[misc]
            @classmethod
            async def connect(cls, conninfo: str = "", **kwargs: Any):  # type: ignore[override]
                if cache is not None:
                    kwargs["password"] = await asyncio.to_thread(cache.get)
                return await super().connect(conninfo, **kwargs)

        conninfo = make_conninfo(
            host=settings.host,
            port=settings.port,
            dbname=settings.database,
            user=settings.user,
            sslmode=settings.sslmode,
            connect_timeout=settings.connect_timeout,
            application_name=application_name[:63],
            options=f"-c statement_timeout={settings.statement_timeout_ms}",
        )
        kwargs: dict[str, Any] = {"autocommit": True}
        if settings.auth == "password" and settings.password:
            kwargs["password"] = settings.password
        self.pool = AsyncConnectionPool(
            conninfo,
            connection_class=_Conn,
            kwargs=kwargs,
            min_size=settings.pool_min,
            max_size=settings.pool_max,
            timeout=float(settings.connect_timeout),
            max_lifetime=50 * 60.0,
            max_idle=300.0,
            reconnect_timeout=60.0,
            check=AsyncConnectionPool.check_connection,
            open=False,
            name="catalog",
        )

    async def open(self) -> None:
        await self.pool.open(wait=False)

    async def close(self) -> None:
        await self.pool.close(timeout=5)

    async def migrate(self) -> None:
        async with self.pool.connection() as conn:
            async with conn.transaction():
                await conn.execute("SELECT pg_advisory_xact_lock(%s)", (MIGRATION_LOCK_ID,))
                await conn.execute("CREATE SCHEMA IF NOT EXISTS catalog")
                await conn.execute(
                    "CREATE TABLE IF NOT EXISTS catalog.schema_migrations (version int PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
                )
                cur = await conn.execute("SELECT version FROM catalog.schema_migrations")
                applied = {row[0] for row in await cur.fetchall()}
                for version, statements in MIGRATIONS:
                    if version in applied:
                        continue
                    for statement in statements:
                        await conn.execute(statement)
                    await conn.execute("INSERT INTO catalog.schema_migrations (version) VALUES (%s) ON CONFLICT DO NOTHING", (version,))
                    log.info("applied catalog migration", extra={"migration.version": version})

    async def ping(self) -> None:
        check_fault("db_error")
        async with self.pool.connection(timeout=2.0) as conn:
            await conn.execute("SELECT 1")

    async def list(self, limit: int, offset: int, category: str | None) -> list[Product]:
        check_fault("db_error")
        async with self.pool.connection() as conn:
            if category:
                cur = await conn.execute(
                    f"SELECT {_COLUMNS} FROM catalog.products WHERE category = %s ORDER BY sku LIMIT %s OFFSET %s", (category, limit, offset)
                )
            else:
                cur = await conn.execute(f"SELECT {_COLUMNS} FROM catalog.products ORDER BY sku LIMIT %s OFFSET %s", (limit, offset))
            return [_row_to_product(r) for r in await cur.fetchall()]

    async def get(self, sku: str) -> Product | None:
        check_fault("db_error")
        async with self.pool.connection() as conn:
            cur = await conn.execute(f"SELECT {_COLUMNS} FROM catalog.products WHERE sku = %s", (sku,))
            row = await cur.fetchone()
            return _row_to_product(row) if row else None

    async def upsert(self, product: ProductIn) -> Product:
        check_fault("db_error")
        async with self.pool.connection() as conn:
            cur = await conn.execute(_UPSERT, product.model_dump())
            return _row_to_product(await cur.fetchone())

    async def upsert_many(self, products: list[ProductIn]) -> int:
        check_fault("db_error")
        async with self.pool.connection() as conn:
            async with conn.transaction():
                async with conn.cursor() as cur:
                    await cur.executemany(_UPSERT.split("RETURNING")[0], [p.model_dump() for p in products])
        return len(products)
