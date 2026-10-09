"""Linux host installer (modules/host-agents) executed in ubuntu:24.04: installs the pinned Fluent Bit
package from packages.fluentbit.io, stages + dry-runs the config, writes the env file 0600, configures the
Datadog Agent drop-in (OTLP on localhost, logs off) and is idempotent on re-run. systemd is stubbed.
Needs outbound HTTPS (opt in: EH_NETWORK_TESTS=1; uses HTTPS_PROXY + /root/.ccr/ca-bundle.crt when present).
"""

from __future__ import annotations

import os
import shutil
import subprocess

import pytest

from dockerutil import HERE, PACKAGE

pytestmark = [
    pytest.mark.skipif(shutil.which("docker") is None, reason="docker not available"),
    pytest.mark.skipif(os.environ.get("EH_NETWORK_TESTS") != "1", reason="network test (set EH_NETWORK_TESTS=1)"),
]


def _render(tmp_path, key):
    tf = os.environ.get("TERRAFORM_BIN", "terraform")
    mod = PACKAGE / "modules" / "host-agents"
    subprocess.run([tf, "init", "-backend=false", "-input=false"], cwd=mod, check=True, capture_output=True)
    out = subprocess.run([tf, "console", f"-var-file={HERE / 'host' / 'hosts.tfvars.json'}"], cwd=mod,
                         input=f'local.scripts["{key}"]', capture_output=True, text=True, check=True).stdout
    lines = out.splitlines()
    script = "\n".join(lines[1:-1]) + "\n"  # strip <<EOT / EOT
    p = tmp_path / f"{key}.sh"
    p.write_text(script)
    subprocess.run(["bash", "-n", str(p)], check=True)
    return p


def test_linux_installer_in_ubuntu(tmp_path):
    worker = _render(tmp_path, "worker")
    sqlvm = _render(tmp_path, "sqlvm")
    ca = "/root/.ccr/ca-bundle.crt"
    args = ["docker", "run", "--rm", "--network", "host"]
    if os.environ.get("HTTPS_PROXY"):
        args += ["-e", f"https_proxy={os.environ['HTTPS_PROXY']}", "-e", f"HTTPS_PROXY={os.environ['HTTPS_PROXY']}"]
    if os.path.exists(ca):
        args += ["-v", f"{ca}:/ca.crt:ro"]
    args += ["-v", f"{worker}:/installer.sh:ro", "-v", f"{sqlvm}:/installer-sqlvm.sh:ro",
             "-v", f"{HERE / 'host' / 'run-in-ubuntu.sh'}:/run.sh:ro", "-v", f"{HERE / 'samples'}:/samples:ro",
             "ubuntu:24.04", "bash", "/run.sh"]
    res = subprocess.run(args, capture_output=True, text=True, timeout=900)
    print(res.stdout[-4000:], res.stderr[-2000:])
    assert res.returncode == 0
    out = res.stdout + res.stderr
    assert "fluent-bit\t5.1.3" in out
    assert "configuration test is successful" in out
    assert "600 /etc/default/fluent-bit-eh" in out
    assert "DD_LOGS_ENABLED=false" in out and "localhost:4317" in out
    assert out.count("[eh-host-setup] fluent-bit 5.1.3 installed") == 1  # second run does not reinstall
    assert "agent-only host" in out and "AGENT_ONLY_OK" in out
