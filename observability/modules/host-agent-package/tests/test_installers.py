"""Rendered VM Application setup scripts (modules/host-agent-package).

* static: render both installers with `terraform console`, `bash -n` + shellcheck (when installed) on Linux, and
  guard that nothing secret / no SAS / no Key Vault is in them;
* local (docker, no network): run the Linux installer twice in ubuntu:24.04 next to the fake dsv-fetch fixture with
  IMDS, the Datadog install script and systemd stubbed; check datadog.yaml (ENC[] DSV reference, secret backend,
  host tags mapped from the instance's Azure tags, OP Worker), the Agent log config (policy files + the
  datadog:log_paths tag), dsv-fetch 0500 dd-agent, idempotency, the checksum guard and `remove`.

Run: python3 -m pytest observability/modules/host-agent-package/tests -q   (TERRAFORM_BIN overrides `terraform`)
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess

import pytest

MODULE = pathlib.Path(__file__).resolve().parents[1]
HERE = pathlib.Path(__file__).resolve().parent
TF = os.environ.get("TERRAFORM_BIN", "terraform")

VARS = {
    "resource_group_id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg",
    "location": "swedencentral",
    "names": {"gallery": "g", "storage_account": "ehstvmapp", "publisher_identity": "id"},
    "package_version": "1.0.0",
    "dsv_fetch_release_dir": "./tests/fixtures/dsv-fetch",
    "env": "dev",
    "datadog": {"site": "datadoghq.eu", "api_key_ref": "dsv://eh/dev/datadog-api-key#value"},
    "dsv": {"tenant": "contoso", "identity_client_id": "33333333-3333-3333-3333-333333333333"},
    "op_agent_logs_url": "http://eh-obs-dev-opw.internal:8282",
    "host_logs": {"linux": {"files": [{"path": "/var/log/hello-worker/*.log", "service": "hello-worker"}]}},
}


@pytest.fixture(scope="module")
def installers(tmp_path_factory):
    if shutil.which(TF) is None:
        pytest.skip("terraform not available")
    tmp = tmp_path_factory.mktemp("render")
    tfvars = tmp / "vars.tfvars.json"
    tfvars.write_text(json.dumps(VARS))
    subprocess.run([TF, "init", "-backend=false", "-input=false"], cwd=MODULE, check=True, capture_output=True)
    out = {}
    for key in ("linux", "windows"):
        res = subprocess.run([TF, "console", f"-var-file={tfvars}"], cwd=MODULE, input=f"jsonencode(local.installers[\"{key}\"])",
                             capture_output=True, text=True, check=True)
        out[key] = json.loads(json.loads(res.stdout.strip()))
    return out


def test_no_secret_material(installers):
    for name, script in installers.items():
        low = script.lower()
        assert "vault.azure.net" not in low and "sig=" not in low and "sv=20" not in low, name
        assert "dd_api_key=" not in low and "apikey=" not in low, name
        assert "ENC[" in script and "dsv://eh/dev/datadog-api-key#value" in script, name


def test_linux_installer_lint(installers, tmp_path):
    p = tmp_path / "datadog-agent-setup.sh"
    p.write_text(installers["linux"])
    subprocess.run(["bash", "-n", str(p)], check=True)
    if shutil.which("shellcheck") is None:
        pytest.skip("shellcheck not installed")
    res = subprocess.run(["shellcheck", "-S", "warning", str(p)], capture_output=True, text=True)
    assert res.returncode == 0, res.stdout


def test_install_commands_fit_vm_application_limit(installers):
    # manage_action strings are short; the scripts themselves travel as the configuration blob (1 GB limit)
    assert all(len(s) < 1_000_000 for s in installers.values())


def _image_present(image: str) -> bool:
    return subprocess.run(["docker", "image", "inspect", image], capture_output=True).returncode == 0


@pytest.mark.skipif(shutil.which("docker") is None, reason="docker not available")
def test_linux_setup_in_ubuntu(installers, tmp_path):
    if not _image_present("ubuntu:24.04"):
        pytest.skip("ubuntu:24.04 image not present (the test runs without network)")
    (tmp_path / "datadog-agent-setup.sh").write_text(installers["linux"])
    shutil.copy(HERE / "fixtures" / "dsv-fetch" / "dsv-fetch-linux-amd64", tmp_path / "dsv-fetch")
    tags = ("Env:dev;service:Hello-Worker;team:platform-engineering;owner:platform@example.com;"
            "datadog:enabled:true;datadog:log_paths:/srv/app/*.log, relative/ignored.log;version:1.2.3")
    res = subprocess.run(
        ["docker", "run", "--rm", "--network", "none", "-e", f"FAKE_TAGS={tags}",
         "-v", f"{tmp_path}:/in:ro", "-v", f"{HERE / 'host' / 'run-in-ubuntu.sh'}:/run.sh:ro",
         "ubuntu:24.04", "bash", "/run.sh"],
        capture_output=True, text=True, timeout=600)
    out = res.stdout + res.stderr
    print(out[-6000:])
    assert res.returncode == 0
    sections = dict(s.split("\n", 1) for s in out.split("=== ")[1:])
    dd = sections["DATADOG_YAML"]
    assert "api_key: ENC[dsv://eh/dev/datadog-api-key#value]" in dd
    assert "secret_backend_command: /opt/datadog-dsv/dsv-fetch" in dd and "  - agent-backend" in dd
    assert "env: dev" in dd and '  - "team:platform-engineering"' in dd and '  - "owner:platform_example.com"' in dd
    assert "service:" not in dd.split("secret_backend_command")[0].split("tags:")[1], "service is never a host tag"
    assert 'url: "http://eh-obs-dev-opw.internal:8282"' in dd and "remote_updates: false" in dd
    logs = sections["LOGS_CONF"]
    assert 'path: "/var/log/hello-worker/*.log"\n    service: "hello-worker"' in logs
    assert 'path: "/srv/app/*.log"\n    service: "hello-worker"' in logs and "relative/ignored.log" not in logs
    assert json.loads(sections["DSV_JSON"])["AZURE_CLIENT_ID"] == "33333333-3333-3333-3333-333333333333"
    env = sections["INSTALL_ENV"]
    assert "DD_AGENT_MINOR_VERSION=84.2" in env and "DD_INSTALL_ONLY=true" in env and "DD_APM_INSTRUMENTATION_ENABLED=host" in env
    assert "DD_REMOTE_UPDATES" not in env
    perms = sections["PERMS"]
    assert "500 dd-agent /opt/datadog-dsv/dsv-fetch" in perms and "640 root /etc/datadog-agent/datadog.yaml" in perms
    assert "dd-agent /etc/datadog-agent/datadog.yaml" in perms
    assert "StartLimitIntervalSec=0" in sections["UNIT"]
    assert "datadog-agent unchanged" in sections["RUN2"], "second run is a no-op"
    assert "TAMPER_REJECTED" in sections["TAMPER"] and "checksum mismatch" in sections["TAMPER"]
    assert "REMOVED_OK" in sections["REMOVE"]


PWSH_IMAGE = "mcr.microsoft.com/powershell:7.4-ubuntu-22.04"


@pytest.mark.skipif(shutil.which("docker") is None, reason="docker not available")
def test_windows_setup_parses_and_renders(installers, tmp_path):
    """PowerShell parser on the full script; then the configuration part (up to the MSI download) runs under pwsh
    on Linux with IMDS mocked, and the rendered datadog.yaml / logs conf are checked."""
    if not _image_present(PWSH_IMAGE):
        pytest.skip(f"{PWSH_IMAGE} not present (the test runs without network)")
    script = installers["windows"]
    (tmp_path / "datadog-agent-setup.ps1").write_text(script)
    marker = "# ------------------------------------------------------------------ Datadog Agent MSI"
    assert marker in script
    mock = (
        "function Invoke-RestMethod { param($Headers, [switch]$NoProxy, $TimeoutSec, $Uri) "
        "@([pscustomobject]@{name='Environment';value='Dev'}, [pscustomobject]@{name='service';value='hello-inventory-api'}, "
        "[pscustomobject]@{name='Team';value='Platform Engineering'}, "
        "[pscustomobject]@{name='datadog:log_paths';value='D:\\app\\*.log, relative.log'}) }\n"
    )
    head = script.split(marker)[0]
    # Windows directories -> container paths (pwsh on Linux has no C: drive); the rendered YAML keeps the real ones
    head = head.replace("$DdDir = 'C:\\ProgramData\\Datadog'", "$DdDir = '/tmp/dd'")
    # the param() block must stay first: insert the mock right after it
    lines = head.splitlines()
    idx = next(i for i, line in enumerate(lines) if line.startswith("param("))
    cfg = "\n".join(lines[: idx + 1]) + "\n" + mock + "\n".join(lines[idx + 1:])
    cfg += "\nGet-Content -Raw (Join-Path $DdDir 'datadog.yaml'); '=== LOGS'; Get-Content -Raw $LogsConf\n"
    (tmp_path / "cfg.ps1").write_text(cfg)
    shutil.copy(HERE / "fixtures" / "dsv-fetch" / "dsv-fetch-windows-amd64.exe", tmp_path / "dsv-fetch.exe")
    parse = ("$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile('/w/datadog-agent-setup.ps1',"
             "[ref]$t,[ref]$e)|Out-Null; if($e.Count){$e|%{\"$($_.Extent.StartLineNumber): $($_.Message)\"}; exit 1}; "
             "Copy-Item -Recurse /w /run/w; Set-Location /run/w; ./cfg.ps1 -Action install")
    res = subprocess.run(["docker", "run", "--rm", "--network", "none", "-v", f"{tmp_path}:/w:ro", PWSH_IMAGE,
                          "pwsh", "-NoProfile", "-NonInteractive", "-Command", parse],
                         capture_output=True, text=True, timeout=300)
    out = res.stdout + res.stderr
    print(out[-4000:])
    assert res.returncode == 0
    dd, logs = out.split("=== LOGS")
    assert "api_key: ENC[dsv://eh/dev/datadog-api-key#value]" in dd and "secret_backend_command: C:\\Program Files\\Datadog\\dsv-fetch\\dsv-fetch.exe" in dd
    assert "env: dev" in dd and '  - "team:platform_engineering"' in dd and "service:hello" not in dd
    assert 'url: "http://eh-obs-dev-opw.internal:8282"' in dd and '    - "GET /healthz"' in dd
    assert "type: windows_event" in logs and "channel_path: 'System'" in logs and "channel_path: 'Application'" in logs
    assert "path: 'D:\\app\\*.log'" in logs and "relative.log" not in logs and 'service: "hello-inventory-api"' in logs
