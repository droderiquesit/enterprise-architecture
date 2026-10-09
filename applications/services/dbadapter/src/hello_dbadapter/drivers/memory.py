"""In-memory driver (tests / local demos). No configuration."""

from __future__ import annotations

from typing import Any

from .base import Driver, Record, iso, utcnow


class MemoryDriver(Driver):
    db_system = "memory"

    def __init__(self, family: str = "memory") -> None:
        self.family = family
        self._items: dict[str, Record] = {}

    async def ping(self) -> None:
        self.fault_hook()

    async def create(self, payload: dict[str, Any], record_id: str | None = None) -> Record:
        from .base import new_id

        self.fault_hook()
        rid = record_id or new_id()
        now = iso(utcnow())
        existing = self._items.get(rid)
        rec = Record(rid, dict(payload), existing.created_at if existing else now, now)
        self._items[rid] = rec
        return rec

    async def get(self, record_id: str) -> Record | None:
        self.fault_hook()
        return self._items.get(record_id)

    async def list(self, limit: int) -> list[Record]:
        self.fault_hook()
        return sorted(self._items.values(), key=lambda r: r.created_at or "", reverse=True)[:limit]

    async def update(self, record_id: str, payload: dict[str, Any]) -> Record | None:
        self.fault_hook()
        rec = self._items.get(record_id)
        if rec is None:
            return None
        rec.payload = dict(payload)
        rec.updated_at = iso(utcnow())
        return rec

    async def delete(self, record_id: str) -> bool:
        self.fault_hook()
        return self._items.pop(record_id, None) is not None
