"""Common driver interface. Every family implements the same async CRUD contract on a single
logical "records" collection: {id, payload (JSON object), created_at, updated_at}.

Drivers must:
* use bounded timeouts and pooled clients from the family's official SDK,
* call ``check_fault("db_error")`` before each data operation (fault-injection hook),
* create their schema/collection idempotently in ``open()`` when the identity is allowed to,
* never log payloads or credentials.
"""

from __future__ import annotations

import asyncio
import json
import uuid
from abc import ABC, abstractmethod
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any, TypeVar

from opentelemetry import trace
from opentelemetry.trace import SpanKind

from hello_common.faults import check_fault

T = TypeVar("T")
SEED_NAMESPACE = uuid.UUID("6f0d7c1e-3c55-4f1f-9a50-6a1f0e8b2c11")
_tracer = trace.get_tracer("hello_dbadapter")


class NotSupported(Exception):
    """Operation not supported by this family (e.g. update/delete on append-only ledger)."""


class RecordNotFound(Exception):
    pass


def utcnow() -> datetime:
    return datetime.now(UTC)


def iso(dt: datetime | str | None) -> str | None:
    if dt is None:
        return None
    if isinstance(dt, str):
        return dt
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC).isoformat().replace("+00:00", "Z")


def dumps(payload: dict[str, Any]) -> str:
    return json.dumps(payload, separators=(",", ":"), sort_keys=True, default=str)


def loads(raw: str | bytes | dict | None) -> dict[str, Any]:
    if raw is None:
        return {}
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode()
    value = json.loads(raw)
    return value if isinstance(value, dict) else {"value": value}


def new_id() -> str:
    return str(uuid.uuid4())


def seed_id(index: int) -> str:
    return str(uuid.uuid5(SEED_NAMESPACE, f"seed-{index}"))


def key_id(idempotency_key: str) -> str:
    """Deterministic record id from an Idempotency-Key: retried POSTs upsert the same record."""
    return str(uuid.uuid5(SEED_NAMESPACE, f"idem-{idempotency_key}"))


@dataclass
class Record:
    id: str
    payload: dict[str, Any]
    created_at: str | None = None
    updated_at: str | None = None
    extra: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        doc = {"id": self.id, "payload": self.payload, "created_at": self.created_at, "updated_at": self.updated_at}
        doc.update(self.extra)
        return doc


class Driver(ABC):
    family: str = "base"
    db_system: str = "other_sql"
    append_only: bool = False
    cache_semantics: bool = False
    # (name, purpose) of env vars, surfaced by GET /config for operators
    env_vars: tuple[str, ...] = ()

    async def open(self) -> None:  # noqa: B027 - optional hook
        """Connect and create schema idempotently."""

    async def close(self) -> None:  # noqa: B027
        """Release pooled resources."""

    @abstractmethod
    async def ping(self) -> None: ...

    @abstractmethod
    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        """Insert (or overwrite when record_id already exists - upsert)."""

    @abstractmethod
    async def get(self, record_id: str) -> Record | None: ...

    @abstractmethod
    async def list(self, limit: int) -> list[Record]: ...

    @abstractmethod
    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None: ...

    @abstractmethod
    async def delete(self, record_id: str) -> bool: ...

    async def seed(self, count: int) -> int:
        for i in range(1, count + 1):
            await self.create({"seed": i, "name": f"record-{i:03d}", "family": self.family}, seed_id(i))
        return count

    # helpers ---------------------------------------------------------------------------------
    def fault_hook(self) -> None:
        check_fault("db_error")

    async def in_thread(self, fn: Callable[..., T], *args: Any, **kwargs: Any) -> T:
        """Run a blocking SDK call off the event loop (sync-only SDKs), keeping the OTel context."""
        from opentelemetry import context as otel_context

        ctx = otel_context.get_current()

        def _run() -> T:
            token = otel_context.attach(ctx)
            try:
                return fn(*args, **kwargs)
            finally:
                otel_context.detach(token)

        return await asyncio.to_thread(_run)

    def client_span(self, operation: str, **attributes: Any):
        """CLIENT span for SDKs without OpenTelemetry instrumentation."""
        attrs = {"db.system": self.db_system, "db.system.name": self.db_system, "db.operation.name": operation, "family": self.family}
        attrs.update({k: v for k, v in attributes.items() if v is not None})
        return _tracer.start_as_current_span(f"{operation} {self.family}", kind=SpanKind.CLIENT, attributes=attrs)

    def describe(self) -> dict[str, Any]:
        return {"family": self.family, "db_system": self.db_system, "append_only": self.append_only, "cache_semantics": self.cache_semantics}
