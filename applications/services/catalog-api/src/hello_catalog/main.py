"""hello-catalog-api HTTP surface.

GET  /products?limit=&offset=&category=  -> {"items": [Product], "count": n}
GET  /products/{sku}                       -> Product, header X-Cache: HIT|MISS|BYPASS
POST /products  (upsert by sku)            -> 200 Product (Idempotency-Key optional; upsert is idempotent)
POST /seed                                 -> {"seeded": 20} deterministic SKU-0001..SKU-0020
"""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Header, Query, Response

from hello_common.app import create_app
from hello_common.config import env_choice, service_info
from hello_common.idempotency import IdempotencyCache, IdempotencyConflict, InvalidIdempotencyKey, validate_key
from hello_common.problems import Problem
from hello_common.telemetry import meter

from . import settings as settings_mod
from .cache import CatalogCache
from .models import SKU_PATTERN, Product, ProductIn
from .repository import InMemoryRepository, PostgresRepository, ProductRepository
from .seed import seed_products

log = logging.getLogger("hello_catalog")
_cache_counter = meter("hello_catalog").create_counter("hello.catalog.cache.requests", unit="{request}", description="Catalog cache-aside lookups by result")


def build_app(settings: settings_mod.Settings | None = None, repo: ProductRepository | None = None, cache: CatalogCache | None = None) -> FastAPI:
    info = service_info("hello-catalog-api")
    settings = settings or settings_mod.load()
    if repo is None:
        storage = env_choice("CATALOG_STORAGE", "postgres", {"postgres", "memory"})
        repo = InMemoryRepository() if storage == "memory" else PostgresRepository(settings.pg, info.service)
    cache = cache or CatalogCache(settings.redis)
    state = {"migrated": False}
    idem = IdempotencyCache(ttl_seconds=3600, max_entries=5000)

    async def _migrate_with_retry() -> None:
        delay = 1.0
        while True:
            try:
                await repo.migrate()
                state["migrated"] = True
                if settings.seed_on_startup:
                    await repo.upsert_many(seed_products())
                log.info("catalog schema ready")
                return
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.warning(
                    "catalog migration failed; retrying", extra={"error.kind": type(exc).__name__, "error.message": str(exc)[:200], "retry_in_s": delay}
                )
                await asyncio.sleep(delay)
                delay = min(delay * 2, 30.0)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        await repo.open()
        task = None
        if settings.migrate_on_startup:
            task = asyncio.create_task(_migrate_with_retry())
        else:
            state["migrated"] = True
        try:
            yield
        finally:
            if task:
                task.cancel()
            await cache.close()
            await repo.close()

    async def check_db() -> dict:
        await repo.ping()
        if not state["migrated"]:
            raise RuntimeError("schema migration pending")
        return {"detail": "ok"}

    app = create_app(info, readiness={"postgresql": check_db, "redis": cache.ping}, lifespan=lifespan)
    app.state.repo = repo
    app.state.cache = cache

    @app.get("/products")
    async def list_products(limit: int = Query(50, ge=1, le=200), offset: int = Query(0, ge=0), category: str | None = Query(None, max_length=64)):
        items = await repo.list(limit, offset, category)
        return {"items": [p.model_dump(mode="json") for p in items], "count": len(items)}

    @app.get("/products/{sku}", response_model=Product)
    async def get_product(sku: str, response: Response):
        import re

        if not re.match(SKU_PATTERN, sku):
            raise Problem(400, detail="invalid sku format")
        result, cached = await cache.get(sku)
        _cache_counter.add(1, {"cache.result": result.lower()})
        response.headers["X-Cache"] = result
        if cached is not None:
            return cached
        product = await repo.get(sku)
        if product is None:
            raise Problem(404, detail=f"product {sku} not found")
        doc = product.model_dump(mode="json")
        if result == "MISS":
            await cache.set(sku, doc)
        return doc

    @app.post("/products", response_model=Product)
    async def upsert_product(product: ProductIn, idempotency_key: str | None = Header(default=None)):
        try:
            key = validate_key(idempotency_key)
            payload = product.model_dump(mode="json")
            if key and (stored := idem.lookup("products", key, payload)) is not None:
                return stored.body
        except InvalidIdempotencyKey as exc:
            raise Problem(400, detail=str(exc)) from exc
        except IdempotencyConflict as exc:
            raise Problem(422, detail=str(exc)) from exc
        saved = await repo.upsert(product)
        await cache.invalidate(product.sku)
        doc = saved.model_dump(mode="json")
        if key:
            idem.store("products", key, payload, 200, doc)
        log.info("product upserted", extra={"sku": product.sku})
        return doc

    @app.post("/seed")
    async def seed():
        products = seed_products()
        count = await repo.upsert_many(products)
        for p in products:
            await cache.invalidate(p.sku)
        log.info("catalog seeded", extra={"seeded": count})
        return {"seeded": count, "first": products[0].sku, "last": products[-1].sku}

    return app
