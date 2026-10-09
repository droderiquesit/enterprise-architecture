"""Static validation of the Logic Apps artifacts:
* every JSON file is well-formed;
* the Consumption definition validates against the official Workflow Definition Language schema
  (2016-06-01, vendored in tests/schemas, downloaded from schema.management.azure.com on 2026-10-09);
* the Standard workflow validates against the same schema extended only with the Standard-only
  `ServiceProvider` operation type (built-in connectors), plus cross-file checks: connection names exist in
  connections.json, referenced app settings / parameters are declared, runAfter targets exist."""

import copy
import json
import re
from pathlib import Path

import jsonschema
import pytest

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = json.loads((ROOT / "tests" / "schemas" / "workflowdefinition-2016-06-01.json").read_text())
SERVICE_PROVIDER_ALTERNATIVE = {
    "type": "object",
    "required": ["type", "inputs"],
    "properties": {
        "type": {"enum": ["ServiceProvider"]},
        "inputs": {
            "type": "object",
            "required": ["parameters", "serviceProviderConfiguration"],
            "properties": {
                "serviceProviderConfiguration": {
                    "type": "object",
                    "required": ["connectionName", "operationId", "serviceProviderId"],
                    "properties": {"serviceProviderId": {"type": "string", "pattern": "^/serviceProviders/"}},
                }
            },
        },
    },
}


def _standard_schema():
    s = copy.deepcopy(SCHEMA)

    def walk(node):
        if isinstance(node, dict):
            if isinstance(node.get("enum"), list) and "ApiConnection" in node["enum"] and "Compose" in node["enum"]:
                node["enum"].append("ServiceProvider")
            for key, value in node.items():
                # operation alternatives (actions and triggers) are oneOf lists discriminated by a `type` enum
                if key == "oneOf" and isinstance(value, list) and any(isinstance(v, dict) and "enum" in v.get("properties", {}).get("type", {}) for v in value):
                    value.append(SERVICE_PROVIDER_ALTERNATIVE)
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(s)
    return s


def all_json_files():
    return sorted(p for p in ROOT.rglob("*.json") if "tests" not in p.parts)


@pytest.mark.parametrize("path", all_json_files(), ids=lambda p: str(p.relative_to(ROOT)))
def test_json_well_formed(path):
    json.loads(path.read_text())


def _run_after_targets_exist(actions: dict):
    for name, action in actions.items():
        for dep in action.get("runAfter") or {}:
            assert dep in actions, f"{name} runs after unknown action {dep}"
        if "actions" in action:
            _run_after_targets_exist(action["actions"])


def test_consumption_definition_valid_against_official_schema():
    d = json.loads((ROOT / "consumption" / "batch-request.definition.json").read_text())
    errors = list(jsonschema.Draft4Validator(SCHEMA).iter_errors(d))
    assert not errors, [e.message[:200] for e in errors]
    assert d["triggers"]["Recurrence"]["recurrence"] == {"frequency": "Hour", "interval": 1}
    send = d["actions"]["For_each_item"]["actions"]["Send_message_to_batch_items"]
    assert send["type"] == "ApiConnection" and "$connections" in send["inputs"]["host"]["connection"]["name"]
    assert d["parameters"]["queueName"]["defaultValue"] == "batch-items"
    _run_after_targets_exist(d["actions"])


def test_standard_workflow_valid_and_consistent():
    wf = json.loads((ROOT / "standard" / "audit-archive" / "workflow.json").read_text())
    assert wf["kind"] == "Stateful"
    d = wf["definition"]
    errors = list(jsonschema.Draft4Validator(_standard_schema()).iter_errors(d))
    assert not errors, [e.message[:200] for e in errors]
    connections = json.loads((ROOT / "standard" / "connections.json").read_text())["serviceProviderConnections"]
    parameters = json.loads((ROOT / "standard" / "parameters.json").read_text())
    ops = list(d["triggers"].values()) + list(d["actions"].values())
    for op in ops:
        if op["type"] == "ServiceProvider":
            cfg = op["inputs"]["serviceProviderConfiguration"]
            assert cfg["connectionName"] in connections
            assert connections[cfg["connectionName"]]["serviceProvider"]["id"] == cfg["serviceProviderId"]
    trigger = d["triggers"]["When_messages_are_available_in_a_topic"]
    assert trigger["inputs"]["serviceProviderConfiguration"]["operationId"] == "receiveTopicMessages"
    assert parameters["subscriptionName"]["value"] == "archive" and parameters["topicName"]["value"] == "order-events"
    upload = d["actions"]["Upload_blob_to_archive"]["inputs"]
    assert upload["serviceProviderConfiguration"]["operationId"] == "uploadBlob"
    for ref in re.findall(r"parameters\('([^']+)'\)", json.dumps(d)):
        assert ref in parameters, ref
    _run_after_targets_exist(d["actions"])


def test_standard_connections_use_managed_identity_and_app_settings():
    conns = json.loads((ROOT / "standard" / "connections.json").read_text())["serviceProviderConnections"]
    for name, c in conns.items():
        assert c["parameterSetName"] == "ManagedServiceIdentity", name
        assert c["parameterValues"]["authProvider"]["Type"] == "ManagedServiceIdentity", name
        text = json.dumps(c)
        assert "connectionString" not in text and "AccountKey" not in text and "SharedAccessKey" not in text
    settings = set(
        re.findall(r"appsetting\('([^']+)'\)", (ROOT / "standard" / "connections.json").read_text() + (ROOT / "standard" / "parameters.json").read_text())
    )
    assert settings == {"serviceBus_fullyQualifiedNamespace", "AzureBlob_blobStorageEndpoint", "ARCHIVE_CONTAINER"}


def test_host_json_uses_workflows_bundle():
    host = json.loads((ROOT / "standard" / "host.json").read_text())
    assert host["extensionBundle"] == {"id": "Microsoft.Azure.Functions.ExtensionBundle.Workflows", "version": "[1.*, 2.0.0)"}


def test_schema_extension_is_needed_and_minimal():
    """Guard: the official schema alone rejects ServiceProvider (Standard-only), so the extension is required."""
    d = json.loads((ROOT / "standard" / "audit-archive" / "workflow.json").read_text())["definition"]
    assert list(jsonschema.Draft4Validator(SCHEMA).iter_errors(d))
