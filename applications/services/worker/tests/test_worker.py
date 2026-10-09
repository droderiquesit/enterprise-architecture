import asyncio
import json
import os
import signal
import subprocess
import sys
import time

import httpx
import pytest

from hello_worker.sinks import MemorySink
from hello_worker.sources import MemorySource
from hello_worker.worker import Worker, parse_event, PoisonMessage

TP = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"


def event(order_id="11111111-1111-1111-1111-111111111111", **kw):
    return json.dumps({"event": "OrderCreated", "order_id": order_id, "sku": "SKU-0001", "quantity": 2, "amount": 24.7,
                       "created_at": "2026-10-09T12:00:00Z", **kw}).encode()


def make(source=None, sink=None, **kw):
    return Worker(source or MemorySource(), sink or MemorySink(), entity="order-events/subscriptions/notifications",
                  receive_wait=0.05, **{"retry_delay_base": 0.01, **kw})


async def run_until_empty(w, source, timeout=5.0):
    task = asyncio.create_task(w.run())
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        await asyncio.sleep(0.05)
        if source.queue.empty() and not w._inflight:
            break
    w.stop()
    await task


async def test_success_link_not_parent_and_idempotent_upsert(spans):
    src, sink = MemorySource(), MemorySink()
    src.put(event(), {"traceparent": TP, "tracestate": "dd=s:1"}, message_id="m1")
    src.put(event(), {"traceparent": TP}, message_id="m1-dup")  # duplicate delivery of the same order
    w = make(src, sink)
    await run_until_empty(w, src)
    assert len(src.completed) == 2 and sink.writes == 2 and len(sink.rows) == 1
    row = sink.rows["11111111-1111-1111-1111-111111111111"]
    assert row["PartitionKey"] == "order" and row["status"] == "Notified" and row["producer_trace_id"] == "4bf92f3577b34da6a3ce929d0e0e4736"
    consumer = [s for s in spans() if s.name == "servicebus.process"]
    assert len(consumer) == 2
    for s in consumer:
        assert s.kind.name == "CONSUMER" and s.parent is None
        assert s.context.trace_id != int("4bf92f3577b34da6a3ce929d0e0e4736", 16)
        assert s.links and s.links[0].context.trace_id == int("4bf92f3577b34da6a3ce929d0e0e4736", 16)
        assert s.attributes["messaging.destination.name"] == "order-events/subscriptions/notifications"


async def test_poison_is_dead_lettered_immediately():
    src = MemorySource()
    src.put(b"not-json", message_id="bad1")
    src.put(json.dumps({"event": "OrderCreated"}).encode(), message_id="bad2")
    w = make(src)
    await run_until_empty(w, src)
    assert [r for _, r, _ in src.dead_lettered] == ["PoisonMessage", "PoisonMessage"]
    assert src.abandoned == 0
    with pytest.raises(PoisonMessage):
        parse_event(b"[1,2]")


async def test_transient_failures_abandon_then_dead_letter_after_max_attempts():
    class Flaky(MemorySink):
        async def upsert(self, order_id, entity):
            raise ConnectionError("table unavailable")

    src = MemorySource()
    src.put(event(), message_id="m-fail")
    w = make(src, Flaky(), max_attempts=3)
    await run_until_empty(w, src)
    assert src.abandoned == 2
    assert len(src.dead_lettered) == 1 and src.dead_lettered[0][1] == "MaxDeliveryAttemptsExceeded"
    assert src.dead_lettered[0][0].attempt == 3


async def test_db_error_fault_is_retried():
    from hello_common.faults import REGISTRY

    src, sink = MemorySource(), MemorySink()
    REGISTRY.add("db_error", 1.0, 1)
    src.put(event(), message_id="m-fault")
    w = make(src, sink, max_attempts=50, retry_delay_base=0.1, retry_delay_max=0.4)
    task = asyncio.create_task(w.run())
    await asyncio.sleep(1.3)  # fault expires after 1s, then the retry succeeds
    for _ in range(40):
        if src.completed:
            break
        await asyncio.sleep(0.05)
    w.stop()
    await task
    assert src.abandoned >= 1 and len(src.completed) == 1


async def test_bounded_concurrency():
    active = {"now": 0, "max": 0}

    class Slow(MemorySink):
        async def upsert(self, order_id, entity):
            active["now"] += 1
            active["max"] = max(active["max"], active["now"])
            await asyncio.sleep(0.05)
            active["now"] -= 1
            await super().upsert(order_id, entity)

    src, sink = MemorySource(), Slow()
    for i in range(30):
        src.put(event(order_id=f"order-{i}"))
    w = make(src, sink, max_concurrency=4)
    await run_until_empty(w, src)
    assert len(sink.rows) == 30 and active["max"] <= 4 and active["max"] >= 2


def test_process_health_and_graceful_sigterm(tmp_path):
    env = {**os.environ, "MESSAGING_MODE": "memory", "TABLE_MODE": "memory", "PORT": "18381", "LOG_FILE_PATH": str(tmp_path / "worker.log"),
           "RECEIVE_WAIT_SECONDS": "1"}
    proc = subprocess.Popen([sys.executable, "-m", "hello_worker"], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        ok = False
        for _ in range(60):
            try:
                if httpx.get("http://127.0.0.1:18381/readyz", timeout=1).status_code == 200:
                    ok = True
                    break
            except httpx.HTTPError:
                pass
            time.sleep(0.25)
        assert ok, "worker never became ready"
        assert httpx.get("http://127.0.0.1:18381/version").json()["service"] == "hello-worker"
        proc.send_signal(signal.SIGTERM)
        out, _ = proc.communicate(timeout=20)
    finally:
        if proc.poll() is None:
            proc.kill()
    assert proc.returncode == 0
    assert '"message":"worker stopped"' in out
    lines = (tmp_path / "worker.log").read_text().splitlines()
    assert any(json.loads(line)["message"] == "worker stopped" for line in lines)
