"""Local (docker) test of config/otel/gateway.yaml: OTLP gRPC + HTTP in, processors, Datadog exporter out.

The real `datadog` exporter is kept and pointed at the mock intake (traces/metrics endpoints overridden by
otel/test-overlay.yaml); a file exporter is added alongside to assert the resource-attribute mapping.
Runs against the upstream contrib image and the DDOT collector image (gateway_distribution = upstream|ddot).
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import time

import pytest

from dockerutil import HERE, OTEL_CONFIG, OTELCOL_IMAGE, Stack, http_status, received, start_mock_intake, wait_for

DDOT_IMAGE = "datadog/ddot-collector:7.84.2"
pytestmark = pytest.mark.skipif(shutil.which("docker") is None, reason="docker not available")


def _read_json_lines(path):
    if not path.exists():
        return []
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


def _resource_attrs(batches, kind):
    out = []
    for b in batches:
        for rs in b.get(kind, []):
            out.append({a["key"]: next(iter(a["value"].values())) for a in rs["resource"].get("attributes", [])})
    return out


def _span_names(batches):
    return [s["name"] for b in batches for rs in b.get("resourceSpans", []) for ss in rs["scopeSpans"] for s in ss["spans"]]


def _run_gateway(stack, image, outdir, extra_configs=(), extra_env=None, entry_cmd=None):
    outdir.mkdir(parents=True, exist_ok=True)
    outdir.chmod(0o777)
    cfgs = ["--config=file:/cfg/gateway.yaml", *extra_configs, "--config=file:/test/test-overlay.yaml"]
    env = {"DD_API_KEY": "test-not-a-real-key", "DD_SITE": "datadoghq.com", "DD_ENV": "fallback-env",
           "TRACE_SAMPLING_PERCENTAGE": "100", "GATEWAY_MEMORY_LIMIT_MIB": "400", "GATEWAY_MEMORY_SPIKE_MIB": "100"}
    env.update(extra_env or {})
    cmd = (entry_cmd or []) + cfgs
    c = stack.run("gateway", image, env=env,
                  volumes=[f"{OTEL_CONFIG}:/cfg:ro", f"{HERE / 'otel'}:/test:ro", f"{outdir}:/out"],
                  ports=["127.0.0.1::4317", "127.0.0.1::4318", "127.0.0.1::13133"], user="0", cmd=cmd)
    hc = f"http://127.0.0.1:{stack.host_port(c, 13133)}/"
    try:
        wait_for(lambda: http_status(hc, timeout=2) == 200, 60, what="collector health_check")
    except TimeoutError:
        print(stack.logs(c)[-5000:])
        raise
    return c, stack.host_port(c, 4317), stack.host_port(c, 4318)


def _send(grpc_port, http_port, token=None):
    args = [sys.executable, str(HERE / "otel" / "send_spans.py"), f"http://127.0.0.1:{grpc_port}", f"http://127.0.0.1:{http_port}"]
    if token:
        args.append(token)
    return subprocess.run(args, capture_output=True, text=True, timeout=60)


@pytest.mark.parametrize("image,entry", [(OTELCOL_IMAGE, []), (DDOT_IMAGE, ["run"])], ids=["upstream", "ddot"])
def test_gateway_pipeline(tmp_path, image, entry):
    stack = Stack("otel")
    try:
        _, base = start_mock_intake(stack)
        # DDOT standalone resolves a hostname at start-up; the module sets DD_HOSTNAME to the gateway app name
        extra = {"DD_HOSTNAME": "otel-gateway-test"} if image == DDOT_IMAGE else None
        gw, gport, hport = _run_gateway(stack, image, tmp_path / "out", entry_cmd=entry, extra_env=extra)
        res = _send(gport, hport)
        assert res.returncode == 0, res.stderr
        wait_for(lambda: len(_span_names(_read_json_lines(tmp_path / "out" / "traces.json"))) >= 4, 60, what="spans in file exporter")
        wait_for(lambda: any(o["path"].startswith("/api/v0.2/traces") for o in received(base)["others"]), 60,
                 what="datadog exporter trace payload at mock intake")
        time.sleep(3)
        traces = _read_json_lines(tmp_path / "out" / "traces.json")
        names = _span_names(traces)
        assert sorted(names) == sorted(["POST /orders", "INSERT orders.orders", "GET /orders/{id}", "GET /products"])
        attrs = _resource_attrs(traces, "resourceSpans")
        orders = [a for a in attrs if a.get("service.name") == "hello-orders-api"][0]
        # legacy deployment.environment mapped to deployment.environment.name (-> Datadog env)
        assert orders["deployment.environment.name"] == "test"
        assert orders["service.version"] == "1.4.2"
        assert orders["team"] == "observability"
        assert "process.command_line" not in orders  # secrets in command lines dropped
        catalog = [a for a in attrs if a.get("service.name") == "hello-catalog-api"][0]
        assert catalog["deployment.environment"] == "test" and catalog["service.version"] == "unknown"
        others = received(base)["others"]
        print(json.dumps(others, indent=1)[:3000])
        assert all(o["api_key_present"] for o in others)
        # APM stats from the datadog connector (computed pre-sampling) are exported too
        wait_for(lambda: any("stats" in o["path"] for o in received(base)["others"]), 60, what="APM stats payload")
        # OTLP metrics reached the metrics pipeline
        wait_for(lambda: any(
            m.get("name") == "orders.created"
            for b in _read_json_lines(tmp_path / "out" / "metrics.json")
            for rm in b.get("resourceMetrics", []) for sm in rm["scopeMetrics"] for m in sm["metrics"]), 60, what="metric")
    finally:
        print(stack.logs(f"{stack.id}-gateway")[-3000:])
        stack.close()


def test_gateway_bearer_token_auth(tmp_path):
    stack = Stack("otelauth")
    try:
        start_mock_intake(stack)
        _, gport, hport = _run_gateway(stack, OTELCOL_IMAGE, tmp_path / "out",
                                       extra_configs=["--config=file:/cfg/gateway-auth.yaml"],
                                       extra_env={"OTLP_BEARER_TOKEN": "test-token-123"})
        bad = _send(gport, hport, token="wrong-token")
        time.sleep(2)
        assert _span_names(_read_json_lines(tmp_path / "out" / "traces.json")) == []
        assert "401" in bad.stderr or "Unauthenticated" in bad.stderr or "UNAUTHENTICATED" in bad.stderr or bad.stderr
        ok = _send(gport, hport, token="test-token-123")
        assert ok.returncode == 0, ok.stderr
        wait_for(lambda: len(_span_names(_read_json_lines(tmp_path / "out" / "traces.json"))) >= 4, 60, what="authorised spans")
    finally:
        stack.close()


def test_gateway_overlays_validate():
    res = subprocess.run(
        ["docker", "run", "--rm", "-e", "DD_API_KEY=x", "-e", "OTLP_BEARER_TOKEN=t", "-e", "FLUENTBIT_METRICS_TARGET=fb:2020",
         "-v", f"{OTEL_CONFIG}:/c:ro", OTELCOL_IMAGE, "validate", "--config=file:/c/gateway.yaml",
         "--config=file:/c/gateway-auth.yaml", "--config=file:/c/gateway-tail-sampling.yaml",
         "--config=file:/c/gateway-scrape-fluentbit.yaml"],
        capture_output=True, text=True, timeout=120)
    assert res.returncode == 0, res.stderr
