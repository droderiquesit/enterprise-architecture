"""Consumer runtime: bounded concurrency, span per message linked (not parented) to the producer,
dead-lettering of poison messages and of messages that exhaust MAX_DELIVERY_ATTEMPTS, graceful drain."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from datetime import UTC, datetime
from typing import Any

from opentelemetry import trace
from opentelemetry.context import Context
from opentelemetry.trace import SpanKind, Status, StatusCode

from hello_common.propagation import links_from_properties, producer_context
from hello_common.telemetry import meter

from .sinks import NotificationSink
from .sources import Envelope, MessageSource

log = logging.getLogger("hello_worker")
tracer = trace.get_tracer("hello_worker")
_m = meter("hello_worker")
_processed = _m.create_counter("hello.worker.messages", unit="{message}", description="Messages settled by outcome")
_duration = _m.create_histogram("hello.worker.process.duration", unit="ms", description="Per-message processing time")


class PoisonMessage(ValueError):
    """Message can never succeed (bad JSON / missing fields) -> dead-letter immediately."""


def parse_event(body: bytes) -> dict[str, Any]:
    try:
        event = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise PoisonMessage(f"body is not valid JSON: {exc}") from exc
    if not isinstance(event, dict):
        raise PoisonMessage("body is not a JSON object")
    order_id = event.get("order_id")
    if not order_id or not isinstance(order_id, str) or len(order_id) > 128:
        raise PoisonMessage("order_id missing or invalid")
    return event


def notification_entity(event: dict[str, Any], env: Envelope) -> dict[str, Any]:
    producer = producer_context(env.application_properties)
    return {
        "event": str(event.get("event", "OrderCreated")),
        "sku": str(event.get("sku", "")),
        "quantity": int(event.get("quantity") or 0),
        "amount": float(event.get("amount") or 0.0),
        "order_created_at": str(event.get("created_at", "")),
        "channel": "email-simulated",
        "status": "Notified",
        "message_id": env.message_id,
        "producer_trace_id": format(producer.trace_id, "032x") if producer else "",
        "notified_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
    }


class Worker:
    def __init__(
        self,
        source: MessageSource,
        sink: NotificationSink,
        *,
        entity: str,
        max_concurrency: int = 8,
        receive_batch: int = 10,
        receive_wait: float = 5.0,
        max_attempts: int = 5,
        processing_timeout: float = 30.0,
        shutdown_grace: float = 25.0,
        retry_delay_base: float = 0.5,
        retry_delay_max: float = 10.0,
    ) -> None:
        self.source, self.sink, self.entity = source, sink, entity
        self.max_concurrency = max_concurrency
        self.receive_batch, self.receive_wait = receive_batch, receive_wait
        self.max_attempts, self.processing_timeout, self.shutdown_grace = max_attempts, processing_timeout, shutdown_grace
        self.retry_delay_base, self.retry_delay_max = retry_delay_base, retry_delay_max
        self._sem = asyncio.Semaphore(max_concurrency)
        self._inflight: set[asyncio.Task] = set()
        self._stop = asyncio.Event()
        self.last_loop = time.monotonic()
        self.stats = {"completed": 0, "dead_lettered": 0, "abandoned": 0}

    def stop(self) -> None:
        self._stop.set()

    @property
    def stopping(self) -> bool:
        return self._stop.is_set()

    async def handle(self, env: Envelope) -> str:
        """Process one message inside a CONSUMER span linked to the producer. Returns the outcome."""
        attributes = {
            "messaging.system": "servicebus",
            "messaging.operation.type": "process",
            "messaging.destination.name": self.entity,
            "messaging.message.id": env.message_id,
            "messaging.servicebus.message.delivery_count": env.attempt,
        }
        started = time.perf_counter()
        outcome = "completed"
        # New root trace (empty Context) + link: an async hand-off is not a parent/child relationship.
        with tracer.start_as_current_span(
            "servicebus.process", context=Context(), kind=SpanKind.CONSUMER, links=links_from_properties(env.application_properties), attributes=attributes
        ) as span:
            try:
                event = parse_event(env.body)
                span.set_attribute("app.event", str(event.get("event", "")))
                await asyncio.wait_for(self.sink.upsert(event["order_id"], notification_entity(event, env)), timeout=self.processing_timeout)
                await self.source.complete(env)
                log.info("notification recorded", extra={"order_id": event["order_id"], "messaging.message.id": env.message_id, "attempt": env.attempt})
            except PoisonMessage as exc:
                outcome = "dead_lettered"
                span.set_status(Status(StatusCode.ERROR, "poison message"))
                await self.source.dead_letter(env, "PoisonMessage", str(exc))
                log.error("poison message dead-lettered", extra={"messaging.message.id": env.message_id, "error.message": str(exc)})
            except Exception as exc:
                span.record_exception(exc)
                span.set_status(Status(StatusCode.ERROR, type(exc).__name__))
                if env.attempt >= self.max_attempts:
                    outcome = "dead_lettered"
                    await self.source.dead_letter(env, "MaxDeliveryAttemptsExceeded", f"{type(exc).__name__}: {exc}")
                    log.error(
                        "message dead-lettered after max attempts",
                        extra={"messaging.message.id": env.message_id, "attempt": env.attempt, "error.kind": type(exc).__name__},
                    )
                else:
                    outcome = "abandoned"
                    # bounded exponential pause (lock kept alive by AutoLockRenewer) before releasing the message
                    await asyncio.sleep(min(self.retry_delay_base * 2 ** (env.attempt - 1), self.retry_delay_max))
                    await self.source.abandon(env)
                    log.warning(
                        "processing failed; message abandoned for retry",
                        extra={"messaging.message.id": env.message_id, "attempt": env.attempt, "error.kind": type(exc).__name__},
                    )
            span.set_attribute("app.outcome", outcome)
        self.stats[outcome] += 1
        _processed.add(1, {"outcome": outcome, "messaging.destination.name": self.entity})
        _duration.record((time.perf_counter() - started) * 1000, {"outcome": outcome})
        return outcome

    async def _run_one(self, env: Envelope) -> None:
        try:
            await self.handle(env)
        except Exception as exc:  # settlement failure (lock lost etc.) - broker will redeliver
            log.warning("settlement failed", extra={"messaging.message.id": env.message_id, "error.kind": type(exc).__name__})
        finally:
            self._sem.release()

    async def run(self) -> None:
        backoff = 1.0
        while not self._stop.is_set():
            self.last_loop = time.monotonic()
            free = self.max_concurrency - len(self._inflight)
            if free <= 0:
                await asyncio.wait(self._inflight, return_when=asyncio.FIRST_COMPLETED)
                continue
            try:
                batch = await self.source.receive(min(self.receive_batch, free), self.receive_wait)
                backoff = 1.0
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.warning("receive failed; backing off", extra={"error.kind": type(exc).__name__, "retry_in_s": backoff})
                try:
                    await asyncio.wait_for(self._stop.wait(), timeout=backoff)
                except TimeoutError:
                    pass
                backoff = min(backoff * 2, 30.0)
                continue
            for env in batch:
                await self._sem.acquire()
                task = asyncio.create_task(self._run_one(env))
                self._inflight.add(task)
                task.add_done_callback(self._inflight.discard)
        await self.drain()

    async def drain(self) -> None:
        if self._inflight:
            log.info("draining in-flight messages", extra={"inflight": len(self._inflight)})
            await asyncio.wait(self._inflight, timeout=self.shutdown_grace)
