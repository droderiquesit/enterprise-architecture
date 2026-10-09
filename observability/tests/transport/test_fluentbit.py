"""Local (docker) functional tests of the Fluent Bit configs against a mock Datadog logs intake.

Proves for sidecar.yaml (direct), sidecar-forward.yaml -> aggregator.yaml (forward input) and
aggregator.yaml (kafka input, SASL PLAIN with the Event Hubs "$ConnectionString" convention):
  * JSON lines parsed into attributes; timestamp consumed into the event time
  * multiline .NET / Python stack traces merged into one event
  * secrets redacted (key=value, JSON fields, Bearer tokens, storage AccountKey)
  * ddsource / service / ddtags set; trace_id / span_id / dd.trace_id retained
  * no duplicated events, payloads gzip-compressed, API key header present
Requires a docker daemon. Synthetic data only.
"""

from __future__ import annotations

import collections
import json
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from dockerutil import (
    FLB_CONFIG,
    FLUENT_BIT_IMAGE,
    HERE,
    KAFKA_IMAGE,
    Stack,
    fluent_bit_env,
    http_json,
    http_status,
    received,
    start_mock_intake,
    wait_for,
)

SAMPLES = HERE / "samples"
TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736"
SPAN_ID = "00f067aa0ba902b7"
SIDECAR_IDS = [f"evt-000{i}" for i in range(1, 8)]

pytestmark = pytest.mark.skipif(shutil.which("docker") is None, reason="docker not available")


def _event_id(ev: dict) -> str | None:
    for k in ("event_id",):
        if k in ev:
            return ev[k]
    text = json.dumps(ev)
    for i in list(range(1, 8)) + [101, 102, 201]:
        tok = f"evt-{i:04d}"
        if tok in text:
            return tok
    return None


def _by_id(events: list[dict]) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = collections.defaultdict(list)
    for ev in events:
        out[_event_id(ev)].append(ev)
    return out


PIPELINE_TAG = "telemetry.pipeline:fluent-bit"


def _is_canary(ev: dict) -> bool:
    return ev.get("canary") is True or ev.get("service") == "telemetry-canary"


def _assert_canary(events: list[dict]) -> None:
    can = [e for e in events if _is_canary(e)]
    assert can, "no pipeline canary received"
    for c in can:
        assert c["service"] == "telemetry-canary" and c["canary"] is True
        tags = c["ddtags"].split(",")
        assert PIPELINE_TAG in tags and "env:test" in tags, c["ddtags"]


def _assert_app_events(events: list[dict], expect_source: str = "csharp") -> None:
    for ev in events:
        assert PIPELINE_TAG in ev.get("ddtags", "").split(","), f"pipeline tag missing: {ev}"
    events = [e for e in events if not _is_canary(e)]
    ids = _by_id(events)
    # every sample event arrived exactly once (no duplicates, nothing split)
    for eid in SIDECAR_IDS:
        assert len(ids.get(eid, [])) == 1, f"{eid}: {len(ids.get(eid, []))} copies; got ids {sorted(k for k in ids if k)}"
    assert None not in ids, f"unexpected fragments: {ids.get(None)}"

    e1 = ids["evt-0001"][0]
    # JSON parsed: attributes are top level, message is the app message, timestamp became event time
    assert e1["message"] == "order created"
    assert e1["order_status"] == "Pending"
    assert e1["service"] == "hello-orders-api"
    assert e1["trace_id"] == TRACE_ID and e1["span_id"] == SPAN_ID
    assert e1["dd.trace_id"] == str(int(TRACE_ID[16:], 16))
    assert e1["ddsource"] == expect_source
    assert "env:test" in e1["ddtags"] and "team:observability" in e1["ddtags"]
    assert "log" not in e1

    # redaction: free text and structured fields
    e2 = json.dumps(ids["evt-0002"][0])
    assert "hunter2" not in e2 and "abc123" not in e2 and "s3cr3t-value" not in e2
    assert "[REDACTED]" in e2
    e5 = json.dumps(ids["evt-0005"][0])
    assert "eyJhbGciOiJIUzI1NiJ9" not in e5
    e7 = json.dumps(ids["evt-0007"][0])
    assert "QUJDREVGRw==" not in e7

    # error attributes retained on structured errors
    e3 = ids["evt-0003"][0]
    assert e3["error.kind"] == "System.TimeoutException"

    # multiline: .NET unhandled exception with its frames is ONE event
    e4 = ids["evt-0004"][0]
    assert "Unhandled exception" in e4["message"] and "Program.cs:line 42" in e4["message"]
    assert e4["message"].count("\n") >= 2
    assert e4["service"] == "hello-orders-api"  # FLB_DD_SERVICE fallback for non-JSON lines
    # multiline: Python traceback incl. final exception line is ONE event
    e6 = ids["evt-0006"][0]
    assert e6["message"].startswith("Traceback") and "ValueError: bad message evt-0006" in e6["message"]


def _requests_ok(reqs: list[dict]) -> None:
    assert reqs, "no requests received"
    for r in reqs:
        assert r["path"] == "/api/v2/logs"
        assert r["content_encoding"] == "gzip"
        assert r["api_key_present"]


def _write_log(dir_: Path) -> Path:
    dir_.mkdir(parents=True, exist_ok=True)
    dir_.chmod(0o777)
    target = dir_ / "app.log"
    # append in two writes to exercise tailing of new data
    content = (SAMPLES / "app.log").read_text()
    lines = content.splitlines(keepends=True)
    with target.open("a") as fh:
        fh.writelines(lines[:3])
    time.sleep(2)
    with target.open("a") as fh:
        fh.writelines(lines[3:])
    return target


@pytest.fixture()
def stack(request):
    s = Stack(request.node.name.replace("_", "-")[:20])
    yield s
    rep = getattr(request.node, "rep_call", None)
    if rep is not None and rep.failed:
        for c in s.containers:
            print(f"==== logs {c}\n{s.logs(c)[-4000:]}")
    s.close()


def test_dry_run_all_configs():
    res = subprocess.run([str(HERE / "dryrun.sh")], capture_output=True, text=True)
    print(res.stdout, res.stderr)
    assert res.returncode == 0
    assert res.stdout.count("PASS") == 8


def test_sidecar_direct_to_datadog(stack, tmp_path):
    _, base = start_mock_intake(stack)
    logdir = tmp_path / "applogs"
    logdir.mkdir()
    logdir.chmod(0o777)
    fb = stack.run(
        "sidecar", FLUENT_BIT_IMAGE,
        env=fluent_bit_env(LOG_FILE_PATH="/var/log/app/app.log"),
        volumes=[f"{FLB_CONFIG}:/fluent-bit/etc/eh:ro", f"{logdir}:/var/log/app"],
        ports=["127.0.0.1::2020"],
        cmd=["-c", "/fluent-bit/etc/eh/sidecar.yaml"],
    )
    hc = f"http://127.0.0.1:{stack.host_port(fb, 2020)}"
    wait_for(lambda: http_status(f"{hc}/api/v1/health", timeout=2) == 200, 30, what="fluent-bit health check")
    _write_log(logdir)
    wait_for(lambda: len(received(base)["events"]) >= len(SIDECAR_IDS), 60, what="sidecar events")
    time.sleep(4)  # catch late duplicates
    got = received(base)
    print(json.dumps(got["events"], indent=1)[:6000])
    _assert_app_events(got["events"])
    assert not any(_is_canary(e) for e in got["events"]), "sidecars do not emit the canary"
    _requests_ok(got["requests"])
    # self-metrics endpoint exposed for the OTel gateway / Agent to scrape
    metrics = subprocess.run(["curl", "-sf", f"{hc}/api/v2/metrics/prometheus"], capture_output=True, text=True).stdout
    # Prometheus names keep the _total suffix (monitors use e.g. fluentbit_output_errors_total)
    assert "fluentbit_output_proc_records_total" in metrics and "fluentbit_output_errors_total" in metrics


def _kafka(stack: Stack, conn_str: str, workdir: Path) -> str:
    jaas = workdir / "kafka_server_jaas.conf"
    jaas.write_text(
        "KafkaServer {\n  org.apache.kafka.common.security.plain.PlainLoginModule required\n"
        '  username="admin" password="admin-secret"\n  user_admin="admin-secret"\n'
        f'  user_$ConnectionString="{conn_str}";\n}};\n'
    )
    jaas.chmod(0o644)
    env = {
        "KAFKA_NODE_ID": "1",
        "KAFKA_PROCESS_ROLES": "broker,controller",
        "KAFKA_LISTENERS": "SASL_PLAINTEXT://:9092,CONTROLLER://:9093",
        "KAFKA_ADVERTISED_LISTENERS": "SASL_PLAINTEXT://kafka:9092",
        "KAFKA_CONTROLLER_LISTENER_NAMES": "CONTROLLER",
        "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP": "CONTROLLER:PLAINTEXT,SASL_PLAINTEXT:SASL_PLAINTEXT",
        "KAFKA_CONTROLLER_QUORUM_VOTERS": "1@localhost:9093",
        "KAFKA_INTER_BROKER_LISTENER_NAME": "SASL_PLAINTEXT",
        "KAFKA_SASL_ENABLED_MECHANISMS": "PLAIN",
        "KAFKA_SASL_MECHANISM_INTER_BROKER_PROTOCOL": "PLAIN",
        "KAFKA_OPTS": "-Djava.security.auth.login.config=/jaas/kafka_server_jaas.conf",
        "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR": "1",
        "KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR": "1",
        "KAFKA_TRANSACTION_STATE_LOG_MIN_ISR": "1",
        "KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS": "0",
        "KAFKA_NUM_PARTITIONS": "2",
    }
    k = stack.run("kafka", KAFKA_IMAGE, env=env, volumes=[f"{workdir}:/jaas:ro"])
    props = (
        "security.protocol=SASL_PLAINTEXT\nsasl.mechanism=PLAIN\n"
        'sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";\n'
    )
    subprocess.run(["docker", "exec", "-i", k, "sh", "-c", "cat > /tmp/client.properties"], input=props, text=True, check=True)

    def topics_ready():
        for t in ("app-logs", "platform-logs"):
            subprocess.run(
                ["docker", "exec", k, "/opt/kafka/bin/kafka-topics.sh", "--bootstrap-server", "kafka:9092",
                 "--command-config", "/tmp/client.properties", "--create", "--if-not-exists", "--topic", t,
                 "--partitions", "2", "--replication-factor", "1"],
                capture_output=True, text=True, check=True, timeout=60,
            )
        return True

    wait_for(topics_ready, 120, interval=3, what="kafka topics")
    return k


def _produce(kafka: str, topic: str, path: Path) -> None:
    subprocess.run(
        ["docker", "exec", "-i", kafka, "/opt/kafka/bin/kafka-console-producer.sh", "--bootstrap-server", "kafka:9092",
         "--producer.config", "/tmp/client.properties", "--topic", topic],
        input=path.read_text(), text=True, check=True, capture_output=True, timeout=60,
    )


def test_aggregator_forward_and_eventhub_kafka(stack, tmp_path):
    _, base = start_mock_intake(stack)
    conn = "Endpoint=sb://ehns-test.servicebus.windows.net/;SharedAccessKeyName=fluent-bit-listen;SharedAccessKey=dGVzdA=="
    kdir = tmp_path / "kafka"
    kdir.mkdir()
    kdir.chmod(0o755)
    kafka = _kafka(stack, conn, kdir)
    agg = stack.run(
        "aggregator", FLUENT_BIT_IMAGE,
        env=fluent_bit_env(
            EVENTHUB_BROKERS="kafka:9092",
            EVENTHUB_TOPICS="app-logs,platform-logs",
            EVENTHUB_CONSUMER_GROUP="fluent-bit",
            KAFKA_SECURITY_PROTOCOL="SASL_PLAINTEXT",  # Event Hubs: SASL_SSL (TLS) - only the local broker is plaintext
            EVENTHUB_CONNECTION_STRING=conn,
            FLB_DD_TAGS="env:test,collector:aggregator",
        ),
        volumes=[f"{FLB_CONFIG}:/fluent-bit/etc/eh:ro"],
        cmd=["-c", "/fluent-bit/etc/eh/aggregator.yaml"],
    )
    logdir = tmp_path / "applogs"
    logdir.mkdir()
    logdir.chmod(0o777)
    stack.run(
        "sidecarfwd", FLUENT_BIT_IMAGE,
        env=fluent_bit_env(LOG_FILE_PATH="/var/log/app/app.log", FLB_FORWARD_HOST="aggregator", FLB_FORWARD_PORT="24224"),
        volumes=[f"{FLB_CONFIG}:/fluent-bit/etc/eh:ro", f"{logdir}:/var/log/app"],
        cmd=["-c", "/fluent-bit/etc/eh/sidecar-forward.yaml"],
    )
    _write_log(logdir)
    _produce(kafka, "app-logs", SAMPLES / "eventhub-app-logs.jsonl")
    _produce(kafka, "platform-logs", SAMPLES / "eventhub-platform-logs.jsonl")

    expected = len(SIDECAR_IDS) + 3
    try:
        wait_for(lambda: len([e for e in received(base)["events"] if not _is_canary(e)]) >= expected, 120, interval=2,
                 what="aggregator events")
    finally:
        print(stack.logs(agg)[-3000:])
    time.sleep(5)
    got = received(base)
    _assert_canary(got["events"])
    events = [e for e in got["events"] if not _is_canary(e)]
    print(json.dumps(events, indent=1)[:8000])
    assert len(events) == expected, f"expected {expected} events, got {len(events)}"
    fwd = [e for e in events if (_event_id(e) or "") in SIDECAR_IDS]
    _assert_app_events(fwd)
    _requests_ok(got["requests"])

    ids = _by_id(events)
    # App Service console log carrying the app's JSON line: fields lifted, secret redacted, Azure tags
    a = ids["evt-0101"][0]
    assert a["service"] == "hello-inventory-api"
    assert a["message"].startswith("inventory reserved") and "tok-999" not in a["message"]
    assert a["trace_id"] == TRACE_ID
    assert a["ddsource"] == "azure.web"
    assert "category:AppServiceConsoleLogs" in a["ddtags"]
    assert "resource_id:/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/rg-apps/providers/microsoft.web/sites/app-inventory" in a["ddtags"]
    # plain console line keeps message, falls back to resource name as service
    b = ids["evt-0102"][0]
    assert b["message"] == "plain console line evt-0102" and b["service"] == "app-inventory"
    # platform log from the platform-logs hub
    c = ids["evt-0201"][0]
    assert c["ddsource"] == "azure.app" and "category:ContainerAppSystemLogs" in c["ddtags"]
    assert "eventhub:platform-logs" in c["ddtags"]
    assert all(PIPELINE_TAG in e["ddtags"].split(",") for e in events)


def test_linux_host_config_with_canary(stack, tmp_path):
    """linux-host.yaml (VM/VMSS service): tails the app log glob, emits the canary, tags the pipeline, and
    pushes its self-metrics over OTLP to the local Agent (stand-in collector) with _total names + env."""
    _, base = start_mock_intake(stack)
    out = tmp_path / "agentout"
    out.mkdir()
    out.chmod(0o777)
    stack.run("agent", "otel/opentelemetry-collector-contrib:0.162.0", user="0",
              volumes=[f"{HERE / 'otel'}:/test:ro", f"{out}:/out"], cmd=["--config=file:/test/agent-standin.yaml"])
    logdir = tmp_path / "hostlogs"
    logdir.mkdir()
    logdir.chmod(0o777)
    stack.run(
        "host", FLUENT_BIT_IMAGE,
        env=fluent_bit_env(FLB_LOG_PATHS="/var/log/enterprise-hello/*.log", HOSTNAME="vm-test",
                           FLB_METRICS_INTERVAL_SEC="2", FLB_OTLP_HOST="agent", FLB_ENV="test"),
        volumes=[f"{FLB_CONFIG}:/fluent-bit/etc/eh:ro", f"{logdir}:/var/log/enterprise-hello"],
        cmd=["-c", "/fluent-bit/etc/eh/linux-host.yaml"],
    )
    target = logdir / "hello-worker.log"
    target.touch()
    time.sleep(8)  # discovered first: hosts start tailing at the end (no re-shipping of history on install)
    with target.open("a") as fh:
        fh.write((SAMPLES / "app.log").read_text())
    wait_for(lambda: len([e for e in received(base)["events"] if not _is_canary(e)]) >= len(SIDECAR_IDS)
             and any(_is_canary(e) for e in received(base)["events"]), 60, what="host events + canary")
    print(json.dumps(received(base)["events"])[:3000])
    time.sleep(3)
    got = received(base)
    _assert_app_events(got["events"])
    _assert_canary(got["events"])
    assert all(e.get("log.file.path", "").startswith("/var/log/enterprise-hello/") for e in got["events"] if not _is_canary(e))

    def _metrics():
        f = out / "agent-metrics.json"
        if not f.exists():
            return None
        pts = {}
        for line in f.read_text().splitlines():
            for rm in json.loads(line).get("resourceMetrics", []):
                for sm in rm["scopeMetrics"]:
                    for m in sm["metrics"]:
                        for kind in ("sum", "gauge"):
                            for dp in m.get(kind, {}).get("dataPoints", []):
                                pts.setdefault(m["name"], []).append({a["key"]: next(iter(a["value"].values())) for a in dp.get("attributes", [])})
        return pts if "fluentbit_output_errors_total" in pts else None

    pts = wait_for(_metrics, 60, what="fluent-bit OTLP self-metrics")
    assert all(p.get("env") == "test" for p in pts["fluentbit_output_errors_total"]), pts["fluentbit_output_errors_total"][:2]
    assert "fluentbit_input_records_total" in pts
