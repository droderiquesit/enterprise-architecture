"""hello-dbadapter HTTP surface (same API for every DB_FAMILY).

POST   /records {payload}        -> 201 record   (Idempotency-Key => deterministic id, retried POST upserts)
GET    /records/{id}             -> record | 404
GET    /records?limit=20         -> {"items": [...], "count": n}
PUT    /records/{id} {payload}   -> record | 404   (405 for append-only families, e.g. ledger)
DELETE /records/{id}             -> 204 | 404      (405 for append-only families)
POST   /roundtrip                -> {"family","ok","timings_ms":{write,read,update,delete},"cache"?,"error"?}
POST   /seed                     -> {"seeded": n}  deterministic ids (uuid5) so seeding is idempotent
GET    /info                     -> driver description (family, db_system, append_only, cache_semantics)

DB_FAMILY selects the driver (see hello_dbadapter.drivers.FAMILIES). DB_SERVICE_NAME overrides DD_SERVICE
(default hello-dbadapter-<family>). DB_OPEN_RETRY_MAX_SECONDS (default 30) bounds the startup backoff.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Any

from fastapi import Body, FastAPI, Header, Query
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field

from hello_common.app import create_app
from hello_common.config import service_info
from hello_common.idempotency import InvalidIdempotencyKey, validate_key
from hello_common.problems import Problem
from hello_common.telemetry import meter

from .drivers import FAMILIES, create_driver
from .drivers.base import Driver, NotSupported, key_id

log = logging.getLogger("hello_dbadapter")
_duration = meter("hello_dbadapter").create_histogram("hello.dbadapter.operation.duration", unit="ms", description="Adapter operation latency")


class RecordIn(BaseModel):
    payload: dict[str, Any] = Field(default_factory=dict)


def _family() -> str:
    family = (os.environ.get("DB_FAMILY") or "memory").strip().lower()
    if family not in FAMILIES:
        raise ValueError(f"DB_FAMILY={family!r} is not one of {sorted(FAMILIES)}")
    return family


def build_app(driver: Driver | None = None, family: str | None = None) -> FastAPI:
    family = family or (driver.family if driver else _family())
    os.environ.setdefault("DB_SERVICE_NAME", f"hello-dbadapter-{family}")
    info = service_info(f"hello-dbadapter-{family}", service_override_var="DB_SERVICE_NAME")
    state: dict[str, Any] = {"driver": driver, "opened": False, "error": None}

    async def _open_with_retry() -> None:
        delay, max_delay = 1.0, float(os.environ.get("DB_OPEN_RETRY_MAX_SECONDS", "30"))
        while True:
            try:
                await state["driver"].open()
                state["opened"], state["error"] = True, None
                log.info("driver ready", extra={"family": family})
                return
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                state["error"] = f"{type(exc).__name__}: {str(exc)[:200]}"
                log.warning("driver open failed; retrying", extra={"family": family, "error.kind": type(exc).__name__, "retry_in_s": delay})
                await asyncio.sleep(delay)
                delay = min(delay * 2, max_delay)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        if state["driver"] is None:
            state["driver"] = create_driver(family)
        task = None
        try:  # first attempt inline (fast, deterministic start); then bounded background retries
            await asyncio.wait_for(state["driver"].open(), timeout=20)
            state["opened"] = True
            log.info("driver ready", extra={"family": family})
        except Exception as exc:
            state["error"] = f"{type(exc).__name__}: {str(exc)[:200]}"
            log.warning("driver open failed; retrying in background", extra={"family": family, "error.kind": type(exc).__name__})
            task = asyncio.create_task(_open_with_retry())
        try:
            yield
        finally:
            if task:
                task.cancel()
            try:
                await state["driver"].close()
            except Exception as exc:  # pragma: no cover
                log.warning("driver close failed", extra={"error.kind": type(exc).__name__})

    async def ready() -> dict:
        if not state["opened"]:
            raise RuntimeError(state["error"] or "driver opening")
        await state["driver"].ping()
        return {"family": family}

    app = create_app(info, readiness={family: ready}, lifespan=lifespan)

    def drv() -> Driver:
        if not state["opened"]:
            raise Problem(503, "Driver not ready", state["error"] or "driver is still connecting")
        return state["driver"]

    async def timed(op: str, coro):
        started = time.perf_counter()
        outcome = "ok"
        try:
            return await coro
        except Exception:
            outcome = "error"
            raise
        finally:
            _duration.record((time.perf_counter() - started) * 1000, {"family": family, "operation": op, "outcome": outcome})

    @app.get("/info")
    async def info_doc():
        d = state["driver"]
        doc = d.describe() if d else {"family": family}
        doc.update(ready=state["opened"], service=info.service)
        return doc

    @app.post("/records", status_code=201)
    async def create_record(body: RecordIn, idempotency_key: str | None = Header(default=None)):
        try:
            key = validate_key(idempotency_key)
        except InvalidIdempotencyKey as exc:
            raise Problem(400, detail=str(exc)) from exc
        record_id = key_id(key) if key else None
        rec = await timed("create", drv().create(body.payload, record_id))
        return JSONResponse(rec.to_dict(), status_code=201)

    @app.get("/records")
    async def list_records(limit: int = Query(20, ge=1, le=200)):
        items = await timed("list", drv().list(limit))
        return {"items": [r.to_dict() for r in items], "count": len(items)}

    @app.get("/records/{record_id}")
    async def get_record(record_id: str):
        rec = await timed("read", drv().get(record_id))
        if rec is None:
            raise Problem(404, detail="record not found")
        return rec.to_dict()

    @app.put("/records/{record_id}")
    async def put_record(record_id: str, body: RecordIn):
        d = drv()
        if d.append_only:
            raise Problem(405, "Method Not Allowed", f"{family} is append-only")
        rec = await timed("update", d.update(record_id, body.payload))
        if rec is None:
            raise Problem(404, detail="record not found")
        return rec.to_dict()

    @app.delete("/records/{record_id}", status_code=204)
    async def delete_record(record_id: str):
        d = drv()
        if d.append_only:
            raise Problem(405, "Method Not Allowed", f"{family} is append-only")
        if not await timed("delete", d.delete(record_id)):
            raise Problem(404, detail="record not found")
        return Response(status_code=204)

    @app.post("/roundtrip")
    async def roundtrip(body: dict[str, Any] | None = Body(default=None)):
        d = drv()
        timings: dict[str, float] = {}
        result: dict[str, Any] = {"family": family, "ok": False, "timings_ms": timings}
        payload = {"kind": "roundtrip", "at": time.time(), **((body or {}).get("payload") or {})}

        async def step(name: str, coro):
            t = time.perf_counter()
            try:
                return await timed(name if name != "write" else "create", coro)
            finally:
                timings[name] = round((time.perf_counter() - t) * 1000, 2)

        try:
            rec = await step("write", d.create(payload))
            result["id"] = rec.id
            got = await step("read", d.get(rec.id))
            if got is None:
                raise RuntimeError("written record not readable")
            if d.cache_semantics:
                result["cache"] = getattr(d, "last_result", "hit")
            if d.append_only:
                result["update"] = result["delete"] = "not_supported (append-only)"
            else:
                updated = await step("update", d.update(rec.id, {**payload, "updated": True}))
                if updated is None and not d.cache_semantics:
                    raise RuntimeError("update did not find record")
                deleted = await step("delete", d.delete(rec.id))
                if not deleted and not d.cache_semantics:
                    raise RuntimeError("delete did not find record")
            result["ok"] = True
        except NotSupported as exc:
            result["error"] = str(exc)
        except Problem:
            raise
        except Exception as exc:
            from hello_common.faults import FaultInjectedError

            if isinstance(exc, FaultInjectedError):
                raise
            log.warning("roundtrip failed", extra={"family": family, "error.kind": type(exc).__name__})
            result["error"] = f"{type(exc).__name__}: {str(exc)[:200]}"
        status = 200 if result["ok"] else 502
        return JSONResponse(result, status_code=status)

    @app.post("/seed")
    async def seed(count: int = Query(10, ge=1, le=100)):
        n = await timed("seed", drv().seed(count))
        return {"family": family, "seeded": n}

    @app.exception_handler(NotSupported)
    async def _not_supported(request, exc):
        from hello_common.problems import problem_response

        return problem_response(405, "Method Not Allowed", str(exc), instance=request.url.path)

    return app
