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

import hashlib

from dockerutil import HERE, OTEL_CONFIG, OTELCOL_IMAGE, Stack, dsv_fetch_init, http_status, received, start_mock_intake, wait_for

GATEWAY_KEY = "test-not-a-real-key"

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


def _run_gateway(stack, image, outdir, extra_configs=(), extra_env=None, entry_cmd=None, overlay="test-overlay.yaml",
                 secrets=None):
    outdir.mkdir(parents=True, exist_ok=True)
    outdir.chmod(0o777)
    # the gateway reads its secrets as FILES (${file:/dsv-secrets/<name>}) written by the dsv-fetch image from the
    # (mock) DSV - same command line as the ACA init container (files, 0444)
    sec = dsv_fetch_init(outdir.parent / f"dsv-{outdir.name}", {"dd-api-key": GATEWAY_KEY, **(secrets or {})},
                         fmt="files", extra=["--file-mode", "0444"])
    cfgs = ["--config=file:/cfg/gateway.yaml", *extra_configs, f"--config=file:/test/{overlay}"]
    env = {"DD_SITE": "datadoghq.com", "DD_ENV": "fallback-env",
           "TRACE_SAMPLING_PERCENTAGE": "100", "GATEWAY_MEMORY_LIMIT_MIB": "400", "GATEWAY_MEMORY_SPIKE_MIB": "100"}
    env.update(extra_env or {})
    cmd = (entry_cmd or []) + cfgs
    c = stack.run("gateway", image, env=env,
                  volumes=[f"{OTEL_CONFIG}:/cfg:ro", f"{HERE / 'otel'}:/test:ro", f"{outdir}:/out", f"{sec}:/dsv-secrets:ro"],
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


def test_gateway_pipeline_upstream(tmp_path):
    stack = Stack("otel")
    try:
        _, base = start_mock_intake(stack)
        _, gport, hport = _run_gateway(stack, OTELCOL_IMAGE, tmp_path / "out")
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
        # the exporter used the key from the dsv-fetch file (DSV value), not an env var
        assert all(o["api_key_sha256"] == hashlib.sha256(GATEWAY_KEY.encode()).hexdigest() for o in others)
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


def test_gateway_pipeline_ddot(tmp_path):
    stack = Stack("ddot")
    try:
        _, base = start_mock_intake(stack)
        # DDOT standalone resolves a hostname at start-up; the module sets DD_HOSTNAME to the gateway app name
        gw, gport, hport = _run_gateway(stack, DDOT_IMAGE, tmp_path / "out", entry_cmd=["run"],
                                        extra_env={"DD_HOSTNAME": "otel-gateway-test"}, overlay="test-overlay-ddot.yaml")
        res = _send(gport, hport)
        assert res.returncode == 0, res.stderr
        wait_for(lambda: any(o["path"].startswith("/api/v0.2/traces") for o in received(base)["others"]), 90,
                 what="datadog exporter trace payload at mock intake")
        wait_for(lambda: any("stats" in o["path"] for o in received(base)["others"]), 60, what="APM stats payload")
        def _debug_logs():
            text = stack.logs(gw)
            return text if "INSERT orders.orders" in text else None

        logs = wait_for(_debug_logs, 30, what="debug exporter output")
        assert "deployment.environment.name: Str(test)" in logs
        assert "process.command_line" not in logs
    finally:
        stack.close()


def test_gateway_bearer_token_auth(tmp_path):
    stack = Stack("otelauth")
    try:
        start_mock_intake(stack)
        _, gport, hport = _run_gateway(stack, OTELCOL_IMAGE, tmp_path / "out",
                                       extra_configs=["--config=file:/cfg/gateway-auth.yaml"],
                                       secrets={"otlp-bearer-token": "test-token-123"})
        bad = _send(gport, hport, token="wrong-token")
        time.sleep(2)
        assert _span_names(_read_json_lines(tmp_path / "out" / "traces.json")) == []
        assert "401" in bad.stderr or "Unauthenticated" in bad.stderr or "UNAUTHENTICATED" in bad.stderr or bad.stderr
        ok = _send(gport, hport, token="test-token-123")
        assert ok.returncode == 0, ok.stderr
        wait_for(lambda: len(_span_names(_read_json_lines(tmp_path / "out" / "traces.json"))) >= 4, 60, what="authorised spans")
    finally:
        stack.close()


def test_gateway_overlays_validate(tmp_path):
    sec = dsv_fetch_init(tmp_path / "dsv", {"dd-api-key": "x", "otlp-bearer-token": "t"}, fmt="files", extra=["--file-mode", "0444"])
    res = subprocess.run(
        ["docker", "run", "--rm", "-e", "FLUENTBIT_METRICS_TARGET=fb:2020",
         "-v", f"{OTEL_CONFIG}:/c:ro", "-v", f"{sec}:/dsv-secrets:ro", OTELCOL_IMAGE, "validate", "--config=file:/c/gateway.yaml",
         "--config=file:/c/gateway-auth.yaml", "--config=file:/c/gateway-tail-sampling.yaml",
         "--config=file:/c/gateway-scrape-fluentbit.yaml"],
        capture_output=True, text=True, timeout=120)
    assert res.returncode == 0, res.stderr


def _send_logs(grpc_port, http_port):
    return subprocess.run([sys.executable, str(HERE / "otel" / "send_logs.py"), f"http://127.0.0.1:{grpc_port}",
                           f"http://127.0.0.1:{http_port}"], capture_output=True, text=True, timeout=60)


def test_gateway_accepts_and_drops_otlp_logs_by_default(tmp_path):
    """Functions host exports host/worker logs over OTLP: accepted (no client errors) but never forwarded."""
    stack = Stack("otellogs")
    try:
        _, base = start_mock_intake(stack)
        gw, gport, hport = _run_gateway(stack, OTELCOL_IMAGE, tmp_path / "out",
                                        extra_configs=["--config=file:/test/test-overlay-logs.yaml"])
        res = _send_logs(gport, hport)
        print(res.stdout, res.stderr)
        assert res.returncode == 0, "gateway must accept OTLP logs (gRPC + HTTP) without errors"
        time.sleep(8)
        got = received(base)
        assert got["events"] == [] and not any(o["path"].startswith("/api/v2/logs") for o in got["others"])
        assert "otlp-log-" not in stack.logs(gw)
    finally:
        stack.close()


def test_gateway_logs_forward_overlay_is_opt_in(tmp_path):
    stack = Stack("otellogsfwd")
    try:
        _, base = start_mock_intake(stack)
        _, gport, hport = _run_gateway(stack, OTELCOL_IMAGE, tmp_path / "out",
                                       extra_configs=["--config=file:/cfg/gateway-logs-forward.yaml",
                                                      "--config=file:/test/test-overlay-logs.yaml"])
        res = _send_logs(gport, hport)
        assert res.returncode == 0, res.stderr
        def _forwarded():
            r = received(base)
            return r if any("otlp-log-" in json.dumps(e) for e in r["events"]) else None

        got = wait_for(_forwarded, 60, what="forwarded OTLP logs")
        print(json.dumps(got["events"])[:1500])
        assert any("otlp-log-" in json.dumps(e) for e in got["events"])
    finally:
        stack.close()


def _metric_points(batches):
    out = {}
    for b in batches:
        for rm in b.get("resourceMetrics", []):
            for sm in rm["scopeMetrics"]:
                for m in sm["metrics"]:
                    for kind in ("sum", "gauge", "histogram", "summary"):
                        for dp in m.get(kind, {}).get("dataPoints", []):
                            attrs = {a["key"]: next(iter(a["value"].values())) for a in dp.get("attributes", [])}
                            out.setdefault(m["name"], []).append(attrs)
    return out


def test_gateway_self_and_fluentbit_metrics_naming(tmp_path):
    """Self-telemetry names without type suffix (otelcol_exporter_send_failed_spans), Fluent Bit names keep
    _total (fluentbit_output_errors_total); every scraped point carries env."""
    from dockerutil import FLB_CONFIG, FLUENT_BIT_IMAGE, fluent_bit_env, fluent_bit_secrets

    stack = Stack("otelmetrics")
    try:
        start_mock_intake(stack)
        logs = tmp_path / "fb"
        logs.mkdir()
        logs.chmod(0o777)
        stack.run("fluentbit", FLUENT_BIT_IMAGE, env=fluent_bit_env(LOG_FILE_PATH="/var/log/app/app.log"),
                  volumes=[f"{FLB_CONFIG}:/fluent-bit/etc/eh:ro", f"{logs}:/var/log/app", fluent_bit_secrets(tmp_path)],
                  cmd=["-c", "/fluent-bit/etc/eh/sidecar.yaml"])
        _, gport, hport = _run_gateway(stack, OTELCOL_IMAGE, tmp_path / "out",
                                       extra_configs=["--config=file:/cfg/gateway-scrape-fluentbit.yaml"],
                                       extra_env={"FLUENTBIT_METRICS_TARGET": "fluentbit:2020", "SELF_SCRAPE_INTERVAL": "5s", "DD_ENV": "test"},
                                       overlay="test-overlay-fail.yaml")
        _send(gport, hport)  # trace export to the unreachable endpoint fails -> send_failed_spans

        def _names():
            pts = _metric_points(_read_json_lines(tmp_path / "out" / "metrics.json"))
            return pts if ("fluentbit_output_errors_total" in pts and "otelcol_exporter_send_failed_spans" in pts) else None

        pts = wait_for(_names, 90, 3, "self + fluent-bit metrics")
        print(sorted(pts)[:80])
        assert not any(n.startswith("otelcol_") and n.endswith("_total") for n in pts)
        for name in ("fluentbit_output_errors_total", "fluentbit_output_proc_records_total", "otelcol_exporter_send_failed_spans"):
            assert pts[name] and all(p.get("env") == "test" for p in pts[name]), (name, pts[name][:3])
    finally:
        stack.close()
