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
"""

from __future__ import annotations

import json
import shutil
import subprocess
import time
from pathlib import Path

import pytest
from dockerutil import FLUENT_BIT_IMAGE, HERE, Stack, sh, wait_for

PKG = HERE.parents[1]
SAMPLES = HERE / "samples"
VECTOR_IMAGE = "timberio/vector:0.58.0-debian"   # test-only stand-in for the Worker's VRL / fluent source engine
OPW_IMAGE = "datadog/observability-pipelines-worker:2.22.0"

pytestmark = pytest.mark.skipif(not (shutil.which("docker") and shutil.which("terraform")), reason="docker + terraform needed")


def console(module: Path, expr: str, tfvars: dict, tmp: Path) -> object:
    """Evaluate an expression of a module with terraform console (no provider calls) and decode it."""
    if not (module / ".terraform").exists():
        sh("terraform", f"-chdir={module}", "init", "-backend=false", "-input=false", "-no-color")
    vf = tmp / f"{module.name}.tfvars.json"
    vf.write_text(json.dumps(tfvars))
    out = subprocess.run(["terraform", f"-chdir={module}", "console", f"-var-file={vf}"], input=f"jsonencode({expr})\n",
                         capture_output=True, text=True, check=True).stdout.strip()
    return json.loads(json.loads(out))


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
