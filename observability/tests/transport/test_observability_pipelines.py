"""Local (docker) tests of the Observability Pipelines path. Synthetic data only.

What can be proven offline (the Observability Pipelines Worker itself needs a live Datadog org: at start it validates
the API key and downloads the pipeline definition by DD_OP_PIPELINE_ID through Remote Configuration):

* test_vrl_programs: the VRL custom processors rendered by modules/observability-pipeline (terraform console) compile
  and behave on the recorded Event Hubs batches and application logs, executed by the `vector vrl` CLI (VRL is the
  language of the OP custom processor; the Worker is built on Vector). split_array is simulated between the two
  Azure programs.
* test_fluent_bit_forward_to_fluent_source: the sidecar config rendered for log_destination = observability_pipelines
  (modules/fluent-bit, terraform console) runs on Fluent Bit 5.1.3 and delivers to a Vector `fluent` source - the
  source type behind the OP fluent_bit source - with acknowledged forward, without any secret on the edge.
* test_worker_bootstrap_fail_closed_and_env: the real Worker image (pinned 2.22.0) with the module's worker command:
  refuses to start without the dsv-fetch dotenv file, and with it accepts the bootstrap env (pipeline id, site, source
  addresses, data dir per replica) and reaches API-key validation (which needs Datadog - not reachable here).
* test_apm_gateway_agent_resolves_key_from_dsv: the APM gateway of modules/telemetry-transport (Datadog Agent 7.84.2,
  datadog.yaml rendered by terraform console, the module's start command re-installing the static dsv-fetch binary
  that the init container copied into /dsv-bin) resolves api_key ENC[dsv://...] through the
  dsv-fetch secret backend from a mock Delinea DSV, accepts Datadog tracer payloads from another container on 8126
  (apm_non_local_traffic) and reports healthy on 5555 - no API key in env, image or Terraform.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import time
from pathlib import Path

import pytest
from dockerutil import FLUENT_BIT_IMAGE, HERE, Stack, dsv_fetch_binary, sh, wait_for

PKG = HERE.parents[1]
SAMPLES = HERE / "samples"
VECTOR_IMAGE = "timberio/vector:0.58.0-debian"   # test-only stand-in for the Worker's VRL / fluent source engine
OPW_IMAGE = "datadog/observability-pipelines-worker:2.22.0"
AGENT_IMAGE = "datadog/agent:7.84.2"                 # same build as gcr.io/datadoghq/agent:7.84.2 (module default)
PYTHON_IMAGE = "python:3.13-slim"
REPO = PKG.parent

pytestmark = pytest.mark.skipif(not (shutil.which("docker") and shutil.which("terraform")), reason="docker + terraform needed")


def console(module: Path, expr: str, tfvars: dict, tmp: Path) -> object:
    """Evaluate an expression of a module with terraform console (no provider calls) and decode it."""
    if not (module / ".terraform").exists():
        sh("terraform", f"-chdir={module}", "init", "-backend=false", "-input=false", "-no-color")
    vf = tmp / f"{module.name}.tfvars.json"
    vf.write_text(json.dumps(tfvars))
    out = subprocess.run(["terraform", f"-chdir={module}", "console", f"-var-file={vf}"], input=f"jsonencode({expr})\n",
                         capture_output=True, text=True, check=True).stdout.strip()
    # warnings (e.g. about the console's evaluation mode) precede the value: the value is the last line
    return json.loads(json.loads(out.splitlines()[-1]))


OP_VARS = {
    "name": "eh-test-logs", "env": "test",
    "secret_refs": {"api_key": "dsv://eh/test/datadog-api-key#value", "eventhub_connection_string": "dsv://eh/test/eventhub-listen#value"},
    "eventhub_bootstrap": "evhns.servicebus.windows.net:9093",
    "sources": {"eventhub": {"topics": ["app-logs", "platform-logs", "activity-logs"]}},
    "default_tags": {"region": "swedencentral", "managed_by": "terraform", "application": "enterprise-hello"},
    "azure": {"aca_console_allow": ["eh-caj-*"],
              "scope_tags": {"/subscriptions/00000000-0000-0000-0000-000000000000": {"env": "dev", "team": "platform-engineering"},
                             "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-apps-dev": {"team": "orders"}}},
}


def vrl(tmp: Path, program: str, events: list[dict]) -> list[dict]:
    (tmp / "p.vrl").write_text(program)
    (tmp / "in.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
    res = subprocess.run(["docker", "run", "--rm", "-v", f"{tmp}:/w", VECTOR_IMAGE, "vrl", "-p", "/w/p.vrl", "-i", "/w/in.jsonl", "-o"],
                         capture_output=True, text=True)
    lines = [ln for ln in res.stdout.splitlines() if ln.startswith("{")]
    assert res.returncode == 0 and len(lines) == len(events), res.stdout[-3000:] + res.stderr[-3000:]
    return [json.loads(ln) for ln in lines]


def tags(ev: dict) -> dict[str, str]:
    return dict(t.split(":", 1) for t in ev["ddtags"].split(",") if ":" in t)


def test_vrl_programs(tmp_path):
    progs = console(PKG / "modules/observability-pipeline", "local.vrl", OP_VARS, tmp_path)
    # ---- application logs: JSON lift + tag policy (fill missing keys, never overwrite, aliases, pipeline tag)
    app = vrl(tmp_path, progs["app"], [
        {"message": json.dumps({"timestamp": "2026-10-09T12:00:00Z", "level": "ERROR", "message": "boom", "traceId": "4bf92f3577b34da6a3ce929d0e0e4736"}),
         "ddtags": "env:dev,team:orders"},
        {"message": "plain line", "ddtags": ""},
    ])
    assert app[0]["message"] == "boom" and app[0]["level"] == "error" and app[0]["trace_id"] == "4bf92f3577b34da6a3ce929d0e0e4736"
    assert app[1]["message"] == "plain line"
    tagged = vrl(tmp_path, progs["tags"], app)
    t0, t1 = tags(tagged[0]), tags(tagged[1])
    assert t0["env"] == "dev" and t0["team"] == "orders" and t0["region"] == "swedencentral" and t0["managed_by"] == "terraform"
    assert t0["telemetry.pipeline"] == "observability-pipelines"
    assert t1["env"] == "test", "env default of the pipeline when the source sent none"
    # ---- Azure Event Hubs batches: unwrap -> (split_array) -> forwarder shape
    raw = []
    for f, topic in (("eventhub-activity-logs.jsonl", "activity-logs"), ("eventhub-entra-logs.jsonl", "activity-logs"),
                     ("eventhub-azure-platform-logs.jsonl", "platform-logs"), ("eventhub-app-logs.jsonl", "app-logs")):
        raw += [{"message": ln, "topic": topic} for ln in (SAMPLES / f).read_text().splitlines() if ln.strip()]
    unwrapped = vrl(tmp_path, progs["azure_unwrap"], raw)
    split = [dict(e, records=r) for e in unwrapped for r in e["records"]]
    shaped = vrl(tmp_path, progs["azure_shape"], split)
    by_src = {}
    for e in shaped:
        by_src.setdefault(e["ddsource"], []).append(e)
    assert {"azure.authorization", "azure.activedirectory", "azure.keyvault", "azure.containerservice"} <= set(by_src)
    admin = by_src["azure.authorization"][0]
    ta = tags(admin)
    assert ta["subscription_id"] == "00000000-0000-0000-0000-000000000000" and ta["resource_group"] == "eh-rg-apps-dev"
    assert ta["resource_type"] == "microsoft.authorization/roleassignments" and ta["azure_log_type"] == "activity"
    assert ta["team"] == "orders", "longest resource-scope prefix wins per key"
    assert ta["env"] == "dev" and admin["service"] == "azure" and admin["operationName"].startswith("MICROSOFT.AUTHORIZATION")
    entra = tags(by_src["azure.activedirectory"][0])
    assert entra["azure_log_type"] == "entra" and entra["tenant"]
    audit = by_src["azure.containerservice"][0]
    assert audit["aks_audit"]["verb"] and audit["aks_audit"]["objectRef"]["resource"] == "pods"
    # ACA console: allow-listed job kept, sidecar-collected app + fluent-bit container flagged for the filter processor
    aca = [e for e in shaped if e.get("category") == "ContainerAppConsoleLogs"]
    assert aca and any(e.get("eh_drop") for e in aca) and any(not e.get("eh_drop") for e in aca)
    tagged_azure = vrl(tmp_path, progs["tags"], shaped)
    assert all(tags(e)["telemetry.pipeline"] == "observability-pipelines" for e in tagged_azure)


def test_fluent_bit_forward_to_fluent_source(tmp_path):
    files = console(PKG / "modules/fluent-bit", "local.files",
                    {"role": "sidecar", "log_destination": "observability_pipelines", "op_endpoint": {"host": "opw", "port": 24224}},
                    tmp_path)
    conf = tmp_path / "flb"
    conf.mkdir()
    for rel, text in files.items():
        p = conf / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    assert "fluentbit-env.yaml" not in files["fluent-bit.yaml"].split("pipeline:")[0].split("includes:")[1], "no secret include"
    out = tmp_path / "out"
    out.mkdir()
    out.chmod(0o777)
    (tmp_path / "vector.yaml").write_text(
        "sources:\n  fluent:\n    type: fluent\n    address: 0.0.0.0:24224\n"
        "sinks:\n  file:\n    type: file\n    inputs: [fluent]\n    path: /out/events.log\n    encoding:\n      codec: json\n")
    logdir = tmp_path / "applogs"
    logdir.mkdir()
    logdir.chmod(0o777)
    s = Stack("op-fluent")
    try:
        s.run("opw", VECTOR_IMAGE, volumes=[f"{tmp_path / 'vector.yaml'}:/etc/vector/vector.yaml:ro", f"{out}:/out"],
              cmd=["--config", "/etc/vector/vector.yaml"])
        s.run("sidecar", FLUENT_BIT_IMAGE, volumes=[f"{conf}:/fluent-bit/etc/eh:ro", f"{logdir}:/var/log/app"],
              env={"LOG_FILE_PATH": "/var/log/app/app.log", "FLB_STATE_DIR": "/tmp/flb", "FLB_DD_SOURCE": "csharp",
                   "FLB_DD_SERVICE": "hello-orders-api", "FLB_DD_TAGS": "env:test,service:hello-orders-api,team:orders",
                   "FLB_FORWARD_HOST": "opw", "FLB_FORWARD_PORT": "24224", "FLB_FORWARD_TLS": "off", "FLB_FORWARD_TLS_VERIFY": "off"},
              cmd=["-c", "/fluent-bit/etc/eh/fluent-bit.yaml"])
        (logdir / "app.log").write_text((SAMPLES / "app.log").read_text())
        target = out / "events.log"

        def events():
            return [json.loads(ln) for ln in target.read_text().splitlines()] if target.exists() else []
        wait_for(lambda: len(events()) >= 5, 60, what="events at the fluent source")
        evs = events()
        assert all("telemetry.pipeline:fluent-bit" in e["ddtags"] and "team:orders" in e["ddtags"] for e in evs)
        assert all(e["ddsource"] == "csharp" for e in evs)
        joined = json.dumps(evs)
        assert "test-secret" not in joined.lower() or "[REDACTED]" in joined
        logs = s.logs(f"{s.id}-sidecar")
        assert "error" not in logs.lower().replace("errors", ""), logs[-2000:]
    finally:
        for c in s.containers:
            print(f"==== {c}\n{s.logs(c)[-3000:]}")
        s.close()


def test_worker_bootstrap_fail_closed_and_env(tmp_path):
    op = PKG / "modules/observability-pipeline"
    cmd = console(op, "local.worker_script", OP_VARS, tmp_path)
    env = {"DD_OP_PIPELINE_ID": "aaaaaaaa-0000-0000-0000-000000000001", "DD_SITE": "datadoghq.com", "DD_OP_API_ENABLED": "true",
           "DD_OP_API_ADDRESS": "0.0.0.0:8686", "DD_OP_DATA_DIR_BASE": "/var/lib/observability-pipelines-worker",
           "DD_OP_SOURCE_FLUENT_ADDRESS": "0.0.0.0:24224", "DD_OP_SOURCE_DATADOG_AGENT_ADDRESS": "0.0.0.0:8282"}
    envargs = [a for k, v in env.items() for a in ("-e", f"{k}={v}")]
    # 1) no secrets file -> refuses to start (fail closed); shortened wait for the test
    fast = cmd.replace("-gt 60", "-gt 1")
    r = subprocess.run(["docker", "run", "--rm", *envargs, "--entrypoint", "/bin/sh", OPW_IMAGE, "-c", fast],
                       capture_output=True, text=True, timeout=120)
    assert r.returncode == 1 and "refusing to start" in r.stderr
    # 2) dotenv written by dsv-fetch (format dotenv: quoted, $ escaped) -> bootstrap accepted, API key validation reached
    sec = tmp_path / "dsv"
    sec.mkdir()
    (sec / "opw.env").write_text('DD_API_KEY="abcdefabcdefabcdefabcdefabcdef12"\n')
    name = f"opw-boot-{int(time.time())}"
    subprocess.run(["docker", "run", "-d", "--name", name, *envargs, "-v", f"{sec}:/dsv-secrets:ro", "--entrypoint", "/bin/sh",
                    OPW_IMAGE, "-c", cmd], check=True, capture_output=True)
    try:
        def reached():
            return "validate Datadog API key" in sh("docker", "logs", name, check=False)
        wait_for(reached, 60, what="worker bootstrap -> API key validation")
        logs = sh("docker", "logs", name, check=False)
        assert "Bootstrap configuration contains errors" not in logs
        assert "abcdefabcdefabcdefabcdefabcdef12" not in logs, "the API key is never logged"
        listing = sh("docker", "exec", name, "sh", "-c", "ls /var/lib/observability-pipelines-worker/", check=False)
        assert listing.strip(), "per-replica data dir created"
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)


TRANSPORT_VARS = {
    "name_prefix": "eh-obs-test", "location": "swedencentral", "tags": {"env": "test"},
    "resource_group": {"name": "rg-obs", "id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-obs"},
    "datadog": {"site": "datadoghq.com", "api_key_ref": "dsv://eh/test/datadog-api-key#value", "env": "test", "extra_tags": {"team": "observability"}},
    "secrets": {"tenant": "contoso", "fetch_image": "ehacr.azurecr.io/dsv-fetch@sha256:" + "1" * 64},
    "collector_identity": {"id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs",
                           "principal_id": "11111111-1111-1111-1111-111111111111", "client_id": "22222222-2222-2222-2222-222222222222"},
    "event_hub": {"mode": "none"},
    "container_apps": {"environment_id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aca/providers/Microsoft.App/managedEnvironments/cae"},
    "observability_pipelines": {"pipeline_id": "aaaaaaaa-0000-0000-0000-000000000001"},
    "default_tags": {"region": "swedencentral", "managed_by": "terraform"},
}


def test_apm_gateway_agent_resolves_key_from_dsv(tmp_path):
    import yaml
    tr = PKG / "modules/telemetry-transport"
    dd_yaml = yaml.safe_load(console(tr, "local.apm_datadog_yaml", TRANSPORT_VARS, tmp_path))
    start = console(tr, "local.apm_command", TRANSPORT_VARS, tmp_path)
    env = {e["name"]: e["value"] for e in console(tr, "local.apm_container_env", TRANSPORT_VARS, tmp_path)}
    assert env["DD_API_KEY"] == "ENC[dsv://eh/test/datadog-api-key#value]", "only a DSV reference in the container env"
    assert dd_yaml["api_key"] == "ENC[dsv://eh/test/datadog-api-key#value]" and dd_yaml["apm_config"]["apm_non_local_traffic"] is True
    assert dd_yaml["secret_backend_command"] == "/opt/dsv-fetch/dsv-fetch" and dd_yaml["logs_enabled"] is False
    assert "managed_by:terraform" in dd_yaml["tags"] and "env:test" in dd_yaml["tags"]
    key = "abcdef0123456789abcdef0123456789"
    cfg = tmp_path / "apm"
    for d in ("dsvmock", "eh-agent", "eh-dsv", "dsv-bin"):
        (cfg / d).mkdir(parents=True)
    (cfg / "dsvmock" / "cfg.json").write_text(json.dumps({
        "clients": {"apm-test": {"secret": "apm-test-secret", "identity": "obs-apm-test"}},
        "users": {"obs-apm-test": {"read": ["eh/test/*"]}},
        "secrets": {"eh/test/datadog-api-key": {"value": key}}}))
    (cfg / "eh-agent" / "datadog.yaml").write_text(yaml.safe_dump(dd_yaml))
    # the dsv-fetch-install init container's result: the static binary in the replica's EmptyDir /dsv-bin
    found = dsv_fetch_binary(tmp_path)
    if found is None:
        pytest.skip("no dsv-fetch static binary (set DSV_FETCH_BIN, DSV_FETCH_IMAGE or install Go)")
    shutil.copy(found[0], cfg / "dsv-bin" / "dsv-fetch")
    # the module's dsv.json uses managed identity (DSV_AUTH azure); locally the mock DSV authenticates a client
    (cfg / "eh-dsv" / "dsv.json").write_text(json.dumps({
        "DSV_AUTH": "client_credentials", "DSV_CLIENT_ID": "apm-test", "DSV_CLIENT_SECRET": "apm-test-secret",
        "DSV_BASE_URL": "http://dsv:8200/v1", "DSV_ALLOW_INSECURE_HTTP": "true"}))
    for p in cfg.rglob("*"):
        p.chmod(0o755 if p.is_dir() or p.name == "dsv-fetch" else 0o644)
    s = Stack("apmgw")
    try:
        s.run("dsv", PYTHON_IMAGE, volumes=[f"{REPO / 'tools' / 'secrets'}:/m:ro", f"{cfg / 'dsvmock'}:/c:ro"],
              cmd=["python", "-u", "/m/mock_dsv.py", "--config", "/c/cfg.json", "--host", "0.0.0.0", "--port", "8200"])
        agent = s.run("apm", AGENT_IMAGE, env={**env, "HOSTNAME": "apm-gw-0"},
                      volumes=[f"{cfg / 'eh-agent'}:/eh/agent:ro", f"{cfg / 'eh-dsv'}:/eh/dsv:ro", f"{cfg / 'dsv-bin'}:/dsv-bin:ro"],
                      entrypoint=start[0], cmd=start[1:])

        def secret_resolved():
            out = subprocess.run(["docker", "exec", agent, "agent", "secret"], capture_output=True, text=True).stdout
            seen.append(out)
            return ("Number of secrets resolved: 1" in out or "Number of secrets decrypted: 1" in out) and out
        seen: list[str] = []
        try:
            out = wait_for(secret_resolved, 120, 3, "API key resolved through dsv-fetch")
        except TimeoutError:
            print("agent secret:", (seen or [""])[-1][-3000:])
            raise
        assert "Executable permissions: OK" in out and key not in out
        # a Datadog tracer payload from ANOTHER container (managed runtime) on 8126
        payload = json.dumps([[{"trace_id": 1, "span_id": 1, "parent_id": 0, "name": "web.request", "resource": "GET /",
                                "service": "hello-orders-api", "type": "web", "start": time.time_ns(), "duration": 1000000,
                                "meta": {"env": "test", "version": "1.0.0"}}]])
        client = ("import urllib.request,sys; r=urllib.request.Request('http://apm:8126/v0.4/traces', data=sys.argv[1].encode(),"
                  " method='PUT', headers={'Content-Type':'application/json','X-Datadog-Trace-Count':'1'});"
                  " print(urllib.request.urlopen(r, timeout=10).status)")

        def accepted():
            r = subprocess.run(["docker", "run", "--rm", "--network", s.id, PYTHON_IMAGE, "python", "-c", client, payload],
                               capture_output=True, text=True)
            return r.returncode == 0 and r.stdout.strip() == "200"
        wait_for(accepted, 90, 3, "trace-agent accepts non-local traffic on 8126")
        def live():
            h = subprocess.run(["docker", "run", "--rm", "--network", s.id, PYTHON_IMAGE, "python", "-c",
                                "import urllib.request; print(urllib.request.urlopen('http://apm:5555/live', timeout=10).status)"],
                               capture_output=True, text=True)
            return h.stdout.strip() == "200"
        wait_for(live, 120, 5, "Agent liveness on 5555 (Container Apps liveness probe)")
        logs = s.logs(agent)
        assert key not in logs, "the API key is never logged"
    finally:
        for c in s.containers:
            print(f"==== {c}\n{s.logs(c)[-3000:]}")
        s.close()
