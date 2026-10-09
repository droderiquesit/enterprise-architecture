import json

import httpx
import pytest

from hello_common.http import create_client
from hello_functions import handlers

from conftest import EXPORTER, PROVIDER

TP = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"


def mock_factory(handler):
    def make(base, **kw):
        return create_client(base, inner_transport=httpx.MockTransport(handler), backoff_base=0.001, **kw)

    return make


class MemSink(handlers.AuditSink):
    def __init__(self):
        self.entries = []

    def write(self, entry):
        self.entries.append(entry)
        return f"2.{len(self.entries)}"


def test_function_app_indexes_three_functions_with_expected_bindings():
    import function_app

    fns = {f.get_function_name(): f for f in function_app.app.get_functions()}
    assert set(fns) == {"audit", "cache_warmer", "quote"}
    audit = json.loads(fns["audit"].get_function_json())["bindings"][0]
    assert audit["type"] == "serviceBusTrigger" and audit["topicName"] == "order-events" and audit["subscriptionName"] == "audit"
    assert audit["connection"] == "ServiceBusConnection"
    timer = json.loads(fns["cache_warmer"].get_function_json())["bindings"][0]
    assert timer["type"] == "timerTrigger" and timer["schedule"] == "0 */5 * * * *"
    http = json.loads(fns["quote"].get_function_json())["bindings"][0]
    assert http["type"] == "httpTrigger" and http["route"] == "quote" and http["methods"] == ["GET"]


def test_audit_links_producer_and_writes_entry():
    EXPORTER.clear()
    sink = MemSink()
    body = json.dumps({"event": "OrderCreated", "order_id": "o-1", "sku": "SKU-0001", "amount": 12.35})
    out = handlers.handle_audit(body.encode(), "m-1", {b"traceparent": TP.encode()}, sink)
    assert out["ref"] == "2.1" and sink.entries[0]["producer_trace_id"] == "4bf92f3577b34da6a3ce929d0e0e4736"
    PROVIDER.force_flush()
    span = [s for s in EXPORTER.get_finished_spans() if s.name == "servicebus.process"][-1]
    assert span.kind.name == "CONSUMER" and span.links[0].context.trace_id == int("4bf92f3577b34da6a3ce929d0e0e4736", 16)
    assert span.context.trace_id != int("4bf92f3577b34da6a3ce929d0e0e4736", 16)
    with pytest.raises(handlers.PoisonAudit):
        handlers.handle_audit(b"{}", "m-2", {}, sink)


def test_ledger_and_table_sinks_with_fakes():
    class Ledger:
        def begin_create_ledger_entry(self, entry, collection_id=None):
            assert collection_id == "order-audit" and json.loads(entry["contents"])["order_id"] == "o-9"
            return type("P", (), {"result": lambda self: {"transactionId": "2.77"}})()

    assert handlers.LedgerAuditSink(Ledger()).write({"order_id": "o-9", "message_id": "m"}) == "2.77"

    class Table:
        def __init__(self):
            self.rows = {}

        def upsert_entity(self, e, mode=None):
            self.rows[(e["PartitionKey"], e["RowKey"])] = e

    t = Table()
    sink = handlers.TableAuditSink(t)
    sink.write({"order_id": "o-9", "message_id": "m"})
    sink.write({"order_id": "o-9", "message_id": "m"})  # redelivery -> same row (idempotent)
    assert len(t.rows) == 1


def test_sink_selection(monkeypatch):
    monkeypatch.delenv("TABLES_ENDPOINT", raising=False)
    monkeypatch.delenv("AUDIT_SINK", raising=False)
    assert isinstance(handlers.audit_sink_from_env(), handlers.LogAuditSink)
    monkeypatch.setenv("AUDIT_SINK", "ledger")
    assert isinstance(handlers.audit_sink_from_env(), handlers.LedgerAuditSink)


def test_cache_warmer_reports_cache_results():
    def h(req):
        if req.url.path == "/products":
            return httpx.Response(200, json={"items": [{"sku": "SKU-0001"}, {"sku": "SKU-0002"}]})
        return httpx.Response(200, json={}, headers={"X-Cache": "MISS" if req.url.path.endswith("1") else "HIT"})

    assert handlers.warm_cache("http://catalog", mock_factory(h)) == {"HIT": 1, "MISS": 1, "BYPASS": 0, "errors": 0}
    with pytest.raises(ValueError):
        handlers.warm_cache("", mock_factory(h))


def test_quote():
    f = mock_factory(lambda r: httpx.Response(404) if "9999" in r.url.path else httpx.Response(200, json={"sku": "SKU-0001", "price": 12.35, "currency": "USD"}))
    status, body = handlers.quote("SKU-0001", "3", "http://catalog", f)
    assert status == 200 and body["amount"] == 37.05 and body["unit_price"] == 12.35 and body["valid_until"] > body["quoted_at"]
    assert handlers.quote("SKU-9999", "1", "http://catalog", f)[0] == 404
    assert handlers.quote("bad sku", "1", "http://catalog", f)[0] == 400
    assert handlers.quote("SKU-0001", "0", "http://catalog", f)[0] == 400
    assert handlers.quote("SKU-0001", "1", "", f)[0] == 503


def test_host_json_contract():
    from pathlib import Path

    host = json.loads((Path(__file__).resolve().parents[1] / "host.json").read_text())
    assert host["version"] == "2.0" and host["telemetryMode"] == "OpenTelemetry"
    assert host["extensionBundle"] == {"id": "Microsoft.Azure.Functions.ExtensionBundle", "version": "[4.0.0, 5.0.0)"}
