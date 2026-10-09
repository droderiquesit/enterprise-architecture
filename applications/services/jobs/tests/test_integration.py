"""process-batch-items against the official Service Bus emulator (queue batch-items) + Azurite Tables."""

import json

import pytest

from hello_common.testing import docker_available, run_container, servicebus_emulator, servicebus_emulator_config

pytestmark = [pytest.mark.integration, pytest.mark.skipif(not docker_available(), reason="docker not available")]
AZURITE_KEY = "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="


async def test_batch_items_from_emulator(monkeypatch):
    from azure.data.tables.aio import TableClient
    from azure.servicebus import ServiceBusMessage
    from azure.servicebus.aio import ServiceBusClient

    from hello_jobs import commands

    with servicebus_emulator(servicebus_emulator_config(queues=["batch-items"])) as conn, run_container(
        "mcr.microsoft.com/azure-storage/azurite:latest", [10002], command=["azurite-table", "--tableHost", "0.0.0.0", "--skipApiVersionCheck", "--loose"],
        ready=lambda c: "successfully" in c.logs()) as az:
        tables_cs = f"DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey={AZURITE_KEY};TableEndpoint=http://{az.host}:{az.port(10002)}/devstoreaccount1;"
        async with ServiceBusClient.from_connection_string(conn) as c, c.get_queue_sender("batch-items") as sender:
            await sender.send_messages([ServiceBusMessage(json.dumps({"item_id": f"it-{i}", "batch_id": "b42"})) for i in range(5)])
        monkeypatch.setenv("SERVICEBUS_CONNECTION_STRING", conn)
        monkeypatch.setenv("RESULT_SINK", "table")
        monkeypatch.setenv("TABLES_CONNECTION_STRING", tables_cs)
        out = await commands.process_batch_items(max_messages=50, max_seconds=30)
        assert out["completed"] == 5 and out["received"] == 5, out
        async with TableClient.from_connection_string(tables_cs, table_name="batchitems") as t:
            rows = [e async for e in t.query_entities("PartitionKey eq 'b42'")]
        assert sorted(r["RowKey"] for r in rows) == [f"it-{i}" for i in range(5)]
        again = await commands.process_batch_items(max_messages=50, max_seconds=5)
        assert again["received"] == 0  # all messages were completed (settled), queue drained
