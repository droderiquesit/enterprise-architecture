"""Simulated payment API.

POST /payments {order_id, amount}  -> 201 {payment_id, order_id, amount, currency, status: approved|declined, created_at}
                                     idempotent by order_id: a replay returns the original payment (200,
                                     header Idempotent-Replayed: true); a replay with a different amount -> 409.
GET  /payments/{payment_id}        -> payment | 404

Environment (lab knobs):
  LATENCY_MS_MEAN (150), LATENCY_MS_JITTER (50)  simulated provider latency (normal, clipped at 0)
  PARTNER_FAILURE_RATE (0.0)   probability of a transient 503 (not recorded -> a retry can succeed)
  PARTNER_DECLINE_RATE (0.0)   probability of a business decline (recorded -> idempotent)
  PARTNER_DECLINE_ABOVE (10000) amounts above this are always declined
  PARTNER_MAX_PAYMENTS (100000) bounded in-memory store (oldest evicted)
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import random
import threading
import uuid
from collections import OrderedDict
from datetime import UTC, datetime
from decimal import Decimal

from fastapi import FastAPI, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from hello_common.app import create_app
from hello_common.config import env_float, env_int, service_info
from hello_common.problems import Problem
from hello_common.telemetry import meter

log = logging.getLogger("hello_partner_sim")
_payments = meter("hello_partner_sim").create_counter("hello.partner.payments", unit="{payment}", description="Payments by status")


class PaymentIn(BaseModel):
    order_id: str = Field(min_length=1, max_length=128)
    amount: Decimal = Field(gt=0, le=Decimal("1000000"), decimal_places=2)
    currency: str = Field("USD", pattern=r"^[A-Z]{3}$")


class Store:
    def __init__(self, max_items: int) -> None:
        self.by_order: OrderedDict[str, dict] = OrderedDict()
        self.by_id: dict[str, dict] = {}
        self.max_items = max_items
        self.lock = threading.Lock()

    def get_order(self, order_id: str) -> dict | None:
        with self.lock:
            return self.by_order.get(order_id)

    def put(self, payment: dict) -> dict:
        with self.lock:
            existing = self.by_order.get(payment["order_id"])
            if existing:
                return existing
            self.by_order[payment["order_id"]] = payment
            self.by_id[payment["payment_id"]] = payment
            while len(self.by_order) > self.max_items:
                _, old = self.by_order.popitem(last=False)
                self.by_id.pop(old["payment_id"], None)
            return payment


def build_app(rng: random.Random | None = None) -> FastAPI:
    info = service_info("hello-partner-sim")
    rng = rng or random.Random()
    latency_mean = env_float("LATENCY_MS_MEAN", 150.0, minimum=0, maximum=30000)
    latency_jitter = env_float("LATENCY_MS_JITTER", 50.0, minimum=0, maximum=30000)
    failure_rate = env_float("PARTNER_FAILURE_RATE", 0.0, minimum=0, maximum=1)
    decline_rate = env_float("PARTNER_DECLINE_RATE", 0.0, minimum=0, maximum=1)
    decline_above = Decimal(str(env_float("PARTNER_DECLINE_ABOVE", 10000.0, minimum=0)))
    store = Store(env_int("PARTNER_MAX_PAYMENTS", 100000, minimum=10))
    app = create_app(info, readiness={"store": lambda: {"payments": len(store.by_id)}})
    app.state.store = store

    @app.post("/payments", status_code=201)
    async def create_payment(body: PaymentIn, response: Response):
        existing = store.get_order(body.order_id)
        if existing:
            if Decimal(str(existing["amount"])) != body.amount:
                raise Problem(409, detail="order already paid with a different amount")
            return JSONResponse(existing, status_code=200, headers={"Idempotent-Replayed": "true"})
        delay = max(0.0, rng.gauss(latency_mean, latency_jitter)) / 1000.0
        await asyncio.sleep(delay)
        if rng.random() < failure_rate:
            _payments.add(1, {"status": "unavailable"})
            raise Problem(503, "Partner Unavailable", "simulated transient partner failure; retry later")
        declined = body.amount > decline_above or rng.random() < decline_rate
        payment = {
            # deterministic id per order: retries racing each other converge on the same payment
            "payment_id": "pay_" + hashlib.sha256(body.order_id.encode()).hexdigest()[:24],
            "order_id": body.order_id,
            "amount": float(body.amount),
            "currency": body.currency,
            "status": "declined" if declined else "approved",
            "created_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
            "reference": str(uuid.uuid4()),
        }
        stored = store.put(payment)
        _payments.add(1, {"status": stored["status"]})
        log.info("payment processed", extra={"order_id": body.order_id, "status": stored["status"], "simulated_latency_ms": round(delay * 1000, 1)})
        return stored

    @app.get("/payments/{payment_id}")
    async def get_payment(payment_id: str):
        payment = store.by_id.get(payment_id)
        if payment is None:
            raise Problem(404, detail="payment not found")
        return payment

    return app
