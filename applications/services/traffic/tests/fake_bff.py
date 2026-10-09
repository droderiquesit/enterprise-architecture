"""A tiny stand-in for hello-bff used by traffic tests (orders progress Pending -> Reserved -> Fulfilled)."""

import uuid

from fastapi import FastAPI, Header, Request
from fastapi.middleware.cors import CORSMiddleware


def build(fail_sku: str | None = None) -> FastAPI:
    app = FastAPI()
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"], expose_headers=["traceparent"])
    orders: dict[str, dict] = {}
    seen_keys: dict[str, str] = {}
    app.state.requests = []

    @app.middleware("http")
    async def record(request: Request, call_next):
        app.state.requests.append({"method": request.method, "path": request.url.path, "headers": dict(request.headers)})
        return await call_next(request)

    @app.get("/api/catalog/products")
    async def products():
        return {"items": [{"sku": f"SKU-{i:04d}", "name": f"Widget {i}", "unit_price": 10.0 + i, "price": 10.0 + i} for i in range(1, 4)], "count": 3}

    @app.get("/api/catalog/products/{sku}")
    async def product(sku: str):
        return {"sku": sku, "name": "Widget", "unit_price": 11.0, "price": 11.0}

    @app.get("/api/version")
    async def version():
        return {"service": "fake-bff", "version": "0.0.1"}

    @app.post("/api/orders", status_code=202)
    async def create(body: dict, idempotency_key: str | None = Header(default=None)):
        if idempotency_key in seen_keys:
            return {"order": orders[seen_keys[idempotency_key]]}
        oid = str(uuid.uuid4())
        orders[oid] = {"id": oid, "sku": body["sku"], "quantity": body["quantity"], "status": "Pending", "polls": 0}
        if idempotency_key:
            seen_keys[idempotency_key] = oid
        return {"order": orders[oid]}

    @app.get("/api/orders/{oid}")
    async def get(oid: str):
        o = orders[oid]
        o["polls"] += 1
        terminal = "Failed" if o["sku"] == fail_sku else "Fulfilled"
        o["status"] = ["Pending", "Reserved", terminal][min(o["polls"], 2)]
        return o

    @app.get("/api/adapters")
    async def adapters():
        return [{"family": "memory", "roundtrip_path": "/api/adapters/memory/roundtrip"}]

    @app.post("/api/adapters/{family}/roundtrip")
    async def roundtrip(family: str):
        return {"family": family, "ok": True, "timings_ms": {"write": 1.0}}

    return app
