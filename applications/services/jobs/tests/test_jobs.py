import json
import os
import subprocess
import sys
from datetime import date

import httpx
import pytest

from hello_common.http import create_client
from hello_common.messaging import MemorySource
from hello_jobs import commands


def factory(handler):
    calls = []

    def _handler(request):
        calls.append(request)
        return handler(request)

    def make(**kw):
        return create_client(inner_transport=httpx.MockTransport(_handler), backoff_base=0.001, **kw)

    make.calls = calls
    return make


def test_seed_calls_all_targets_with_idempotency_keys():
    f = factory(lambda r: httpx.Response(200, json={"seeded": 20}))
    env = {"CATALOG_API_URL": "http://catalog", "INVENTORY_API_URL": "http://inv/", "ADAPTERS_JSON": json.dumps([{"family": "mysql", "url": "http://a"}])}
    out = commands.seed(env, f)
    assert out["ok"] and set(out["targets"]) == {"catalog", "inventory", "adapter:mysql"}
    assert [str(c.url) for c in f.calls] == ["http://catalog/seed", "http://inv/inventory/seed", "http://a/seed"]
    assert all(c.headers["idempotency-key"].startswith("seed-") for c in f.calls)


def test_seed_required_failure_raises_but_adapter_failure_tolerated():
    f = factory(lambda r: httpx.Response(500) if r.url.host == "catalog" else httpx.Response(200))
    with pytest.raises(commands.JobFailed):
        commands.seed({"CATALOG_API_URL": "http://catalog"}, f)
    f2 = factory(lambda r: httpx.Response(503) if r.url.host == "a" else httpx.Response(200))
    out = commands.seed({"CATALOG_API_URL": "http://catalog", "ADAPTERS_JSON": json.dumps([{"family": "redis", "url": "http://a"}])}, f2)
    assert out["ok"] and out["targets"]["adapter:redis"]["status"] == "error"
    with pytest.raises(commands.JobFailed):
        commands.seed({}, f)


def test_reconcile_trigger_sends_function_key_header():
    f = factory(lambda r: httpx.Response(202, json={"id": "reconcile-123"}))
    out = commands.reconcile_trigger({"DURABLE_API_URL": "https://durable.example", "DURABLE_FUNCTION_KEY": "k"}, f)
    assert out == {"command": "reconcile-trigger", "status": 202, "instance_id": "reconcile-123"}
    assert f.calls[0].headers["x-functions-key"] == "k" and f.calls[0].url.path == "/api/workflows/reconciliation"
    with pytest.raises(commands.JobFailed):
        commands.reconcile_trigger({}, f)


def test_daily_aggregate(tmp_path):
    orders = [
        {"id": "1", "sku": "SKU-0001", "quantity": 2, "amount": 24.7, "status": "Fulfilled", "created_at": "2026-10-08T10:00:00Z"},
        {"id": "2", "sku": "SKU-0001", "quantity": 1, "amount": 12.35, "status": "Failed", "created_at": "2026-10-08T23:59:59Z"},
        {"id": "3", "sku": "SKU-0002", "quantity": 1, "amount": 19.7, "status": "Fulfilled", "created_at": "2026-10-09T00:00:00Z"},
    ]
    f = factory(lambda r: httpx.Response(200, json={"items": orders}))
    uploaded = []
    out = commands.daily_aggregate(
        {
            "ORDERS_API_URL": "http://orders",
            "AGGREGATE_DATE": "2026-10-08",
            "OUTPUT_PATH": str(tmp_path),
            "AGGREGATE_BLOB_ACCOUNT_URL": "https://acct.blob.core.windows.net",
        },
        f,
        upload=lambda *a: uploaded.append(a) or "https://acct/aggregates/x",
    )
    assert out["orders"] == 2 and out["uploaded"]
    doc = json.loads((tmp_path / "daily-aggregate-2026-10-08.json").read_text())
    assert doc["by_sku"]["SKU-0001"] == {"orders": 2, "quantity": 3, "amount": 37.05}
    assert doc["by_status"] == {"Failed": 1, "Fulfilled": 1}
    assert f.calls[0].url.params["since"] == "2026-10-08T00:00:00Z"
    assert commands.aggregate_orders([], date(2026, 1, 1))["orders"] == 0


async def test_process_batch_items_memory(spans):
    src = MemorySource()
    tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    for i in range(3):
        src.put(json.dumps({"item_id": f"item-{i}", "batch_id": "b1"}).encode(), {"traceparent": tp})
    src.put(b"garbage")
    sink = commands.MemoryResultSink()
    out = await commands.process_batch_items(src, sink, queue="batch-items", max_messages=10, max_seconds=2)
    assert out["completed"] == 3 and out["dead_lettered"] == 1 and out["received"] == 4
    assert set(sink.rows) == {"item-0", "item-1", "item-2"} and sink.rows["item-0"]["status"] == "Processed"
    consumer = [s for s in spans() if s.name == "servicebus.process"]
    assert len(consumer) == 4 and all(s.parent is None for s in consumer)
    assert sum(1 for s in consumer if s.links and s.links[0].context.trace_id == int("4bf92f3577b34da6a3ce929d0e0e4736", 16)) == 3


async def test_process_batch_items_respects_max_messages():
    src = MemorySource()
    for i in range(30):
        src.put(json.dumps({"item_id": f"i{i}"}).encode())
    out = await commands.process_batch_items(src, commands.MemoryResultSink(), max_messages=12, max_seconds=5)
    assert out["received"] == 12 and src.queue.qsize() == 18


def test_cli_exit_codes(tmp_path):
    env = {**os.environ, "MESSAGING_MODE": "memory", "RESULT_SINK": "memory", "BATCH_MAX_SECONDS": "1"}
    ok = subprocess.run([sys.executable, "-m", "hello_jobs", "process-batch-items"], env=env, capture_output=True, text=True, timeout=60)
    assert ok.returncode == 0, ok.stdout + ok.stderr
    line = [json.loads(x) for x in ok.stdout.splitlines() if x.startswith("{") and '"job completed"' in x][0]
    assert line["summary"]["received"] == 0 and line["service"] == "hello-jobs" and len(line["trace_id"]) == 32
    env.pop("ORDERS_API_URL", None)
    bad = subprocess.run([sys.executable, "-m", "hello_jobs", "daily-aggregate"], env=env, capture_output=True, text=True, timeout=60)
    assert bad.returncode == 1 and '"error.kind":"JobFailed"' in bad.stdout
    usage = subprocess.run([sys.executable, "-m", "hello_jobs", "nope"], env=env, capture_output=True, text=True, timeout=60)
    assert usage.returncode == 2


def test_cli_resolves_dsv_reference_from_mock_dsv():
    """DURABLE_FUNCTION_KEY=dsv://... is resolved at start-up (client_credentials against tools/secrets/mock_dsv.py)."""
    import pathlib

    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[4] / "tools" / "secrets"))
    mock_dsv = pytest.importorskip("mock_dsv")
    value = "durable-key-VALUE-41c9"
    cfg = {
        "users": {"jobs": {"read": ["eh/dev/jobs/*"]}},
        "clients": {"jobs-local": {"secret": "cs-local", "identity": "jobs"}},
        "secrets": {"eh/dev/jobs/durable-function-key": {"value": value}},
    }
    httpd, state = mock_dsv.serve(cfg)
    try:
        base = f"http://127.0.0.1:{httpd.server_address[1]}/v1"
        env = {
            **os.environ,
            "MESSAGING_MODE": "memory",
            "RESULT_SINK": "memory",
            "BATCH_MAX_SECONDS": "1",
            "DSV_AUTH": "client_credentials",
            "DSV_BASE_URL": base,
            "DSV_CLIENT_ID": "jobs-local",
            "DSV_CLIENT_SECRET": "cs-local",
            "DURABLE_FUNCTION_KEY": "dsv://eh/dev/jobs/durable-function-key",
        }
        ok = subprocess.run([sys.executable, "-m", "hello_jobs", "process-batch-items"], env=env, capture_output=True, text=True, timeout=60)
        assert ok.returncode == 0, ok.stdout + ok.stderr
        assert value not in ok.stdout + ok.stderr
        assert [c["path"] for c in state.calls] == ["/v1/token", "eh/dev/jobs/durable-function-key"]
        env["DURABLE_FUNCTION_KEY"] = "dsv://eh/dev/jobs/missing"
        bad = subprocess.run([sys.executable, "-m", "hello_jobs", "process-batch-items"], env=env, capture_output=True, text=True, timeout=60)
        assert bad.returncode == 1 and "DURABLE_FUNCTION_KEY (DSV secret read failed (not found, HTTP 404))" in bad.stderr
        env.update({"DSV_AUTH": "none", "DURABLE_FUNCTION_KEY": "dsv://eh/dev/jobs/durable-function-key"})
        none = subprocess.run([sys.executable, "-m", "hello_jobs", "process-batch-items"], env=env, capture_output=True, text=True, timeout=60)
        assert none.returncode == 1 and "DSV_AUTH=none" in none.stderr
    finally:
        httpd.shutdown()
