"""End-to-end against the official Azure Service Bus emulator (+ SQL Server it needs) and Azurite Tables:
a producer sends OrderCreated with traceparent in application_properties; the real worker process path
(ServiceBusSource + TableSink) consumes order-events/notifications, writes the notification row, completes
the message; a poison message is dead-lettered and visible in the subscription's DLQ."""

import asyncio
import json
import time

import pytest

from hello_common.testing import docker_available, run_container, servicebus_emulator, servicebus_emulator_config

pytestmark = [pytest.mark.integration, pytest.mark.skipif(not docker_available(), reason="docker not available")]
AZURITE_KEY = "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
TP = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"


async def test_servicebus_emulator_to_table(monkeypatch, spans):
    from azure.data.tables.aio import TableClient
    from azure.servicebus import ServiceBusMessage
    from azure.servicebus.aio import ServiceBusClient

    from hello_worker import settings as settings_mod
    from hello_worker.sinks import TableSink
    from hello_worker.sources import ServiceBusSource
    from hello_worker.worker import Worker

    cfg = servicebus_emulator_config(topics={"order-events": ["notifications", "fulfillment", "audit"]})
    with (
        servicebus_emulator(cfg) as conn,
        run_container(
            "mcr.microsoft.com/azure-storage/azurite:latest",
            [10002],
            command=["azurite-table", "--tableHost", "0.0.0.0", "--skipApiVersionCheck", "--loose"],
            ready=lambda c: "successfully" in c.logs(),
        ) as az,
    ):
        tables_cs = f"DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey={AZURITE_KEY};TableEndpoint=http://{az.host}:{az.port(10002)}/devstoreaccount1;"
        monkeypatch.setenv("SERVICEBUS_CONNECTION_STRING", conn)
        monkeypatch.setenv("TABLES_CONNECTION_STRING", tables_cs)
        monkeypatch.setenv("RECEIVE_WAIT_SECONDS", "2")
        s = settings_mod.load()
        order_id = "22222222-2222-2222-2222-222222222222"
        # Producer runs inside trace 4bf9...; with azure-core OTel tracing enabled the SDK stamps its own
        # message span context (same trace id) into application_properties, as orders-api's SDK does.
        from opentelemetry import trace as ot
        from opentelemetry.trace import NonRecordingSpan

        from hello_common.propagation import parse_traceparent

        parent_ctx = ot.set_span_in_context(NonRecordingSpan(parse_traceparent(TP)))
        with ot.get_tracer("test-producer").start_as_current_span("orders-api publish", context=parent_ctx):
            async with ServiceBusClient.from_connection_string(conn) as producer, producer.get_topic_sender("order-events") as sender:
                body = {
                    "event": "OrderCreated",
                    "order_id": order_id,
                    "sku": "SKU-0004",
                    "quantity": 1,
                    "amount": 34.4,
                    "created_at": "2026-10-09T12:00:00Z",
                }
                await sender.send_messages(
                    [
                        ServiceBusMessage(json.dumps(body), message_id=order_id, application_properties={"traceparent": TP}, content_type="application/json"),
                        ServiceBusMessage(b"{not json", message_id="poison-1"),
                    ]
                )
        source, sink = ServiceBusSource(s), TableSink(s)
        await sink.open()
        await source.open()
        w = Worker(source, sink, entity=s.entity, receive_wait=2, max_attempts=3, retry_delay_base=0.1)
        task = asyncio.create_task(w.run())
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and (w.stats["completed"] < 1 or w.stats["dead_lettered"] < 1):
            await asyncio.sleep(0.5)
        w.stop()
        await task
        await source.close()
        assert w.stats["completed"] == 1 and w.stats["dead_lettered"] == 1, w.stats
        async with TableClient.from_connection_string(tables_cs, table_name="notifications") as t:
            row = await t.get_entity("order", order_id)
        assert row["status"] == "Notified" and row["producer_trace_id"] == "4bf92f3577b34da6a3ce929d0e0e4736"
        async with ServiceBusClient.from_connection_string(conn) as c:
            async with c.get_subscription_receiver("order-events", "notifications", sub_queue="deadletter", max_wait_time=5) as dlq:
                dead = await dlq.receive_messages(max_message_count=5, max_wait_time=5)
                assert [m.dead_letter_reason for m in dead] == ["PoisonMessage"]
                for m in dead:
                    await dlq.complete_message(m)
        consumer = [x for x in spans() if x.name == "servicebus.process"]
        linked = [x for x in consumer if x.links and x.links[0].context.trace_id == int("4bf92f3577b34da6a3ce929d0e0e4736", 16)]
        assert linked and all(x.parent is None for x in linked)
