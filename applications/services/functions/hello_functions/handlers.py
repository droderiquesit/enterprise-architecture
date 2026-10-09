"""Handlers for the three functions.

audit         order-events/audit Service Bus message -> append-only audit entry. AUDIT_SINK=ledger (Azure
              Confidential Ledger, collection order-audit; LEDGER_ENDPOINT) | table (Table Storage `audit`, RowKey =
              message id -> idempotent; TABLES_ENDPOINT or TABLES_CONNECTION_STRING) | log. Delivery is at-least-once:
              a redelivered message can append a second ledger entry carrying the same message_id.
cache_warmer  GET {CATALOG_API_URL}/products then GET /products/{sku} for each (populates Redis cache-aside).
quote         price quote from catalog: {sku, quantity, unit_price, amount, currency, quoted_at, valid_until}.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import UTC, datetime, timedelta
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

from opentelemetry import trace
from opentelemetry.trace import SpanKind

from hello_common.http import create_client
from hello_common.propagation import links_from_properties, normalize_properties, producer_context

log = logging.getLogger("hello_functions")
tracer = trace.get_tracer("hello_functions")


class PoisonAudit(ValueError):
    pass


# ------------------------------------------------------------------------------------------- audit
def build_audit_entry(body: bytes | str, message_id: str, properties: dict[str, Any] | None) -> dict[str, Any]:
    try:
        event = json.loads(body)
    except ValueError as exc:
        raise PoisonAudit(f"invalid JSON: {exc}") from exc
    if not isinstance(event, dict) or not event.get("order_id"):
        raise PoisonAudit("order_id missing")
    producer = producer_context(properties)
    return {
        "message_id": message_id,
        "event": str(event.get("event", "OrderCreated")),
        "order_id": str(event["order_id"]),
        "sku": str(event.get("sku", "")),
        "amount": float(event.get("amount") or 0),
        "producer_trace_id": format(producer.trace_id, "032x") if producer else "",
        "audited_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
    }


class AuditSink:
    def write(self, entry: dict[str, Any]) -> str:  # returns a reference (tx id / row key)
        raise NotImplementedError


class LogAuditSink(AuditSink):
    def write(self, entry: dict[str, Any]) -> str:
        log.info("audit entry", extra={"audit": entry})
        return entry["message_id"]


class TableAuditSink(AuditSink):
    def __init__(self, client: Any = None) -> None:
        self._t = client

    def _table(self) -> Any:
        if self._t is None:
            from azure.data.tables import TableClient

            name = os.environ.get("AUDIT_TABLE", "audit")
            if os.environ.get("TABLES_CONNECTION_STRING"):
                self._t = TableClient.from_connection_string(os.environ["TABLES_CONNECTION_STRING"], table_name=name)
            else:
                from hello_common.azure_auth import get_credential

                self._t = TableClient(endpoint=os.environ["TABLES_ENDPOINT"], table_name=name, credential=get_credential())
        return self._t

    def write(self, entry: dict[str, Any]) -> str:
        from azure.data.tables import UpdateMode

        self._table().upsert_entity({"PartitionKey": entry["order_id"], "RowKey": entry["message_id"], **entry}, mode=UpdateMode.REPLACE)
        return entry["message_id"]


class LedgerAuditSink(AuditSink):
    def __init__(self, client: Any = None, collection: str | None = None) -> None:
        self._c = client
        self.collection = collection or os.environ.get("LEDGER_COLLECTION", "order-audit")

    def _client(self) -> Any:
        if self._c is None:
            import tempfile
            from urllib.parse import urlparse

            from azure.confidentialledger import ConfidentialLedgerClient
            from azure.confidentialledger.certificate import ConfidentialLedgerCertificateClient

            from hello_common.azure_auth import get_credential

            endpoint = os.environ["LEDGER_ENDPOINT"]
            ledger_id = urlparse(endpoint).hostname.split(".")[0]
            cert = ConfidentialLedgerCertificateClient().get_ledger_identity(ledger_id=ledger_id)["ledgerTlsCertificate"]
            path = os.path.join(tempfile.gettempdir(), f"{ledger_id}.pem")
            with open(path, "w", encoding="ascii") as fh:
                fh.write(cert)
            self._c = ConfidentialLedgerClient(endpoint=endpoint, credential=get_credential(), ledger_certificate_path=path)
        return self._c

    def write(self, entry: dict[str, Any]) -> str:
        result = self._client().begin_create_ledger_entry({"contents": json.dumps(entry, sort_keys=True)}, collection_id=self.collection).result()
        return result["transactionId"]


def audit_sink_from_env() -> AuditSink:
    kind = os.environ.get("AUDIT_SINK", "table" if os.environ.get("TABLES_ENDPOINT") or os.environ.get("TABLES_CONNECTION_STRING") else "log")
    return {"ledger": LedgerAuditSink, "table": TableAuditSink}.get(kind, LogAuditSink)()


def handle_audit(body: bytes | str, message_id: str, properties: dict[str, Any] | None, sink: AuditSink) -> dict[str, Any]:
    """CONSUMER span linked (not parented) to the producer's traceparent; raises -> runtime retries/dead-letters."""
    props = normalize_properties(properties)
    with tracer.start_as_current_span(
        "servicebus.process",
        kind=SpanKind.CONSUMER,
        links=links_from_properties(props),
        attributes={
            "messaging.system": "servicebus",
            "messaging.destination.name": "order-events/subscriptions/audit",
            "messaging.message.id": message_id,
            "messaging.operation.type": "process",
        },
    ):
        entry = build_audit_entry(body, message_id, props)
        ref = sink.write(entry)
        log.info("audit recorded", extra={"order_id": entry["order_id"], "audit_ref": ref, "sink": type(sink).__name__})
        return {"ref": ref, **entry}


# ------------------------------------------------------------------------------------- cache warmer
def warm_cache(catalog_url: str | None = None, client_factory=create_client, limit: int = 20) -> dict[str, Any]:
    base = (catalog_url or os.environ.get("CATALOG_API_URL") or "").rstrip("/")
    if not base:
        raise ValueError("CATALOG_API_URL is required")
    results = {"HIT": 0, "MISS": 0, "BYPASS": 0, "errors": 0}
    with client_factory(base, timeout=5.0, retries=1) as client:
        r = client.get("/products", params={"limit": limit})
        r.raise_for_status()
        body = r.json()
        items = body.get("items", []) if isinstance(body, dict) else body
        for p in items:
            try:
                pr = client.get(f"/products/{p['sku']}")
                pr.raise_for_status()
                results[pr.headers.get("X-Cache", "BYPASS").upper()] = results.get(pr.headers.get("X-Cache", "BYPASS").upper(), 0) + 1
            except Exception:
                results["errors"] += 1
    log.info("cache warmed", extra={"warm": results})
    return results


# -------------------------------------------------------------------------------------------- quote
def quote(sku: str | None, quantity: str | int | None, catalog_url: str | None = None, client_factory=create_client) -> tuple[int, dict[str, Any]]:
    import re

    if not sku or not re.match(r"^[A-Z0-9][A-Z0-9-]{2,31}$", sku):
        return 400, {"type": "about:blank", "title": "Bad Request", "status": 400, "detail": "sku is required (e.g. SKU-0001)"}
    try:
        qty = int(quantity or 1)
        if not 1 <= qty <= 100:
            raise ValueError
    except ValueError:
        return 400, {"type": "about:blank", "title": "Bad Request", "status": 400, "detail": "quantity must be 1..100"}
    base = (catalog_url or os.environ.get("CATALOG_API_URL") or "").rstrip("/")
    if not base:
        return 503, {"type": "about:blank", "title": "Service Unavailable", "status": 503, "detail": "CATALOG_API_URL not configured"}
    try:
        with client_factory(base, timeout=5.0, retries=2) as client:
            r = client.get(f"/products/{sku}")
    except Exception as exc:  # timeouts / connection errors after bounded retries
        log.warning("catalog call failed", extra={"error.kind": type(exc).__name__})
        status = 504 if "Timeout" in type(exc).__name__ else 502
        return status, {
            "type": "about:blank",
            "title": "Bad Gateway" if status == 502 else "Gateway Timeout",
            "status": status,
            "detail": f"catalog unavailable: {type(exc).__name__}",
        }
    if r.status_code == 404:
        return 404, {"type": "about:blank", "title": "Not Found", "status": 404, "detail": f"product {sku} not found"}
    if r.status_code >= 400:
        return 502, {"type": "about:blank", "title": "Bad Gateway", "status": 502, "detail": f"catalog returned {r.status_code}"}
    p = r.json()
    unit = Decimal(str(p.get("price", p.get("unit_price"))))
    now = datetime.now(UTC)
    return 200, {
        "sku": sku,
        "quantity": qty,
        "unit_price": float(unit),
        "amount": float((unit * qty).quantize(Decimal("0.01"), ROUND_HALF_UP)),
        "currency": p.get("currency", "USD"),
        "quoted_at": now.isoformat().replace("+00:00", "Z"),
        "valid_until": (now + timedelta(minutes=15)).isoformat().replace("+00:00", "Z"),
    }
