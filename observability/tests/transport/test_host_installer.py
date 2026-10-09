"""Linux host installer (modules/host-agents) executed in ubuntu:24.04: installs the pinned Datadog Agent (install
script, DD_INSTALL_ONLY, datadog.yaml with api_key ENC[dsv://...] + secret_backend_command) and the pinned Fluent Bit
package, installs dsv-fetch (root copy for ExecStartPre, dd-agent 0500 copy for the Agent), stages + dry-runs the
config, writes the NON-secret env file 0600, configures the Agent drop-in (OTLP on localhost, logs off) and is
idempotent on re-run. Then runs the unit's ExecStartPre against a mock DSV (env-yaml file 0400 in the tmpfs runtime
dir), dry-runs Fluent Bit with it, and calls the Agent secret backend as dd-agent. systemd is stubbed.
Needs outbound HTTPS (opt in: EH_NETWORK_TESTS=1; uses HTTPS_PROXY + /root/.ccr/ca-bundle.crt when present).
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys

import pytest

from dockerutil import HERE, PACKAGE, REPO

pytestmark = [
    pytest.mark.skipif(shutil.which("docker") is None, reason="docker not available"),
    pytest.mark.skipif(os.environ.get("EH_NETWORK_TESTS") != "1", reason="network test (set EH_NETWORK_TESTS=1)"),
]


def _render(tmp_path, key, tfvars=None):
    tf = os.environ.get("TERRAFORM_BIN", "terraform")
    mod = PACKAGE / "modules" / "host-agents"
    subprocess.run([tf, "init", "-backend=false", "-input=false"], cwd=mod, check=True, capture_output=True)
    out = subprocess.run([tf, "console", f"-var-file={tfvars or HERE / 'host' / 'hosts.tfvars.json'}"], cwd=mod,
                         input=f'local.scripts["{key}"]', capture_output=True, text=True, check=True).stdout
    lines = out.splitlines()
    script = "\n".join(lines[1:-1]) + "\n"  # strip <<EOT / EOT
    p = tmp_path / f"{key}.sh"
    p.write_text(script)
    subprocess.run(["bash", "-n", str(p)], check=True)
    return p


KEY = "host-test-not-a-real-key"


def test_linux_installer_in_ubuntu(tmp_path):
    sys.path.insert(0, str(REPO))
    from tools.secrets.mock_dsv import serve

    srv, _ = serve({"clients": {"host-test": {"secret": "host-test-secret", "identity": "vm-worker"}},
                    "users": {"vm-worker": {"read": ["eh/test/*"]}},
                    "secrets": {"eh/test/datadog-api-key": {"value": KEY}}})
    port = srv.server_address[1]
    tfvars = tmp_path / "hosts.tfvars.json"
    tfvars.write_text((HERE / "host" / "hosts.tfvars.json").read_text().replace("127.0.0.1:18200", f"127.0.0.1:{port}"))
    worker = _render(tmp_path, "worker", tfvars)
    sqlvm = _render(tmp_path, "sqlvm", tfvars)
    ca = "/root/.ccr/ca-bundle.crt"
    args = ["docker", "run", "--rm", "--network", "host"]
    if os.environ.get("HTTPS_PROXY"):
        args += ["-e", f"https_proxy={os.environ['HTTPS_PROXY']}", "-e", f"HTTPS_PROXY={os.environ['HTTPS_PROXY']}"]
    if os.path.exists(ca):
        args += ["-v", f"{ca}:/ca.crt:ro"]
    args += ["-e", f"EXPECTED_KEY_SHA={hashlib.sha256(KEY.encode()).hexdigest()}"]
    args += ["-v", f"{worker}:/installer.sh:ro", "-v", f"{sqlvm}:/installer-sqlvm.sh:ro",
             "-v", f"{HERE / 'host' / 'run-in-ubuntu.sh'}:/run.sh:ro", "-v", f"{HERE / 'samples'}:/samples:ro",
             "ubuntu:24.04", "bash", "/run.sh"]
    try:
        res = subprocess.run(args, capture_output=True, text=True, timeout=1500)
    finally:
        srv.shutdown()
    print(res.stdout[-4000:], res.stderr[-2000:])
    assert res.returncode == 0
    out = res.stdout + res.stderr
    assert "fluent-bit\t5.1.3" in out
    assert "configuration test is successful" in out
    assert "600 /etc/default/fluent-bit-eh" in out and "KEY_IN_ENV_FILE" not in out and KEY not in out
    assert "api_key: ENC[dsv://eh/test/datadog-api-key#value]" in out
    assert "500 dd-agent /opt/eh-dsv-fetch/agent/dsv-fetch" in out and "500 root /opt/eh-dsv-fetch/dsv-fetch" in out
    assert "400 /run/fluent-bit-eh/fluentbit-env.yaml" in out and "BACKEND_OK" in out
    assert "datadog-agent\t1:7.84.2" in out
    assert "DD_LOGS_ENABLED=false" in out and "localhost:4317" in out
    assert out.count("[eh-host-setup] fluent-bit 5.1.3 installed") == 1  # second run does not reinstall
    assert "agent-only host" in out and "AGENT_ONLY_OK" in out
