"""TELEMETRY_SDK=otel|datadog switch (hello_common.apm + telemetry + logging + propagation).

ddtrace patches the interpreter globally, so every datadog-mode case runs in a fresh subprocess; the parent test
process stays in the default otel mode used by the rest of the suite.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import textwrap

import pytest

pytest.importorskip("ddtrace")
pytest.importorskip("datadog")

BASE_ENV = {
    "DD_ENV": "test",
    "DD_SERVICE": "hello-apm-test",
    "DD_VERSION": "9.9.9",
    # nothing listens there: the tracer/profiler drop payloads quietly
    "DD_TRACE_AGENT_URL": "http://127.0.0.1:9",
    "DD_INSTRUMENTATION_TELEMETRY_ENABLED": "false",
    "DD_REMOTE_CONFIGURATION_ENABLED": "false",
    "DD_TRACE_STARTUP_LOGS": "false",
    "LOG_LEVEL": "DEBUG",
}


def run(script: str, **env: str) -> dict:
    full_env = {k: v for k, v in os.environ.items() if not k.startswith(("DD_", "OTEL_", "TELEMETRY_SDK", "_DD_"))}
    full_env.update(BASE_ENV)
    full_env.update(env)
    proc = subprocess.run(
        [sys.executable, "-c", textwrap.dedent(script)],
        env=full_env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert proc.returncode == 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    result = [line for line in proc.stdout.splitlines() if line.startswith("RESULT ")]
    assert result, proc.stdout + proc.stderr
    doc = json.loads(result[-1][len("RESULT ") :])
    doc["_stdout"] = proc.stdout
    return doc


PROVIDERS = """
import json, sys
import hello_common
from hello_common.config import service_info
from hello_common.telemetry import setup_telemetry, otel_sdk_active
from hello_common.logging import configure_logging
from hello_common import apm
configure_logging(service_info("hello-apm-test"))
from opentelemetry import metrics, trace
import opentelemetry.sdk.trace as sdk_trace
import opentelemetry.sdk.metrics as sdk_metrics
setup_telemetry(service_info("hello-apm-test"))
out = {
    "mode": apm.telemetry_mode(),
    "status": {k: v for k, v in apm.status().items() if k != "bootstrapped"},
    "sdk_tracer_provider": isinstance(trace.get_tracer_provider(), sdk_trace.TracerProvider),
    "sdk_meter_provider": isinstance(metrics.get_meter_provider(), sdk_metrics.MeterProvider),
    "tracer_provider": type(trace.get_tracer_provider()).__module__,
    "otel_sdk_active": otel_sdk_active(),
    "ddtrace_loaded": "ddtrace.bootstrap.sitecustomize" in sys.modules,
    "fastapi_otel": "opentelemetry.instrumentation.fastapi" in sys.modules,
    "otlp_exporter": any(m.startswith("opentelemetry.exporter.otlp") for m in sys.modules),
}
print("RESULT " + json.dumps(out))
"""


def test_default_mode_is_otel_and_configures_sdk():
    doc = run(PROVIDERS, OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4317")
    assert doc["mode"] == "otel"
    assert doc["sdk_tracer_provider"] and doc["sdk_meter_provider"] and doc["otel_sdk_active"]
    assert doc["otlp_exporter"]
    assert not doc["ddtrace_loaded"]


def test_datadog_mode_creates_no_otel_provider_and_enables_ddtrace():
    doc = run(PROVIDERS, TELEMETRY_SDK="datadog", OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4317")
    assert doc["mode"] == "datadog"
    assert doc["status"]["tracer"] == "enabled"
    assert doc["ddtrace_loaded"]
    assert not doc["sdk_tracer_provider"] and not doc["sdk_meter_provider"] and not doc["otel_sdk_active"]
    assert not doc["otlp_exporter"], "no OTLP exporter may be imported in datadog mode"
    # DD_TRACE_OTEL_ENABLED defaults to true: the OTel API is served by ddtrace's provider
    assert doc["tracer_provider"].startswith("ddtrace.")
    assert "telemetry mode datadog" in doc["_stdout"]


def test_datadog_mode_trace_disabled_does_not_import_ddtrace():
    doc = run(PROVIDERS, TELEMETRY_SDK="datadog", DD_TRACE_ENABLED="false")
    assert doc["status"]["tracer"] == "disabled"
    assert not doc["ddtrace_loaded"]
    assert not doc["sdk_tracer_provider"]


def test_otel_sdk_disabled_creates_no_provider():
    doc = run(PROVIDERS, OTEL_SDK_DISABLED="true", OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4317")
    assert doc["mode"] == "otel"
    assert not doc["sdk_tracer_provider"] and not doc["sdk_meter_provider"] and not doc["otlp_exporter"]


def test_injected_tracer_is_detected_not_repatched():
    script = (
        "import ddtrace.auto\n"
        + PROVIDERS
        + "\nimport ddtrace\nprint('RESULT ' + json.dumps({**out, 'otel_patched': bool(getattr(trace, '_ddtrace_test', None))}))"
    )
    doc = run(script, TELEMETRY_SDK="datadog")
    assert doc["status"]["tracer"] == "injected"
    assert doc["status"]["source"] in ("external", "manual")
    assert not doc["sdk_tracer_provider"]


def test_injected_tracer_with_unset_mode_switches_to_datadog():
    doc = run("import ddtrace.auto\n" + PROVIDERS)
    assert doc["mode"] == "datadog"
    assert not doc["sdk_tracer_provider"]


def test_injected_tracer_with_explicit_otel_warns():
    doc = run("import ddtrace.auto\n" + PROVIDERS, TELEMETRY_SDK="otel")
    assert doc["mode"] == "otel"
    assert "two tracers" in doc["_stdout"]


def test_invalid_mode_is_reported():
    script = """
    import json
    from hello_common import apm
    try:
        apm.telemetry_mode()
        out = {"error": None}
    except apm.TelemetryModeError as exc:
        out = {"error": str(exc)}
    print("RESULT " + json.dumps(out))
    """
    assert "TELEMETRY_SDK must be one of" in run(script, TELEMETRY_SDK="dd")["error"]


LOGS = """
import io, json, logging
import hello_common
from hello_common.config import service_info
from hello_common.logging import JsonFormatter
from hello_common.telemetry import setup_telemetry
from opentelemetry import trace
import ddtrace
info = service_info("hello-apm-test")
setup_telemetry(info)
fmt = JsonFormatter(info)
def line(msg):
    rec = logging.getLogger("t").makeRecord("t", logging.INFO, "x.py", 1, msg, (), None)
    return json.loads(fmt.format(rec))
outside = line("outside")
with ddtrace.tracer.trace("dd.native") as span:
    native = line("native")
    native_ids = [format(span.trace_id, "032x"), format(span.span_id, "016x"), str(span.trace_id & 0xFFFFFFFFFFFFFFFF), str(span.span_id)]
with trace.get_tracer("t").start_as_current_span("otel.api") as s:
    via_otel = line("otel api")
    cur = ddtrace.tracer.current_span()
    otel_ids = None
    if cur is not None:
        otel_ids = [format(cur.trace_id, "032x"), format(cur.span_id, "016x"), str(cur.trace_id & 0xFFFFFFFFFFFFFFFF), str(cur.span_id)]
from hello_common.propagation import inject_current, current_trace_ids
with ddtrace.tracer.trace("prop") as p:
    carrier = inject_current()
    ids = current_trace_ids()
    prop_ids = [format(p.trace_id, "032x"), format(p.span_id, "016x")]
keys = ["trace_id", "span_id", "dd.trace_id", "dd.span_id"]
print("RESULT " + json.dumps({
    "outside": {k: outside.get(k) for k in keys},
    "native": [native.get(k) for k in keys], "native_ids": native_ids,
    "via_otel": [via_otel.get(k) for k in keys], "otel_ids": otel_ids,
    "dd_service": native.get("dd.service"),
    "carrier": carrier, "ids": ids, "prop_ids": prop_ids,
}))
"""


@pytest.mark.parametrize("otel_api", ["true", "false"])
def test_datadog_mode_log_correlation_from_ddtrace_span(otel_api):
    doc = run(LOGS, TELEMETRY_SDK="datadog", DD_TRACE_OTEL_ENABLED=otel_api)
    assert doc["outside"] == dict.fromkeys(["trace_id", "span_id", "dd.trace_id", "dd.span_id"]), "no span -> fields omitted"
    assert doc["native"] == doc["native_ids"]
    assert len(doc["native"][0]) == 32 and len(doc["native"][1]) == 16
    assert doc["dd_service"] == "hello-apm-test"
    if otel_api == "true":
        assert doc["via_otel"] == doc["otel_ids"], "OTel API spans are ddtrace spans"
    else:
        assert doc["otel_ids"] is None and doc["via_otel"] == [None] * 4, "OTel API is a no-op without DD_TRACE_OTEL_ENABLED"
    # traceparent out (response header / message properties) from the active ddtrace span either way
    assert doc["carrier"]["traceparent"].split("-")[1:3] == doc["prop_ids"]
    assert doc["ids"] == doc["prop_ids"]


APP = """
import json, logging
import hello_common
from hello_common.app import create_app
from hello_common.config import service_info
from fastapi.testclient import TestClient
from ddtrace.trace import tracer, TraceFilter
from hello_common.apm import install_probe_filter
from hello_common.telemetry import PROBE_PATHS
from opentelemetry import trace
from hello_common.propagation import links_from_properties
captured = []
class Capture(TraceFilter):
    def process_trace(self, t):
        captured.append([{"name": s.name, "resource": s.resource, "links": len(s._get_links() or [])} for s in t])
        return t
app = create_app(service_info("hello-apm-test"))
# keep the probe filter installed by setup_telemetry and append a capturing processor after it
from hello_common import apm
apm.add_trace_processor(Capture())
@app.get("/hello")
def hello():
    logging.getLogger("hello").info("inside handler")
    producer = {"traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"}
    with trace.get_tracer("t").start_as_current_span("servicebus.process", links=links_from_properties(producer)):
        pass
    return {"ok": True}
c = TestClient(app)
r1 = c.get("/healthz")
r2 = c.get("/hello", headers={"traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"})
tracer.flush()
import sys
print("RESULT " + json.dumps({
    "captured": captured, "traceparent": r2.headers.get("traceparent"), "status": [r1.status_code, r2.status_code],
    "fastapi_otel": "opentelemetry.instrumentation.fastapi" in sys.modules,
}))
"""


def test_datadog_mode_fastapi_traced_by_ddtrace_probes_dropped():
    # the TestClient talks httpx: keep ddtrace off that client so the inbound traceparent reaches the server as sent
    doc = run(APP, TELEMETRY_SDK="datadog", DD_TRACE_HTTPX_ENABLED="false")
    assert doc["status"] == [200, 200]
    assert not doc["fastapi_otel"], "OTel FastAPI instrumentation must not be installed in datadog mode"
    names = [[s["name"] for s in t] for t in doc["captured"]]
    flat = [n for t in names for n in t]
    assert "fastapi.request" in flat
    # ddtrace maps an OTel API span to operation name = span kind and resource = the OTel span name
    assert "servicebus.process" in [s["resource"] for t in doc["captured"] for s in t], "OTel API span recorded by ddtrace"
    resources = [s["resource"] for t in doc["captured"] for s in t]
    assert not any("healthz" in (r or "") for r in resources), "health probes dropped by the probe filter"
    links = [s["links"] for t in doc["captured"] for s in t if s["resource"] == "servicebus.process"]
    assert links and links[0] >= 1, "span link to the producer context kept"
    # inbound W3C context continued, traceparent echoed on the response
    assert doc["traceparent"].split("-")[1] == "4bf92f3577b34da6a3ce929d0e0e4736"
    # inside-handler log line carries the same trace id
    lines = [json.loads(x) for x in doc["_stdout"].splitlines() if x.startswith("{") and '"inside handler"' in x]
    assert lines and lines[0]["trace_id"] == "4bf92f3577b34da6a3ce929d0e0e4736"
    assert lines[0]["dd.trace_id"] == str(int("4bf92f3577b34da6a3ce929d0e0e4736", 16) & 0xFFFFFFFFFFFFFFFF)


METRICS = """
import json, socket, time
import hello_common
from hello_common.config import service_info
from hello_common.telemetry import meter, setup_telemetry, shutdown_telemetry
setup_telemetry(service_info("hello-apm-test"))
m = meter("t")
c = m.create_counter("hello.workflow.completed", unit="{workflow}")
h = m.create_histogram("hello.workflow.duration", unit="ms")
g = m.create_gauge("hello.test.gauge")
c.add(1, {"outcome": "succeeded", "order_id": "ORD-123", "customer_ref": "c-1"})
c.add(2, {"outcome": "succeeded"})
h.record(125.5, {"outcome": "succeeded", "user_id": "u-1"})
g.set(7, {"status": "ok"})
shutdown_telemetry()
print("RESULT " + json.dumps({"ok": True}))
"""


def _udp_listener() -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    sock.settimeout(0.5)
    return sock


def _drain(sock: socket.socket) -> list[str]:
    lines: list[str] = []
    while True:
        try:
            data, _ = sock.recvfrom(65535)
        except TimeoutError:
            return lines
        lines.extend(x for x in data.decode().split("\n") if x)


def test_datadog_mode_metrics_go_to_dogstatsd_with_bounded_tags():
    sock = _udp_listener()
    try:
        port = sock.getsockname()[1]
        run(METRICS, TELEMETRY_SDK="datadog", DD_DOGSTATSD_URL=f"udp://127.0.0.1:{port}")
        lines = _drain(sock)
    finally:
        sock.close()
    joined = "\n".join(lines)
    counts = [x for x in lines if x.startswith("hello.workflow.completed:")]
    assert counts, joined
    assert sum(int(x.split(":")[1].split("|")[0]) for x in counts) == 3, joined
    assert all("|c" in x for x in counts)
    dist = [x for x in lines if x.startswith("hello.workflow.duration:")]
    assert dist and "|d" in dist[0] and "125.5" in dist[0]
    assert any(x.startswith("hello.test.gauge:7|g") for x in lines), joined
    for x in counts + dist:
        assert "outcome:succeeded" in x
        assert "env:test" in x and "service:hello-apm-test" in x and "version:9.9.9" in x
    assert "ORD-123" not in joined and "order_id" not in joined and "user_id" not in joined and "customer_ref" not in joined


def test_otel_mode_metrics_never_touch_dogstatsd():
    sock = _udp_listener()
    try:
        port = sock.getsockname()[1]
        run(METRICS, DD_DOGSTATSD_URL=f"udp://127.0.0.1:{port}")
        lines = _drain(sock)
    finally:
        sock.close()
    assert lines == []


def test_datadog_metrics_otel_bridge_keeps_otel_api():
    sock = _udp_listener()
    try:
        port = sock.getsockname()[1]
        run(
            METRICS,
            TELEMETRY_SDK="datadog",
            DD_METRICS_OTEL_ENABLED="true",
            DD_DOGSTATSD_URL=f"udp://127.0.0.1:{port}",
            OTEL_EXPORTER_OTLP_METRICS_ENDPOINT="http://127.0.0.1:9",
        )
        lines = [x for x in _drain(sock) if x.startswith("hello.")]
    finally:
        sock.close()
    assert lines == [], "DD_METRICS_OTEL_ENABLED=true routes hello.* through ddtrace's OTel MeterProvider, not DogStatsD"


def test_otel_mode_attribute_filter_on_facade():
    from hello_common.telemetry import bounded_attributes

    assert bounded_attributes({"outcome": "ok", "order_id": "x", "status": None}) == {"outcome": "ok"}


PROFILER = """
import json, sys, time
import hello_common
from hello_common import apm
from hello_common.config import service_info
from hello_common.telemetry import setup_telemetry
from hello_common.logging import configure_logging
configure_logging(service_info("hello-apm-test"))
setup_telemetry(service_info("hello-apm-test"))
ddtrace_loaded = "ddtrace" in sys.modules
running = False
try:
    from ddtrace.profiling import bootstrap
    prof = getattr(bootstrap, "profiler", None)
    running = prof is not None and getattr(prof, "status", None) is not None and str(prof.status).lower().endswith("running")
except ImportError:
    pass
print("RESULT " + json.dumps({"status": apm.status()["profiler"], "tracer": apm.status()["tracer"], "running": running,
                              "profiling_loaded": "ddtrace.profiling.profiler" in sys.modules,
                              "ddtrace_loaded": ddtrace_loaded}))
"""


def test_profiler_started_with_tracer_in_datadog_mode():
    doc = run(PROFILER, TELEMETRY_SDK="datadog", DD_PROFILING_ENABLED="true", DD_PROFILING_UPLOAD_INTERVAL="60")
    assert doc["tracer"] == "enabled" and doc["status"] == "enabled"
    assert doc["profiling_loaded"] and doc["running"]


def test_profiler_alone_when_tracing_disabled():
    doc = run(PROFILER, TELEMETRY_SDK="datadog", DD_TRACE_ENABLED="false", DD_PROFILING_ENABLED="true")
    assert doc["tracer"] == "disabled" and doc["status"] == "enabled"
    assert doc["profiling_loaded"] and doc["running"]


def test_profiler_ignored_in_otel_mode():
    doc = run(PROFILER, DD_PROFILING_ENABLED="true")
    assert doc["status"] == "ignored-in-otel-mode"
    assert not doc["ddtrace_loaded"]
    assert "DD_PROFILING_ENABLED is ignored" in doc["_stdout"]
