"""Portability proof for the observability package.

(a) build the release tarball with tools/release/package.sh
(b) copy examples/existing-environment to a temp dir OUTSIDE the repository
(c) vendor the package from the local tarball (file:// url + sha256) with the example's vendor.sh
(d) terraform init -backend=false / validate / test (mock providers); assert that only allowed resource types are
    planned and that supplied resource ids are used verbatim (example tests)
(e) prove that no path in the consumer copy escapes to the source repository or its lab roots
(f) simulate an upgrade <VERSION> -> <VERSION>-upgrade-test (no destroy of anything) and a removal (destroy lists only
    Datadog-side / collection objects, never monitored infrastructure)

Requires terraform, bash, tar, sha256sum. No network beyond the provider plugin cache, no credentials.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

PKG = Path(__file__).resolve().parents[2]          # observability/
REPO = PKG.parent
EXAMPLE = PKG / "examples" / "existing-environment"
# current package version (the release under test) and a synthetic next version for the upgrade simulation
CUR = (PKG / "VERSION").read_text().strip()
NEXT = CUR + "-upgrade-test"

ALLOWED_PREFIXES = ("datadog_", "kubernetes_")
ALLOWED_EXACT = {"azurerm_monitor_diagnostic_setting", "azurerm_virtual_machine_extension",
                 "azurerm_virtual_machine_run_command", "helm_release",
                 # collectors only, when the transport modules are enabled in a consumer root
                 "azurerm_container_app", "azurerm_container_group"}
FORBIDDEN = {"azurerm_virtual_network", "azurerm_subnet", "azurerm_resource_group", "azurerm_linux_web_app",
             "azurerm_windows_web_app", "azurerm_kubernetes_cluster", "azurerm_postgresql_flexible_server",
             "azurerm_mssql_server", "azurerm_mssql_database", "azurerm_service_plan", "azurerm_linux_virtual_machine"}

PLAN_LINE = re.compile(
    r"#\s+((?:module\.[A-Za-z0-9_-]+(?:\[[^\]]*\])?\.)*)(data\.)?([a-z0-9_]+)\.([A-Za-z0-9_-]+)(\[[^\]]*\])?\s+"
    r"(will be created|will be destroyed|must be replaced|will be updated in-place|will be read during apply)")

pytestmark = pytest.mark.skipif(
    not all(shutil.which(t) for t in ("terraform", "bash", "tar", "sha256sum")), reason="toolchain missing")


def sh(cmd, cwd, env=None, timeout=900):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
                       env={**os.environ, **(env or {})})
    return r


def ok(r):
    assert r.returncode == 0, f"{r.args}\nSTDOUT:\n{r.stdout[-4000:]}\nSTDERR:\n{r.stderr[-4000:]}"
    return r


def build(version: str, out: Path) -> tuple[Path, str]:
    ok(sh(["bash", str(PKG / "tools/release/package.sh"), "--out", str(out), "--version", version], cwd=PKG))
    tarball = out / f"observability-{version}.tar.gz"
    sha = (out / f"observability-{version}.tar.gz.sha256").read_text().split()[0]
    return tarball, sha


def lock(consumer: Path, version: str, tarball: Path, sha: str, name="package.lock.json"):
    (consumer / name).write_text(json.dumps({"name": "observability", "version": version,
                                             "url": f"file://{tarball}", "sha256": sha}, indent=2))


def plan_changes(output: str) -> list[tuple[str, str, str]]:
    """(resource_type, address, action) for every planned change printed by `terraform test -verbose`."""
    out = []
    for m in PLAN_LINE.finditer(output):
        if m.group(2):  # data source read
            continue
        addr = f"{m.group(1)}{m.group(3)}.{m.group(4)}{m.group(5) or ''}"
        out.append((m.group(3), addr, m.group(6)))
    return out


def run_sections(output: str) -> dict[str, str]:
    """Split verbose `terraform test` output into per-run sections."""
    sections, current = {}, None
    for line in output.splitlines():
        m = re.match(r'\s*run "([^"]+)"\.\.\. ', line)
        if m:
            current = m.group(1)
            sections[current] = ""
            continue
        if current:
            sections[current] += line + "\n"
    return sections


# Mock providers for every provider a consumer root may use (no credentials, no network).
MOCKS = (
    'mock_provider "datadog" {\n'
    '  mock_resource "datadog_observability_pipeline" { defaults = { id = "aaaaaaaa-0000-0000-0000-000000000001" } }\n'
    '  mock_resource "datadog_rum_application" { defaults = { id = "bbbbbbbb-0000-0000-0000-000000000002", client_token = "pub0123" } }\n'
    '}\n'
    'mock_provider "azurerm" {\n'
    '  mock_data "azurerm_monitor_diagnostic_categories" {\n'
    '    defaults = { log_category_types = ["AppServiceConsoleLogs", "AppServiceHTTPLogs", "PostgreSQLLogs", "kube-audit-admin"] }\n'
    '  }\n'
    '}\n'
    'mock_provider "azapi" {}\n'
    'mock_provider "helm" {}\n'
    'mock_provider "kubernetes" {}\n'
)


def allowed(rtype: str) -> bool:
    return rtype.startswith(ALLOWED_PREFIXES) or rtype in ALLOWED_EXACT


@pytest.fixture(scope="module")
def consumer(tmp_path_factory):
    work = tmp_path_factory.mktemp("portability")
    assert REPO not in work.parents, "consumer copy must live outside the repository"
    dist = work / "dist"
    tarball, sha = build(CUR, dist)
    dst = work / "consumer"
    shutil.copytree(EXAMPLE, dst, ignore=shutil.ignore_patterns(".vendor", ".terraform", "*.tfplan"))
    lock(dst, CUR, tarball, sha)
    ok(sh(["bash", "vendor.sh"], cwd=dst))
    return {"work": work, "dir": dst, "dist": dist, "sha": sha, "tarball": tarball}


def test_a_release_contents(consumer):
    listing = ok(sh(["tar", "-tzf", str(consumer["tarball"])], cwd=consumer["work"])).stdout.splitlines()
    top = {p.split("/")[0] for p in listing}
    assert top == {f"observability-{CUR}"}
    second = {p.split("/")[1] for p in listing if p.count("/") >= 1 and p.split("/")[1]}
    assert {"modules", "config", "schemas", "tools", "pipelines", "examples", "VERSION", "README.md",
            "CHANGELOG.md", "UPGRADING.md"} <= second
    assert not second & {"lab", "onboarding", "extras", "archetypes"}, "lab roots and optional monitoring content are not released"
    assert not [p for p in listing if "/modules/monitors/" in p or "/modules/slos/" in p or "/modules/dashboards/" in p]
    assert not [p for p in listing if "/.terraform/" in p or p.endswith(".tfstate")]
    # reproducible build: same inputs -> same checksum
    _, sha2 = build(CUR, consumer["work"] / "dist2")
    assert sha2 == consumer["sha"]


def test_b_vendor_rejects_wrong_checksum(consumer):
    bad = consumer["work"] / "bad"
    shutil.copytree(consumer["dir"], bad, ignore=shutil.ignore_patterns(".vendor", ".terraform"))
    lock(bad, CUR, consumer["tarball"], "0" * 64)
    r = sh(["bash", "vendor.sh"], cwd=bad)
    assert r.returncode != 0 and "sha256 mismatch" in r.stderr
    assert not (bad / ".vendor" / f"observability-{CUR}").exists()


def test_e_no_path_escapes(consumer):
    root = consumer["dir"].resolve()
    offenders = []
    for tf in root.rglob("*.tf"):
        if ".terraform" in tf.parts:
            continue
        text = tf.read_text()
        for src in re.findall(r'source\s*=\s*"([^"]+)"', text):
            if src.startswith((".", "/")):
                target = (tf.parent / src).resolve()
                if root not in target.parents and target != root:
                    offenders.append(f"{tf}: {src}")
        if re.search(r"terraform_remote" r"_state", text):
            offenders.append(f"{tf}: remote state")
    for f in root.rglob("*"):
        if f.is_file() and ".terraform" not in f.parts and f.suffix in (".tf", ".hcl", ".json", ".yaml", ".yml", ".sh", ".py", ".md"):
            text = f.read_text(errors="ignore")
            if str(REPO) in text:
                offenders.append(f"{f}: absolute path into the source repository")
            if re.search(r"(^|[^A-Za-z0-9_])la" r"b/", text) or "../../foundation" in text:
                offenders.append(f"{f}: lab/foundation reference")
    assert not offenders, "\n".join(offenders)


def test_d_init_validate_test_and_allowed_types(consumer):
    d = consumer["dir"]
    (d / "tests" / "zz_types.tftest.hcl").write_text(
        MOCKS + 'run "types" {\n  command = plan\n}\n')
    ok(sh(["terraform", "init", "-backend=false", "-input=false", "-no-color"], cwd=d))
    ok(sh(["terraform", "validate", "-no-color"], cwd=d))
    ok(sh(["terraform", "test", "-no-color", "-filter=tests/example.tftest.hcl"], cwd=d))
    r = ok(sh(["terraform", "test", "-no-color", "-verbose", "-filter=tests/zz_types.tftest.hcl"], cwd=d))
    changes = plan_changes(r.stdout)
    assert changes, "no planned resources parsed"
    types = {t for t, _, _ in changes}
    assert not (types & FORBIDDEN), types & FORBIDDEN
    assert all(allowed(t) for t in types), sorted(t for t in types if not allowed(t))
    assert all(a == "will be created" for _, _, a in changes)


def test_f_upgrade_and_removal(consumer):
    d = consumer["dir"]
    tarball, sha = build(NEXT, consumer["work"] / "dist-next")
    # The upgraded root is a copy whose lock + module sources move to 1.1.0-test (vendor.sh --update-sources),
    # planned against the state installed by 1.0.0 (shared state_key).
    up = d / "upgrade"
    up.mkdir()
    for item in ("versions.tf", "providers.tf", "variables.tf", "main.tf", "outputs.tf", "vendor.sh", "rendered", "manifests"):
        src = d / item
        (shutil.copytree if src.is_dir() else shutil.copy2)(src, up / item)
    lock(up, NEXT, tarball, sha)
    r = sh(["bash", "vendor.sh", "--update-sources"], cwd=up)
    ok(r)
    assert "observability-" + NEXT + "/" in (up / "main.tf").read_text()
    # removal root: same providers, no resources -> planning it against the installed state lists every destroy
    rm = d / "removal"
    rm.mkdir()
    shutil.copy2(d / "versions.tf", rm / "versions.tf")
    (d / "tests" / "zz_lifecycle.tftest.hcl").write_text(
        MOCKS +
        'run "plan_1_0_0" {\n  command = plan\n  state_key = "consumer"\n}\n'
        'run "install_1_0_0" {\n  command = apply\n  state_key = "consumer"\n}\n'
        'run "upgrade_1_1_0_test" {\n  command = plan\n  state_key = "consumer"\n  module { source = "./upgrade" }\n}\n'
        'run "removal" {\n  command = plan\n  state_key = "consumer"\n  module { source = "./removal" }\n}\n')
    ok(sh(["terraform", "init", "-backend=false", "-input=false", "-no-color"], cwd=d))
    r = ok(sh(["terraform", "test", "-no-color", "-verbose", "-filter=tests/zz_lifecycle.tftest.hcl"], cwd=d))
    sections = run_sections(r.stdout)
    assert {"plan_1_0_0", "install_1_0_0", "upgrade_1_1_0_test", "removal"} <= set(sections), sections.keys()

    installed = plan_changes(sections["plan_1_0_0"])
    upgrade = plan_changes(sections["upgrade_1_1_0_test"])
    removal = plan_changes(sections["removal"])
    for name, items in (("install", installed), ("upgrade", upgrade), ("removal", removal)):
        print(f"{name}: {len(items)} changes, actions={sorted({a for _, _, a in items})}")
    assert installed
    assert not [c for c in upgrade if c[2] in ("will be destroyed", "must be replaced")], upgrade
    assert not [c for c in upgrade if c[2] == "will be created"], "upgrade must not recreate objects under new addresses"
    destroyed = {a for t, a, act in removal if act == "will be destroyed"}
    assert destroyed and all(allowed(t) for t, _, _ in removal)
    assert not ({t for t, _, _ in removal} & FORBIDDEN), "removal must never touch monitored infrastructure"
    print("removal types:", sorted({t for t, _, _ in removal}))
    assert destroyed == {a for _, a, _ in installed}, "removal destroys exactly what was installed"
