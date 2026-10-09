"""Message sources shared by hello-worker and hello-jobs: Azure Service Bus (async PEEK_LOCK receiver +
AutoLockRenewer, managed identity or emulator connection string) and an in-memory queue for tests.
azure-servicebus is imported lazily (only services that consume messages depend on it)."""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from typing import Any, Protocol

from hello_common.propagation import normalize_properties

log = logging.getLogger("hello_common.messaging")


@dataclass
class Envelope:
    message_id: str
    body: bytes
    application_properties: dict[str, str]
    attempt: int  # 1-based delivery attempt
    enqueued_time: str | None = None
    raw: Any = None


class MessageSource(Protocol):
    async def open(self) -> None: ...
    async def receive(self, max_count: int, max_wait: float) -> list[Envelope]: ...
    async def complete(self, env: Envelope) -> None: ...
    async def abandon(self, env: Envelope) -> None: ...
    async def dead_letter(self, env: Envelope, reason: str, description: str) -> None: ...
    async def close(self) -> None: ...
    def healthy(self) -> bool: ...


@dataclass
class MemorySource:
    queue: asyncio.Queue = field(default_factory=asyncio.Queue)
    completed: list[Envelope] = field(default_factory=list)
    dead_lettered: list[tuple[Envelope, str, str]] = field(default_factory=list)
    abandoned: int = 0

    async def open(self) -> None:
        return None

    def put(self, body: bytes, properties: dict[str, str] | None = None, message_id: str | None = None) -> None:
        import uuid

        self.queue.put_nowait(Envelope(message_id or str(uuid.uuid4()), body, dict(properties or {}), 1))

    async def receive(self, max_count: int, max_wait: float) -> list[Envelope]:
        out: list[Envelope] = []
        try:
            out.append(await asyncio.wait_for(self.queue.get(), timeout=max_wait))
        except TimeoutError:
            return out
        while len(out) < max_count and not self.queue.empty():
            out.append(self.queue.get_nowait())
        return out

    async def complete(self, env: Envelope) -> None:
        self.completed.append(env)

    async def abandon(self, env: Envelope) -> None:
        self.abandoned += 1
        env.attempt += 1
        self.queue.put_nowait(env)

    async def dead_letter(self, env: Envelope, reason: str, description: str) -> None:
        self.dead_lettered.append((env, reason, description))

    async def close(self) -> None:
        return None

    def healthy(self) -> bool:
        return True


class ServiceBusSource:
    """azure-servicebus async receiver in PEEK_LOCK mode with AutoLockRenewer for long handlers."""

    def __init__(self, settings: Any = None, *, fqdn: str | None = None, connection_string: str | None = None, topic: str | None = None,
                 subscription: str | None = None, queue: str | None = None, prefetch: int = 20, lock_renew_max: int = 300) -> None:
        if settings is None:
            from types import SimpleNamespace

            settings = SimpleNamespace(sb_fqdn=fqdn, sb_connection_string=connection_string, topic=topic, subscription=subscription,
                                       queue=queue, prefetch=prefetch, lock_renew_max=lock_renew_max)
        self.s = settings
        self._client = None
        self._receiver = None
        self._renewer = None
        self._healthy = False

    async def open(self) -> None:
        from azure.servicebus import ServiceBusReceiveMode
        from azure.servicebus.aio import AutoLockRenewer, ServiceBusClient

        if self.s.sb_connection_string:
            self._client = ServiceBusClient.from_connection_string(self.s.sb_connection_string, retry_total=3)
        else:
            if not self.s.sb_fqdn:
                raise ValueError("SERVICEBUS_FQDN or SERVICEBUS_CONNECTION_STRING is required in servicebus mode")
            from hello_common.azure_auth import get_credential

            self._client = ServiceBusClient(self.s.sb_fqdn, credential=get_credential(async_=True), retry_total=3)
        common = dict(receive_mode=ServiceBusReceiveMode.PEEK_LOCK, prefetch_count=self.s.prefetch)
        if self.s.queue:
            self._receiver = self._client.get_queue_receiver(self.s.queue, **common)
        else:
            self._receiver = self._client.get_subscription_receiver(self.s.topic, self.s.subscription, **common)
        await self._receiver.__aenter__()
        self._renewer = AutoLockRenewer(max_lock_renewal_duration=self.s.lock_renew_max)
        self._healthy = True

    async def receive(self, max_count: int, max_wait: float) -> list[Envelope]:
        try:
            messages = await self._receiver.receive_messages(max_message_count=max_count, max_wait_time=max_wait)
            self._healthy = True
        except Exception:
            self._healthy = False
            raise
        out = []
        for m in messages:
            self._renewer.register(self._receiver, m, max_lock_renewal_duration=self.s.lock_renew_max)
            body = b"".join(m.body) if not isinstance(m.body, (bytes, bytearray)) else bytes(m.body)
            out.append(Envelope(
                message_id=str(m.message_id), body=body, application_properties=normalize_properties(m.application_properties),
                attempt=(m.delivery_count or 0) + 1, enqueued_time=m.enqueued_time_utc.isoformat() if m.enqueued_time_utc else None, raw=m,
            ))
        return out

    async def complete(self, env: Envelope) -> None:
        await self._receiver.complete_message(env.raw)

    async def abandon(self, env: Envelope) -> None:
        await self._receiver.abandon_message(env.raw)

    async def dead_letter(self, env: Envelope, reason: str, description: str) -> None:
        await self._receiver.dead_letter_message(env.raw, reason=reason, error_description=description[:1024])

    async def close(self) -> None:
        self._healthy = False
        for closer in (self._renewer, self._receiver, self._client):
            if closer is not None:
                try:
                    await closer.close()
                except Exception as exc:  # pragma: no cover
                    log.warning("close failed", extra={"error.kind": type(exc).__name__})

    def healthy(self) -> bool:
        return self._healthy
