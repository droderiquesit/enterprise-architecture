"""Job implementations. Each returns a JSON-serialisable summary; the CLI prints it as a log line and
exits non-zero when the job failed.

seed                 POST {CATALOG_API_URL}/seed, {INVENTORY_API_URL}/inventory/seed (if set) and /seed on every
                     adapter in ADAPTERS_JSON ([{"family","url"}]). Idempotent (deterministic seeds).
reconcile-trigger    POST {DURABLE_API_URL}/api/workflows/reconciliation (x-functions-key from DURABLE_FUNCTION_KEY
                     when set - a Key Vault reference, never logged).
process-batch-items  Receive from Service Bus queue SB_QUEUE (default batch-items) at most BATCH_MAX_MESSAGES
                     (default 50) within BATCH_MAX_SECONDS (default 60); one CONSUMER span per message linked
                     to the producer; results upserted (idempotent by item id) to RESULT_SINK=table|log|memory;
                     poison -> dead-letter; failures -> abandon (dead-letter after MAX_DELIVERY_ATTEMPTS).
daily-aggregate      GET {ORDERS_API_URL}/orders?since=<day>&limit=ORDERS_PAGE_LIMIT, aggregate count/quantity/
                     amount per sku and status for AGGREGATE_DATE (default yesterday UTC); write JSON to
                     OUTPUT_PATH (default $AZ_BATCH_TASK_WORKING_DIR or ./) and optionally upload to
                     AGGREGATE_BLOB_ACCOUNT_URL/AGGREGATE_BLOB_CONTAINER (managed identity).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from collections import defaultdict
from datetime import UTC, date, datetime, timedelta
from typing import Any

from opentelemetry import trace
from opentelemetry.context import Context
from opentelemetry.trace import SpanKind, Status, StatusCode

from hello_common.http import create_client
from hello_common.messaging import Envelope, MemorySource, ServiceBusSource
from hello_common.propagation import links_from_properties

log = logging.getLogger("hello_jobs")
tracer = trace.get_tracer("hello_jobs")


class JobFailed(RuntimeError):
    pass


# ------------------------------------------------------------------------------------------- seed
def seed(env: dict[str, str] | None = None, client_factory=create_client) -> dict[str, Any]:
    env = dict(os.environ if env is None else env)
    targets: list[tuple[str, str, bool]] = []
    if env.get("CATALOG_API_URL"):
        targets.append(("catalog", env["CATALOG_API_URL"].rstrip("/") + "/seed", True))
    if env.get("INVENTORY_API_URL"):
        targets.append(("inventory", env["INVENTORY_API_URL"].rstrip("/") + "/inventory/seed", True))
    for adapter in json.loads(env.get("ADAPTERS_JSON") or "[]"):
        targets.append((f"adapter:{adapter['family']}", adapter["url"].rstrip("/") + "/seed", False))
    if not targets:
        raise JobFailed("nothing to seed: set CATALOG_API_URL / INVENTORY_API_URL / ADAPTERS_JSON")
    results: dict[str, Any] = {}
    failed_required = []
    with client_factory(timeout=30.0, retries=3) as client:
        for name, url, required in targets:
            try:
                # Seeds are idempotent, so the POST carries an Idempotency-Key and may be retried.
                r = client.post(url, headers={"Idempotency-Key": f"seed-{name}-{date.today().isoformat()}"})
                results[name] = {"status": r.status_code}
                if r.status_code >= 400:
                    raise JobFailed(f"HTTP {r.status_code}")
            except Exception as exc:
                results[name] = {"status": "error", "error": f"{type(exc).__name__}: {exc}"[:200]}
                if required:
                    failed_required.append(name)
    summary = {"command": "seed", "targets": results, "ok": not failed_required}
    if failed_required:
        raise JobFailed(json.dumps(summary))
    return summary


# ------------------------------------------------------------------------------ reconcile-trigger
def reconcile_trigger(env: dict[str, str] | None = None, client_factory=create_client) -> dict[str, Any]:
    env = dict(os.environ if env is None else env)
    base = env.get("DURABLE_API_URL")
    if not base:
        raise JobFailed("DURABLE_API_URL is required")
    headers = {"Idempotency-Key": f"reconcile-{datetime.now(UTC).strftime('%Y%m%dT%H%M')}"}
    if env.get("DURABLE_FUNCTION_KEY"):
        headers["x-functions-key"] = env["DURABLE_FUNCTION_KEY"]
    with client_factory(timeout=30.0, retries=2) as client:
        r = client.post(base.rstrip("/") + "/api/workflows/reconciliation", headers=headers, json={"requested_by": "hello-jobs"})
    if r.status_code >= 400:
        raise JobFailed(f"reconciliation trigger failed: HTTP {r.status_code}")
    body: Any
    try:
        body = r.json()
    except ValueError:
        body = {}
    return {"command": "reconcile-trigger", "status": r.status_code, "instance_id": (body or {}).get("id") or (body or {}).get("instanceId")}


# ---------------------------------------------------------------------------- process-batch-items
class MemoryResultSink:
    def __init__(self) -> None:
        self.rows: dict[str, dict] = {}

    async def open(self) -> None: ...
    async def close(self) -> None: ...

    async def upsert(self, item_id: str, row: dict) -> None:
        self.rows[item_id] = row


class LogResultSink(MemoryResultSink):
    async def upsert(self, item_id: str, row: dict) -> None:
        log.info("batch item result", extra={"item_id": item_id, "batch_id": row.get("batch_id")})


class TableResultSink:
    def __init__(self, endpoint: str | None, connection_string: str | None, table: str) -> None:
        self.endpoint, self.cs, self.table_name, self._t = endpoint, connection_string, table, None

    async def open(self) -> None:
        from azure.core.exceptions import ResourceExistsError
        from azure.data.tables.aio import TableClient

        if self.cs:
            self._t = TableClient.from_connection_string(self.cs, table_name=self.table_name)
        else:
            from hello_common.azure_auth import get_credential

            self._t = TableClient(endpoint=self.endpoint, table_name=self.table_name, credential=get_credential(async_=True))
        try:
            await self._t.create_table()
        except ResourceExistsError:
            pass

    async def upsert(self, item_id: str, row: dict) -> None:
        from azure.data.tables import UpdateMode

        await self._t.upsert_entity({"PartitionKey": str(row.get("batch_id") or "batch"), "RowKey": item_id, **row}, mode=UpdateMode.REPLACE)

    async def close(self) -> None:
        if self._t is not None:
            await self._t.close()


def _process_item(body: dict[str, Any]) -> dict[str, Any]:
    """Deterministic synthetic work: checksum the item payload."""
    import hashlib

    item_id = str(body["item_id"])
    return {
        "batch_id": str(body.get("batch_id") or "adhoc"),
        "status": "Processed",
        "checksum": hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:16],
        "processed_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "item_id": item_id,
    }


async def process_batch_items(source=None, sink=None, *, queue: str | None = None, max_messages: int | None = None,
                              max_seconds: float | None = None, max_attempts: int | None = None) -> dict[str, Any]:
    queue = queue or os.environ.get("SB_QUEUE", "batch-items")
    max_messages = max_messages or int(os.environ.get("BATCH_MAX_MESSAGES", "50"))
    max_seconds = max_seconds or float(os.environ.get("BATCH_MAX_SECONDS", "60"))
    max_attempts = max_attempts or int(os.environ.get("MAX_DELIVERY_ATTEMPTS", "5"))
    if source is None:
        if os.environ.get("MESSAGING_MODE", "servicebus") == "memory":
            source = MemorySource()
        else:
            source = ServiceBusSource(fqdn=os.environ.get("SERVICEBUS_FQDN"), connection_string=os.environ.get("SERVICEBUS_CONNECTION_STRING"), queue=queue, prefetch=0)
    if sink is None:
        kind = os.environ.get("RESULT_SINK", "table")
        sink = {"memory": MemoryResultSink, "log": LogResultSink}.get(kind, MemoryResultSink)() if kind != "table" else TableResultSink(
            os.environ.get("TABLES_ENDPOINT"), os.environ.get("TABLES_CONNECTION_STRING"), os.environ.get("RESULT_TABLE", "batchitems"))
    stats = {"completed": 0, "dead_lettered": 0, "abandoned": 0}
    await sink.open()
    await source.open()
    deadline = time.monotonic() + max_seconds
    received = 0
    try:
        while received < max_messages and time.monotonic() < deadline:
            wait = max(0.5, min(5.0, deadline - time.monotonic()))
            batch = await source.receive(min(10, max_messages - received), wait)
            if not batch:
                break  # queue drained: an event-driven job exits as soon as there is no more work
            received += len(batch)
            for env in batch:
                stats[await _handle_item(env, source, sink, queue, max_attempts)] += 1
    finally:
        await source.close()
        await sink.close()
    return {"command": "process-batch-items", "queue": queue, "received": received, **stats}


async def _handle_item(env: Envelope, source, sink, queue: str, max_attempts: int) -> str:
    attrs = {"messaging.system": "servicebus", "messaging.operation.type": "process", "messaging.destination.name": queue,
             "messaging.message.id": env.message_id}
    with tracer.start_as_current_span(f"process {queue}", context=Context(), kind=SpanKind.CONSUMER,
                                      links=links_from_properties(env.application_properties), attributes=attrs) as span:
        try:
            try:
                body = json.loads(env.body)
                if not isinstance(body, dict) or "item_id" not in body:
                    raise ValueError("item_id missing")
            except ValueError as exc:
                span.set_status(Status(StatusCode.ERROR, "poison"))
                await source.dead_letter(env, "PoisonMessage", str(exc))
                return "dead_lettered"
            result = _process_item(body)
            await sink.upsert(result["item_id"], result)
            await source.complete(env)
            return "completed"
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, type(exc).__name__))
            if env.attempt >= max_attempts:
                await source.dead_letter(env, "MaxDeliveryAttemptsExceeded", f"{type(exc).__name__}: {exc}")
                return "dead_lettered"
            await source.abandon(env)
            return "abandoned"


# -------------------------------------------------------------------------------- daily-aggregate
def aggregate_orders(orders: list[dict[str, Any]], day: date) -> dict[str, Any]:
    start = datetime(day.year, day.month, day.day, tzinfo=UTC)
    end = start + timedelta(days=1)
    by_sku: dict[str, dict[str, Any]] = defaultdict(lambda: {"orders": 0, "quantity": 0, "amount": 0.0})
    by_status: dict[str, int] = defaultdict(int)
    total = 0
    for o in orders:
        try:
            created = datetime.fromisoformat(str(o.get("created_at")).replace("Z", "+00:00"))
        except ValueError:
            continue
        if created.tzinfo is None:
            created = created.replace(tzinfo=UTC)
        if not (start <= created < end):
            continue
        total += 1
        sku = str(o.get("sku", "unknown"))
        by_sku[sku]["orders"] += 1
        by_sku[sku]["quantity"] += int(o.get("quantity") or 0)
        by_sku[sku]["amount"] = round(by_sku[sku]["amount"] + float(o.get("amount") or 0), 2)
        by_status[str(o.get("status", "unknown"))] += 1
    return {"date": day.isoformat(), "orders": total, "by_sku": dict(sorted(by_sku.items())), "by_status": dict(sorted(by_status.items())),
            "amount_total": round(sum(v["amount"] for v in by_sku.values()), 2)}


def daily_aggregate(env: dict[str, str] | None = None, client_factory=create_client, upload=None) -> dict[str, Any]:
    env = dict(os.environ if env is None else env)
    base = env.get("ORDERS_API_URL")
    if not base:
        raise JobFailed("ORDERS_API_URL is required")
    day = date.fromisoformat(env["AGGREGATE_DATE"]) if env.get("AGGREGATE_DATE") else (datetime.now(UTC).date() - timedelta(days=1))
    with client_factory(timeout=30.0, retries=3) as client:
        r = client.get(base.rstrip("/") + "/orders", params={"since": f"{day.isoformat()}T00:00:00Z", "limit": env.get("ORDERS_PAGE_LIMIT", "100")})
    if r.status_code >= 400:
        raise JobFailed(f"orders-api returned HTTP {r.status_code}")
    data = r.json()
    orders = data.get("items", data.get("orders", [])) if isinstance(data, dict) else data
    result = aggregate_orders(orders, day)
    out_dir = env.get("OUTPUT_PATH") or env.get("AZ_BATCH_TASK_WORKING_DIR") or "."
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"daily-aggregate-{day.isoformat()}.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)
    uploaded = None
    if env.get("AGGREGATE_BLOB_ACCOUNT_URL"):
        uploaded = (upload or _upload_blob)(env["AGGREGATE_BLOB_ACCOUNT_URL"], env.get("AGGREGATE_BLOB_CONTAINER", "aggregates"), os.path.basename(path), path)
    return {"command": "daily-aggregate", "date": day.isoformat(), "orders": result["orders"], "output": path, "uploaded": uploaded}


def _upload_blob(account_url: str, container: str, name: str, path: str) -> str:
    from azure.storage.blob import BlobServiceClient

    from hello_common.azure_auth import get_credential

    with BlobServiceClient(account_url, credential=get_credential()) as svc, open(path, "rb") as fh:
        svc.get_blob_client(container, name).upload_blob(fh, overwrite=True)
    return f"{account_url.rstrip('/')}/{container}/{name}"


def run_async(coro):
    return asyncio.run(coro)
