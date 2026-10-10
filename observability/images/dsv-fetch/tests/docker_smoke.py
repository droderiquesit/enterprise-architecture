#!/usr/bin/env python3
"""Docker smoke test for the dsv-fetch image (manual / CI with docker; not collected by pytest).

    docker build -t dsv-fetch:dev observability/images/dsv-fetch
    python3 observability/images/dsv-fetch/tests/docker_smoke.py [--image dsv-fetch:dev] [--json out.json]

Everything runs on an --internal docker network (no egress): tools/secrets/mock_dsv.py (DSV API), fake_identity.py
(IMDS), capture_intake.py (records SHA-256 of DD-API-KEY headers, never keys). Checks:

  init-files      dsv-fetch (read-only rootfs, uid 65532, azure grant via IMDS) writes DIR/DD_API_KEY 0400 on a tmpfs volume
  fluent-bit      dsv-fetch --format env-yaml -> Fluent Bit 5.1.3 `includes:` the env file; `${DD_API_KEY}` in the main
                  config's datadog output resolves from it (key hash seen by the intake); also when the container env
                  holds a different DD_API_KEY (the YAML env section wins) and when Fluent Bit runs as uid 65532
  otel-collector  dsv-fetch as uid 10001 -> collector-contrib 0.162.0 `api.key: ${file:/dsv-secrets/DD_API_KEY}` (datadog
                  exporter series reach the intake with that key)
  agent-backend   protocol round trip through `docker run -i dsv-fetch:dev agent-backend`
  datadog-agent   `dsv-fetch install` (root, 0500: the static binary copies itself into a plain volume) -> Datadog Agent
                  7.84.2 (Ubuntu-based image, no shared libraries needed) secret_backend_command with
                  DD_API_KEY=ENC[dsv://eh/dev/datadog-api-key#value]; the Agent's requests to the intake carry the key

Prints one JSON document (no secret values) and exits non-zero when a check fails.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
MIRID = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-eh-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-eh-dev-observability"
KEY = "smoke-dd-api-key-" + uuid.uuid4().hex[:12]
DECOY = "decoy-key-from-container-env"
KEY_SHA = hashlib.sha256(KEY.encode()).hexdigest()
DECOY_SHA = hashlib.sha256(DECOY.encode()).hexdigest()
PY = "python:3.13-slim"
FLB = "fluent/fluent-bit:5.1.3"
OTEL = "otel/opentelemetry-collector-contrib:0.162.0"
AGENT = "datadog/agent:7.84.2"


def sh(*args: str, check: bool = True, timeout: int = 120, stdin: str | None = None) -> subprocess.CompletedProcess:
    p = subprocess.run(list(args), capture_output=True, text=True, timeout=timeout, input=stdin)
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:4])}... failed ({p.returncode}): {p.stderr[-800:]}")
    return p


class Smoke:
    def __init__(self, image: str) -> None:
        self.image = image
        self.id = uuid.uuid4().hex[:6]
        self.net = f"dsvsmoke-{self.id}"
        self.containers: list[str] = []
        self.volumes: list[str] = []
        self.work = Path(tempfile.mkdtemp(prefix="dsvsmoke-"))
        self.results: dict[str, dict] = {}

    # ------------------------------------------------------------------------------------------- helpers
    def name(self, n: str) -> str:
        return f"dsvsmoke-{self.id}-{n}"

    def volume(self, n: str, *, tmpfs_uid: int | None = None) -> str:
        v = self.name(n)
        opts = ["--driver", "local", "--opt", "type=tmpfs", "--opt", "device=tmpfs", "--opt", f"o=size=1m,mode=0700,uid={tmpfs_uid},gid={tmpfs_uid}"] if tmpfs_uid is not None else []
        sh("docker", "volume", "create", *opts, v)
        self.volumes.append(v)
        if tmpfs_uid is not None:
            # A tmpfs-backed local volume is mounted while at least one container uses it and its content is lost when
            # the last one exits - like a pod's in-memory emptyDir, which lives as long as the pod. The holder plays the pod.
            self.daemon(f"hold-{n}", "-v", f"{v}:/v:ro", PY, "sleep", "infinity")
        return v

    def daemon(self, n: str, *args: str) -> str:
        c = self.name(n)
        sh("docker", "run", "-d", "--name", c, "--network", self.net, "--network-alias", n, *args)
        self.containers.append(c)
        return c

    def once(self, *args: str, stdin: str | None = None, timeout: int = 120) -> subprocess.CompletedProcess:
        return sh("docker", "run", "--rm", "-i" if stdin is not None else "--init", "--network", self.net, *args, check=False, stdin=stdin, timeout=timeout)

    def dsv_env(self) -> list[str]:
        env = {
            "DSV_BASE_URL": "http://mock-dsv:8200/v1",
            "DSV_ALLOW_INSECURE_HTTP": "true",  # internal docker network, mock server; real DSV is https
            "AZURE_CLIENT_ID": "11111111-2222-3333-4444-555555555555",
            "AZURE_POD_IDENTITY_AUTHORITY_HOST": "http://identity:8300",
        }
        return [x for k, v in env.items() for x in ("-e", f"{k}={v}")]

    def fetch(self, volume: str, *init_args: str, user: str = "65532:65532") -> subprocess.CompletedProcess:
        return self.once("--read-only", "--user", user, "-v", f"{volume}:/dsv-secrets", *self.dsv_env(), self.image, "init", "--out", "/dsv-secrets", *init_args)

    def intake_hashes(self) -> list[dict]:
        p = sh("docker", "exec", self.name("intake"), "python3", "-c", "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/_received').read().decode())")
        return json.loads(p.stdout)["requests"]

    def reset_intake(self) -> None:
        sh("docker", "restart", "-t", "1", self.name("intake"))
        time.sleep(1.5)

    def wait_for_key(self, predicate, timeout: float = 40) -> list[dict]:
        deadline = time.time() + timeout
        reqs: list[dict] = []
        while time.time() < deadline:
            reqs = self.intake_hashes()
            if predicate(reqs):
                return reqs
            time.sleep(1)
        return reqs

    # ------------------------------------------------------------------------------------------- stack
    def up(self) -> None:
        sh("docker", "network", "create", "--internal", self.net)
        cfg = {
            "users": {MIRID: {"read": ["eh/dev/datadog-api-key"]}},
            "secrets": {"eh/dev/datadog-api-key": {"value": KEY}},
        }
        (self.work / "dsv.json").write_text(json.dumps(cfg))
        (self.work).chmod(0o755)
        (self.work / "dsv.json").chmod(0o644)
        self.daemon("mock-dsv", "-v", f"{REPO / 'tools/secrets'}:/m:ro", "-v", f"{self.work}:/cfg:ro", PY, "python3", "-u", "/m/mock_dsv.py", "--config", "/cfg/dsv.json", "--host", "0.0.0.0", "--port", "8200")
        self.daemon("identity", "-v", f"{HERE}:/t:ro", PY, "python3", "-u", "/t/fake_identity.py", "--mirid", MIRID, "--host", "0.0.0.0", "--port", "8300")
        self.daemon("intake", "-v", f"{HERE}:/t:ro", PY, "python3", "-u", "/t/capture_intake.py")
        time.sleep(3)

    def down(self) -> None:
        for c in self.containers:
            sh("docker", "rm", "-f", c, check=False)
        for v in self.volumes:
            sh("docker", "volume", "rm", "-f", v, check=False)
        sh("docker", "network", "rm", self.net, check=False)

    # ------------------------------------------------------------------------------------------- checks
    def check_init_files(self) -> None:
        vol = self.volume("files", tmpfs_uid=65532)
        p = self.fetch(vol, "--format", "files", "--map", "DD_API_KEY=dsv://eh/dev/datadog-api-key#value")
        probe = self.once(
            "-v",
            f"{vol}:/s:ro",
            PY,
            "python3",
            "-c",
            "import os,stat,hashlib,json;st=os.stat('/s/DD_API_KEY');"
            "fs=[l.split()[2] for l in open('/proc/mounts') if l.split()[1]=='/s'];"
            "print(json.dumps({'mode':oct(stat.S_IMODE(st.st_mode)),'uid':st.st_uid,'fstype':fs[0] if fs else None,"
            "'sha256':hashlib.sha256(open('/s/DD_API_KEY','rb').read()).hexdigest(),'files':sorted(os.listdir('/s'))}))",
        )
        info = json.loads(probe.stdout) if probe.returncode == 0 else {"error": probe.stderr[-300:]}
        ok = p.returncode == 0 and info.get("mode") == "0o400" and info.get("uid") == 65532 and info.get("sha256") == KEY_SHA and KEY not in p.stdout + p.stderr
        self.results["init-files"] = {"ok": ok, "exit": p.returncode, "file": info, "stderr_summary": p.stderr.strip()[-300:], "value_in_output": KEY in p.stdout + p.stderr}

    def check_fluent_bit(self) -> None:
        vol = self.volume("flb", tmpfs_uid=65532)
        p = self.fetch(vol, "--format", "env-yaml", "--map", "DD_API_KEY=dsv://eh/dev/datadog-api-key")
        conf = self.work / "flb"
        conf.mkdir()
        (conf / "main.yaml").write_text(
            """includes:
  - /dsv-secrets/fluentbit-env.yaml
service:
  flush: 1
  log_level: info
pipeline:
  inputs:
    - name: dummy
      tag: app.smoke
      dummy: '{"message":"dsv-fetch smoke"}'
      rate: 1
  outputs:
    - name: datadog
      match: '*'
      host: intake
      port: 8080
      tls: off
      compress: gzip
      apikey: ${DD_API_KEY}
      dd_service: dsv-smoke
      dd_source: smoke
"""
        )
        conf.chmod(0o755)
        (conf / "main.yaml").chmod(0o644)
        variants = {"root": [], "decoy-env": ["-e", f"DD_API_KEY={DECOY}"], "uid-65532": ["--user", "65532:65532"]}
        out: dict[str, dict] = {}
        for label, extra in variants.items():
            self.reset_intake()
            c = self.daemon(f"flb-{label}", "--read-only", *extra, "-v", f"{vol}:/dsv-secrets:ro", "-v", f"{conf}:/c:ro", FLB, "-c", "/c/main.yaml")
            reqs = self.wait_for_key(lambda r: any(x["path"] == "/api/v2/logs" for x in r), timeout=20)
            logs = [x for x in reqs if x["path"] == "/api/v2/logs"]
            out[label] = {
                "log_requests": len(logs),
                "all_with_dsv_key": bool(logs) and all(x["api_key_sha256"] == KEY_SHA for x in logs),
                "decoy_used": any(x["api_key_sha256"] == DECOY_SHA for x in logs),
                "value_in_container_log": KEY in sh("docker", "logs", c, check=False).stdout + sh("docker", "logs", c, check=False).stderr,
            }
            sh("docker", "rm", "-f", c, check=False)
        ok = p.returncode == 0 and all(v["all_with_dsv_key"] and not v["decoy_used"] and not v["value_in_container_log"] for v in out.values())
        self.results["fluent-bit"] = {"ok": ok, "image": FLB, "init_exit": p.returncode, "variants": out}

    def check_otel(self) -> None:
        vol = self.volume("otel", tmpfs_uid=10001)
        p = self.fetch(vol, "--format", "files", "--map", "DD_API_KEY=dsv://eh/dev/datadog-api-key", user="10001:10001")
        conf = self.work / "otel"
        conf.mkdir()
        (conf / "config.yaml").write_text(
            """receivers:
  hostmetrics:
    collection_interval: 2s
    scrapers:
      memory: {}
exporters:
  datadog:
    api:
      key: ${file:/dsv-secrets/DD_API_KEY}
      site: datadoghq.com
      fail_on_invalid_key: false
    metrics:
      endpoint: http://intake:8080
    host_metadata:
      enabled: false
service:
  telemetry:
    logs:
      level: warn
  pipelines:
    metrics:
      receivers: [hostmetrics]
      exporters: [datadog]
"""
        )
        conf.chmod(0o755)
        (conf / "config.yaml").chmod(0o644)
        self.reset_intake()
        c = self.daemon("otel", "--read-only", "-v", f"{vol}:/dsv-secrets:ro", "-v", f"{conf}:/c:ro", OTEL, "--config=/c/config.yaml")
        reqs = self.wait_for_key(lambda r: any("series" in x["path"] for x in r), timeout=75)
        series = [x for x in reqs if "series" in x["path"] or "sketches" in x["path"]]
        logs = sh("docker", "logs", c, check=False)
        ok = p.returncode == 0 and bool(series) and all(x["api_key_sha256"] == KEY_SHA for x in series) and KEY not in logs.stdout + logs.stderr
        self.results["otel-collector"] = {
            "ok": ok,
            "image": OTEL,
            "init_exit": p.returncode,
            "init_user": "10001:10001",
            "metric_requests": len(series),
            "paths": sorted({x["path"] for x in series}),
            "all_with_dsv_key": bool(series) and all(x["api_key_sha256"] == KEY_SHA for x in series),
            "collector_running": "true" in sh("docker", "inspect", "-f", "{{.State.Running}}", c, check=False).stdout,
        }

    def check_agent_backend(self) -> None:
        req = {"version": "1.0", "secrets": ["dsv://eh/dev/datadog-api-key#value", "dsv://eh/dev/forbidden"]}
        p = self.once("--read-only", *self.dsv_env(), self.image, "agent-backend", stdin=json.dumps(req))
        try:
            out = json.loads(p.stdout)
        except ValueError:
            out = {}
        ok_handle = out.get("dsv://eh/dev/datadog-api-key#value", {})
        bad_handle = out.get("dsv://eh/dev/forbidden", {})
        ok = (
            p.returncode == 0
            and ok_handle.get("error") is None
            and hashlib.sha256((ok_handle.get("value") or "").encode()).hexdigest() == KEY_SHA
            and bad_handle.get("value") is None
            and "HTTP 403" in (bad_handle.get("error") or "")
            and KEY not in p.stderr
        )
        self.results["agent-backend"] = {"ok": ok, "exit": p.returncode, "ok_handle_value_sha_matches": ok, "forbidden_handle_error": bad_handle.get("error"), "stderr_empty": p.stderr == ""}

    def check_datadog_agent(self) -> None:
        vol = self.volume("agentbin")
        inst = self.once("--user", "0:0", "-v", f"{vol}:/dsv-bin", self.image, "install", "--dest", "/dsv-bin/dsv-fetch", "--python", "/opt/datadog-agent/embedded/bin/python3")
        self.reset_intake()
        env = {
            "DD_API_KEY": "ENC[dsv://eh/dev/datadog-api-key#value]",
            "DD_SECRET_BACKEND_COMMAND": "/dsv-bin/dsv-fetch",
            "DD_SECRET_BACKEND_ARGUMENTS": "agent-backend",
            "DD_DD_URL": "http://intake:8080",
            "DD_HOSTNAME": "dsv-smoke",
            "DD_SITE": "datadoghq.com",
            "DD_APM_ENABLED": "false",
            "DD_PROCESS_AGENT_ENABLED": "false",
            "DD_LOGS_ENABLED": "false",
            "DD_ENABLE_PAYLOADS_EVENTS": "false",
            "DD_INVENTORIES_ENABLED": "false",
            "DD_CLOUD_PROVIDER_METADATA": "[]",
            "DD_SKIP_SSL_VALIDATION": "true",
        }
        args = [x for k, v in env.items() for x in ("-e", f"{k}={v}")]
        c = self.daemon("agent", *args, *self.dsv_env(), "-v", f"{vol}:/dsv-bin:ro", AGENT)
        reqs = self.wait_for_key(lambda r: any(x["api_key_sha256"] == KEY_SHA for x in r), timeout=90)
        hits = [x for x in reqs if x["api_key_sha256"] == KEY_SHA]
        others = [x for x in reqs if x["api_key_sha256"] not in (KEY_SHA, None)]
        secret_cmd = sh("docker", "exec", c, "agent", "secret", check=False, timeout=60)
        perm = sh("docker", "exec", c, "stat", "-c", "%a %U", "/dsv-bin/dsv-fetch", check=False).stdout.strip()
        logs = sh("docker", "logs", c, check=False)
        ok = inst.returncode == 0 and bool(hits) and not others and KEY not in secret_cmd.stdout + logs.stdout + logs.stderr
        self.results["datadog-agent"] = {
            "ok": ok,
            "image": AGENT,
            "install_exit": inst.returncode,
            "backend_file": perm,
            "requests_with_dsv_key": len(hits),
            "requests_with_other_key": len(others),
            "paths": sorted({x["path"] for x in hits})[:12],
            "agent_secret_cmd_excerpt": [ln for ln in secret_cmd.stdout.splitlines() if any(w in ln.lower() for w in ("executable", "permissions", "dsv://", "rights", "number of secrets"))][:12],
        }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default="dsv-fetch:dev")
    ap.add_argument("--json", help="also write the result document here")
    ap.add_argument("--skip", action="append", default=[], help="skip a check (init-files, fluent-bit, otel-collector, agent-backend, datadog-agent)")
    a = ap.parse_args()
    s = Smoke(a.image)
    try:
        s.up()
        for name, fn in [
            ("init-files", s.check_init_files),
            ("fluent-bit", s.check_fluent_bit),
            ("otel-collector", s.check_otel),
            ("agent-backend", s.check_agent_backend),
            ("datadog-agent", s.check_datadog_agent),
        ]:
            if name in a.skip:
                continue
            try:
                fn()
            except Exception as exc:  # report and continue with the other checks
                s.results[name] = {"ok": False, "error": f"{type(exc).__name__}: {str(exc)[:400]}"}
    finally:
        s.down()
    doc = {"image": a.image, "network": "internal (no egress)", "key_sha256_prefix": KEY_SHA[:12], "checks": s.results, "ok": all(r.get("ok") for r in s.results.values())}
    text = json.dumps(doc, indent=2)
    assert KEY not in text
    print(text)
    if a.json:
        Path(a.json).write_text(text + "\n")
    return 0 if doc["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
