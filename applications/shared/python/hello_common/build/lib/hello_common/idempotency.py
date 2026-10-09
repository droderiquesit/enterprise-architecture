"""Idempotency-Key support for POST endpoints that create resources.

``IdempotencyCache`` remembers (key -> request fingerprint, response) for ``ttl_seconds`` with a
bounded size (LRU eviction). Replaying the same key with the same body returns the stored response
(``Idempotent-Replayed: true``); the same key with a *different* body is a 422 conflict. Services
whose storage is naturally idempotent (upsert by business key) additionally enforce it in the data
store; this cache only removes duplicate work for retried client calls within one instance.
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
import uuid
from collections import OrderedDict
from dataclasses import dataclass
from typing import Any

HEADER = "Idempotency-Key"
MAX_KEY_LENGTH = 200


class IdempotencyConflict(Exception):
    pass


class InvalidIdempotencyKey(ValueError):
    pass


def new_key() -> str:
    return str(uuid.uuid4())


def validate_key(key: str | None) -> str | None:
    if key is None:
        return None
    key = key.strip()
    if not key or len(key) > MAX_KEY_LENGTH or any(ord(c) < 0x21 or ord(c) > 0x7E for c in key):
        raise InvalidIdempotencyKey("Idempotency-Key must be 1-200 visible ASCII characters")
    return key


def fingerprint(payload: Any) -> str:
    return hashlib.sha256(json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest()


@dataclass
class StoredResponse:
    fingerprint: str
    status_code: int
    body: Any
    stored_at: float


class IdempotencyCache:
    def __init__(self, ttl_seconds: int = 86400, max_entries: int = 10000, clock=time.time) -> None:
        self.ttl = ttl_seconds
        self.max_entries = max_entries
        self._clock = clock
        self._items: OrderedDict[str, StoredResponse] = OrderedDict()
        self._lock = threading.Lock()

    def lookup(self, scope: str, key: str, payload: Any) -> StoredResponse | None:
        fp = fingerprint(payload)
        now = self._clock()
        with self._lock:
            item = self._items.get(f"{scope}:{key}")
            if item is None:
                return None
            if now - item.stored_at > self.ttl:
                del self._items[f"{scope}:{key}"]
                return None
            if item.fingerprint != fp:
                raise IdempotencyConflict("Idempotency-Key reused with a different request body")
            self._items.move_to_end(f"{scope}:{key}")
            return item

    def store(self, scope: str, key: str, payload: Any, status_code: int, body: Any) -> None:
        with self._lock:
            self._items[f"{scope}:{key}"] = StoredResponse(fingerprint(payload), status_code, body, self._clock())
            self._items.move_to_end(f"{scope}:{key}")
            while len(self._items) > self.max_entries:
                self._items.popitem(last=False)
