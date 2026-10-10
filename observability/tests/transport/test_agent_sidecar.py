"""Local (docker) proof of the observability 4.0.0 managed-runtime sidecars rendered by modules/instrumentation.
Synthetic data only; no Azure, no Datadog org.

* test_aci_agent_sidecar: the ACI Datadog Agent sidecar (Agent 7.84.2) runs the RENDERED datadog.yaml, log config and
  start command of `aci_sidecar`: the init container step installs the dsv-fetch static binary into the dsv-bin
  volume, the Agent re-installs it root-owned 0500 and resolves api_key ENC[dsv://...] through `dsv-fetch
  agent-backend` from a mock Delinea DSV. An "app" container sharing the group's network namespace sends a trace to
  localhost:8126, a DogStatsD metric to localhost:8125 and JSON lines to the shared log file: the trace and the metric
  reach the mock Datadog intake with the DSV key (sha256 compared), the log lines reach an Observability Pipelines
  Worker stand-in (Vector `datadog_agent` source - the source type behind the Worker's Datadog Agent source).
* test_aca_serverless_init_sidecar: the Container Apps serverless-init 1.10.4 sidecar runs the RENDERED command: the
  dsv-fetch binary writes DD_API_KEY from the mock DSV into the sidecar's own /tmp, the shell sources and truncates it
  and execs /datadog-init; serverless-init tails DD_SERVERLESS_LOG_PATH (shared volume) and ships to the Worker stand-in
  via DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_*, and forwards traces with the DSV key.

Deviations from Azure (test only, documented): DSV auth uses client_credentials against the mock (Azure uses the group
/ replica managed identity via IMDS / IDENTITY_ENDPOINT), plain-HTTP intake and DSV (DSV_ALLOW_INSECURE_HTTP), Remote
Configuration off (needs a Datadog backend), DD_DD_URL / DD_APM_DD_URL point at the mock intake.

dsv-fetch binary: DSV_FETCH_BIN (a static linux binary), else /opt/dsv-fetch/dsv-fetch from DSV_FETCH_IMAGE (the
2.0.0 image - then the init container step runs that image exactly like ACI / Container Apps), else built from
observability/images/dsv-fetch with a local Go toolchain; skipped when none is available.
Requires docker and terraform (TERRAFORM_BIN to override).
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest
import yaml

from dockerutil import DSV_FETCH_IMAGE, DSV_FETCH_SRC, PACKAGE, PYTHON_IMAGE, REPO, Stack, sh, wait_for

pytestmark = pytest.mark.skipif(shutil.which("docker") is None, reason="docker not available")

AGENT_IMAGE = "datadog/agent:7.84.2"                  # same build as the fleet pin gcr.io/datadoghq/agent:7.84.2
SI_IMAGE = "datadog/serverless-init:1.10.4"           # fleet pin agent.serverless_init
VECTOR_IMAGE = "timberio/vector:0.58.0-debian"        # Worker stand-in (Datadog Agent source engine)
API_KEY = "0123456789abcdef0123456789abcdef"          # synthetic, stored only in the mock DSV
KEY_REF = "dsv://eh/test/datadog-api-key#value"
SHA = hashlib.sha256(API_KEY.encode()).hexdigest()
DSV_TEST_ENV = {
    "DSV_AUTH": "client_credentials", "DSV_CLIENT_ID": "sidecar-test", "DSV_CLIENT_SECRET": "sidecar-test-secret",
    "DSV_BASE_URL": "http://dsv:8200/v1", "DSV_ALLOW_INSECURE_HTTP": "true",
}
VECTOR_CFG = """sources:
  agent:
    type: datadog_agent
    address: 0.0.0.0:8282
    multiple_outputs: true
sinks:
  out:
    type: console
    inputs: [agent.logs]
    encoding: {codec: json}
"""
# the "application": one trace (v0.4 JSON), one DogStatsD counter, JSON log lines to LOG_FILE_PATH
APP = r"""
import json, os, socket, sys, time, urllib.request
path = os.environ["LOG_FILE_PATH"]
for i in range(60):
    try:
        now = time.time_ns()
        span = {"trace_id": 4242 + i, "span_id": 7 + i, "parent_id": 0, "name": "web.request", "resource": "GET /payments",
                "service": os.environ["DD_SERVICE"], "type": "web", "start": now, "duration": 2000000,
                "meta": {"env": os.environ["DD_ENV"]}, "metrics": {"_sampling_priority_v1": 2}}
        req = urllib.request.Request("http://127.0.0.1:8126/v0.4/traces", data=json.dumps([[span]]).encode(), method="PUT",
                                     headers={"Content-Type": "application/json", "X-Datadog-Trace-Count": "1"})
        urllib.request.urlopen(req, timeout=3).read()
        socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"hello.payments.processed:1|c|#outcome:ok", ("127.0.0.1", 8125))
        with open(path, "a") as fh:
            fh.write(json.dumps({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "level": "INFO",
                                 "message": f"payment accepted {i}", "service": os.environ["DD_SERVICE"]}) + "\n")
    except Exception as exc:  # sidecar not up yet
        print("retry", exc, file=sys.stderr)
    time.sleep(2)
"""


def _render(tmp: Path, architecture: str, runtime: str) -> dict:
    tf = os.environ.get("TERRAFORM_BIN", "terraform")
    mod = PACKAGE / "modules" / "instrumentation"
    tfvars = {
        "service": {"service": "hello-partner-sim", "env": "test", "version": "1.0.0", "team": "payments", "domain": "payments",
                    "tier": "backend", "owner": "payments-team@example.com", "region": "swedencentral", "application": "enterprise-hello"},
        "runtime": runtime,
        "architecture": architecture,
        "apm": {"mode": "datadog"},
        "identity_client_id": "00000000-0000-0000-0000-00000000c0de",
        "telemetry": {
            "datadog_site": "datadoghq.com",
            "api_key_ref": KEY_REF,
            "secrets": {"base_url": "http://dsv:8200/v1", "fetch_image": DSV_FETCH_IMAGE},
            "otlp": {"grpc_endpoint": "http://gw:4317", "http_endpoint": "http://gw:4318"},
            "fluentbit": {"forward_host": "opw", "forward_port": 24224},
            "aggregator": {"kind": "observability_pipelines", "agent_logs_url": "http://opw:8282"},
            "env": {"fleet": {"EH_LOG_PIPELINE": "observability_pipelines", "EH_APM_MODE": "datadog"}},
        },
    }
    vf = tmp / f"{architecture}.tfvars.json"
    vf.write_text(json.dumps(tfvars))
    subprocess.run([tf, "init", "-backend=false", "-input=false"], cwd=mod, check=True, capture_output=True)
    expr = "jsonencode({env = local.env, aci = local.aci_sidecar, aca = local.container_app_patch, files = local.uses_agent_sidecar ? {datadog = local.agent_datadog_yaml, logs = local.agent_logs_conf, dsv = local.agent_dsv_json, start = local.agent_start, env = local.agent_env} : null})"
    out = subprocess.run([tf, "console", "-no-color", f"-var-file={vf}"], cwd=mod, input=expr, capture_output=True, text=True, check=True).stdout.strip()
    return json.loads(json.loads(out.splitlines()[-1]))


def _binary(tmp: Path) -> tuple[Path, bool]:
    """(path to a static dsv-fetch binary, True when DSV_FETCH_IMAGE carries it - the init step then runs the image)."""
    if os.environ.get("DSV_FETCH_BIN"):
        return Path(os.environ["DSV_FETCH_BIN"]), False
    dest = tmp / "dsv-fetch-bin"
    if subprocess.run(["docker", "image", "inspect", DSV_FETCH_IMAGE], capture_output=True).returncode == 0:
        cid = sh("docker", "create", DSV_FETCH_IMAGE).strip()
        try:
            if subprocess.run(["docker", "cp", f"{cid}:/opt/dsv-fetch/dsv-fetch", str(dest)], capture_output=True).returncode == 0:
                return dest, True
        finally:
            sh("docker", "rm", "-f", cid, check=False)
    go = shutil.which("go") or ("/usr/local/go/bin/go" if Path("/usr/local/go/bin/go").exists() else None)
    if go and (DSV_FETCH_SRC / "build.sh").exists():
        env = dict(os.environ, PATH=f"{Path(go).parent}:{os.environ.get('PATH', '')}")
        res = subprocess.run(["bash", str(DSV_FETCH_SRC / "build.sh"), "--toolchain", "local", "--target", "linux/amd64", "--binary", str(dest)],
                             capture_output=True, text=True, env=env)
        if res.returncode == 0:
            return dest, False
    pytest.skip("no dsv-fetch static binary (set DSV_FETCH_BIN, or DSV_FETCH_IMAGE with /opt/dsv-fetch/dsv-fetch, or install Go)")


def _install_binary(tmp: Path, bin_dir: Path) -> None:
    """The dsv-fetch-install init container: `dsv-fetch install --dest <dsv-bin>/dsv-fetch` (as uid 65532)."""
    binary, from_image = _binary(tmp)
    bin_dir.mkdir(parents=True, exist_ok=True)
    bin_dir.chmod(0o777)
    if from_image:
        sh("docker", "run", "--rm", "--read-only", "-v", f"{bin_dir}:/eh/dsv-bin", DSV_FETCH_IMAGE, "install", "--dest", "/eh/dsv-bin/dsv-fetch")
    else:
        stage = tmp / "stage"
        stage.mkdir(exist_ok=True)
        shutil.copy(binary, stage / "dsv-fetch")
        (stage / "dsv-fetch").chmod(0o555)
        sh("docker", "run", "--rm", "--user", "65532:65532", "-v", f"{stage}:/opt/dsv-fetch:ro", "-v", f"{bin_dir}:/eh/dsv-bin",
           "--entrypoint", "/opt/dsv-fetch/dsv-fetch", AGENT_IMAGE, "install", "--dest", "/eh/dsv-bin/dsv-fetch")
    assert (bin_dir / "dsv-fetch").exists()
    assert oct((bin_dir / "dsv-fetch").stat().st_mode & 0o777) == "0o500"


def _start_common(stack: Stack, tmp: Path) -> None:
    cfg = tmp / "dsvmock"
    cfg.mkdir()
    (cfg / "cfg.json").write_text(json.dumps({
        "clients": {"sidecar-test": {"secret": "sidecar-test-secret", "identity": "id-hello-partner-sim"}},
        "users": {"id-hello-partner-sim": {"read": ["eh/test/*"]}},
        "secrets": {"eh/test/datadog-api-key": {"value": API_KEY}},
    }))
    for p in [cfg, *cfg.iterdir()]:
        p.chmod(0o755 if p.is_dir() else 0o644)
    stack.run("dsv", PYTHON_IMAGE, volumes=[f"{REPO / 'tools' / 'secrets'}:/m:ro", f"{cfg}:/c:ro"],
              cmd=["python", "-u", "/m/mock_dsv.py", "--config", "/c/cfg.json", "--host", "0.0.0.0", "--port", "8200"])
    stack.run("intake", PYTHON_IMAGE, volumes=[f"{Path(__file__).parent / 'mock_intake'}:/mock:ro"],
              cmd=["python", "-u", "/mock/mock_intake.py"])
    vec = tmp / "vector"
    vec.mkdir()
    (vec / "vector.yaml").write_text(VECTOR_CFG)
    vec.chmod(0o755)
    (vec / "vector.yaml").chmod(0o644)
    stack.run("opw", VECTOR_IMAGE, volumes=[f"{vec}:/etc/vector:ro"], cmd=["--config", "/etc/vector/vector.yaml"])


def _intake(stack: Stack) -> dict:
    out = sh("docker", "exec", f"{stack.id}-intake", "python", "-c",
             "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/_received').read().decode())")
    return json.loads(out)


def _worker_logs(stack: Stack) -> list[dict]:
    events = []
    for line in stack.logs(f"{stack.id}-opw").splitlines():
        if line.startswith("{"):
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
    return events


def _run_app(stack: Stack, sidecar: str, app_env: dict, log_dir: Path) -> None:
    argv = ["docker", "run", "-d", "--name", f"{stack.id}-app", "--network", f"container:{sidecar}", "-v", f"{log_dir}:/var/log/app"]
    for k in ("DD_SERVICE", "DD_ENV", "LOG_FILE_PATH"):
        argv += ["-e", f"{k}={app_env[k]}"]
    sh(*argv, PYTHON_IMAGE, "python", "-u", "-c", APP)
    stack.containers.append(f"{stack.id}-app")


def _assert_delivery(stack: Stack, service: str, source: str) -> None:
    def traces_and_metrics():
        rec = _intake(stack)
        paths = {(o["path"], o["api_key_sha256"]) for o in rec["others"]}
        has_trace = any(p.startswith("/api/v0.2/traces") and s == SHA for p, s in paths)
        has_series = any(p in ("/api/v2/series", "/api/v1/series", "/api/beta/sketches") and s == SHA for p, s in paths)
        return has_trace and has_series
    wait_for(traces_and_metrics, 120, 3, "trace + DogStatsD series at the mock intake with the DSV key")
    rec = _intake(stack)
    assert all(o["api_key_sha256"] in (SHA, None) for o in rec["others"]), "only the DSV key ever reaches the intake"
    assert not rec["events"], "no logs at the Datadog intake: they go to the Observability Pipelines Worker"

    def logs():
        return [e for e in _worker_logs(stack) if "payment accepted" in str(e.get("message", ""))]
    got = wait_for(logs, 90, 3, "app log lines at the OP Worker stand-in")
    first = got[0]
    assert first["service"] == service and first["ddsource"] == source, first
    assert "env:test" in first.get("ddtags", ""), first


def test_aci_agent_sidecar(tmp_path):
    r = _render(tmp_path, "aci", "python")
    aci = r["aci"]
    assert [c["name"] for c in aci["containers"]] == ["datadog-agent"] and [c["name"] for c in aci["init_containers"]] == ["dsv-fetch-install"]
    files = r["files"]
    dd = yaml.safe_load(files["datadog"])
    assert dd["api_key"] == f"ENC[{KEY_REF}]" and dd["secret_backend_command"] == "/opt/dsv-fetch/dsv-fetch"
    agent = aci["containers"][0]
    assert agent["image"] == "gcr.io/datadoghq/agent:7.84.2"
    assert agent["environment_variables"]["DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL"] == "http://opw:8282"
    assert API_KEY not in json.dumps(r), "no key value in the rendered spec"

    cfg = tmp_path / "agent-config"
    cfg.mkdir()
    (cfg / "datadog.yaml").write_text(files["datadog"])
    (cfg / "app-logs.yaml").write_text(files["logs"])
    # test-only DSV auth (client_credentials against the mock); Azure: the group identity (DSV_AUTH=azure, AZURE_CLIENT_ID)
    (cfg / "dsv.json").write_text(json.dumps({**json.loads(files["dsv"]), **DSV_TEST_ENV}))
    for p in [cfg, *cfg.iterdir()]:
        p.chmod(0o755 if p.is_dir() else 0o644)
    log_dir, bin_dir = tmp_path / "app-logs", tmp_path / "dsv-bin"
    log_dir.mkdir()
    log_dir.chmod(0o777)
    _install_binary(tmp_path, bin_dir)

    stack = Stack("acisc")
    try:
        _start_common(stack, tmp_path)
        env = dict(agent["environment_variables"])
        env.update({"DD_DD_URL": "http://intake:8080", "DD_APM_DD_URL": "http://intake:8080",
                    "DD_REMOTE_CONFIGURATION_ENABLED": "false", "DD_PROCESS_CONFIG_PROCESS_COLLECTION_ENABLED": "false",
                    "DD_INVENTORIES_CONFIGURATION_ENABLED": "false", "DD_PROCESS_CONFIG_PROCESS_DD_URL": "http://intake:8080"})
        name = stack.run("agent", AGENT_IMAGE, env=env,
                         volumes=[f"{cfg}:/eh/agent:ro", f"{bin_dir}:/eh/dsv-bin", f"{log_dir}:/var/log/app"],
                         entrypoint=agent["commands"][0], cmd=agent["commands"][1:])
        try:
            wait_for(lambda: subprocess.run(["docker", "exec", name, "agent", "health"], capture_output=True).returncode == 0, 120, 3, "agent health")
            sec = sh("docker", "exec", name, "agent", "secret", check=False)
            assert "Executable permissions: OK" in sec, sec[-1500:]
            assert "Number of secrets resolved: 1" in sec or "Number of secrets decrypted: 1" in sec, sec[-1500:]
            assert API_KEY not in sec
            owner = sh("docker", "exec", name, "stat", "-c", "%U %a", "/opt/dsv-fetch/dsv-fetch").strip()
            assert owner == "root 500", owner
            _run_app(stack, name, r["env"], log_dir)
            _assert_delivery(stack, "hello-partner-sim", "python")
            raw = sh("docker", "exec", name, "agent", "status", "-j", check=False)
            st = json.loads(raw[raw.index("{"):])
            assert st.get("dogstatsdStats", {}).get("MetricPackets", 0) > 0, st.get("dogstatsdStats")
        except Exception:
            print(stack.logs(name)[-6000:])
            raise
    finally:
        stack.close()


def test_aca_serverless_init_sidecar(tmp_path):
    r = _render(tmp_path, "aca", "dotnet")
    patch = r["aca"]
    assert [c["name"] for c in patch["sidecars"]] == ["datadog"] and [c["name"] for c in patch["init_containers"]] == ["dsv-fetch-install"]
    si = patch["sidecars"][0]
    env = {e["name"]: e["value"] for e in si["env"]}
    assert "DD_API_KEY" not in env and env["DD_LOGS_ENABLED"] == "true" and env["DD_SERVERLESS_LOG_PATH"] == "/var/log/app/app.log"
    assert API_KEY not in json.dumps(r)

    log_dir, bin_dir = tmp_path / "app-logs", tmp_path / "dsv-bin"
    log_dir.mkdir()
    log_dir.chmod(0o777)
    _install_binary(tmp_path, bin_dir)
    stack = Stack("acasi")
    try:
        _start_common(stack, tmp_path)
        env.update(DSV_TEST_ENV)
        env.update({"DD_DD_URL": "http://intake:8080", "DD_APM_DD_URL": "http://intake:8080"})
        name = stack.run("datadog", SI_IMAGE, env=env, volumes=[f"{bin_dir}:/eh/dsv-bin", f"{log_dir}:/var/log/app"],
                         entrypoint=si["command"][0], cmd=si["command"][1:])
        try:
            wait_for(lambda: "Sidecar mode" in stack.logs(name) or "sidecar" in stack.logs(name).lower(), 60, 2, "serverless-init start")
            # the dotenv was sourced and truncated: the key lives only in the process environment
            probe = sh("docker", "exec", name, "/bin/sh", "-c", "if [ -s /tmp/dsv-fetch/serverless-init.env ]; then echo nonempty; else echo empty; fi")
            assert probe.strip() == "empty", probe
            assert API_KEY not in sh("docker", "inspect", name)
            app_env = dict(r["env"], DD_SERVICE="hello-partner-sim")
            _run_app(stack, name, app_env, log_dir)
            _assert_delivery(stack, "hello-partner-sim", "csharp")
        except Exception:
            print(stack.logs(name)[-6000:])
            raise
    finally:
        stack.close()
