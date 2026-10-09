"""The values the Terraform deploy roots render are valid for the chart (end-to-end, no cluster).

Runs `terraform test -verbose` (mock providers, plan only) in applications/deployments/core-aks and
applications/deployments/specialized, extracts the rendered Helm values from the plan output and
  - compares core-aks values with applications/charts/hello-service/examples/aks-<svc>.yaml (drift check;
    REGEN_EXAMPLES=1 rewrites the examples),
  - lints/renders them with the chart (values.schema.json is enforced by helm).
Skipped when terraform is not installed or SKIP_TERRAFORM_TESTS=1. TF_DATA_DIR is a temp dir (no .terraform/ left).
"""

from __future__ import annotations

import os
import re
import shutil
import textwrap

import pytest
import yaml

from chartlib import CHART, REPO, by_kind, render, run

TERRAFORM = shutil.which("terraform")
pytestmark = pytest.mark.skipif(not TERRAFORM or os.environ.get("SKIP_TERRAFORM_TESTS") == "1",
                                reason="terraform not installed or SKIP_TERRAFORM_TESTS=1")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
HEADER = ("# {name} on AKS - values exactly as rendered by applications/deployments/core-aks (terraform test fixture,\n"
          "# run \"defaults\": internal-lb exposure, secretsMode dsv). Regenerate: REGEN_EXAMPLES=1 pytest tests/charts -k terraform\n"
          "# Release: helm upgrade --install {name} applications/charts/hello-service -n hello -f <this file>\n")


def _verbose_plan(root: str, tmp_path_factory) -> str:
    data_dir = tmp_path_factory.mktemp("tfdata")
    env = {**os.environ, "TF_DATA_DIR": str(data_dir), "TF_IN_AUTOMATION": "1"}
    cwd = REPO / root
    init = run([TERRAFORM, "init", "-backend=false", "-input=false", "-lockfile=readonly"], cwd=cwd, env=env)
    assert init.returncode == 0, init.stdout + init.stderr
    res = run([TERRAFORM, "test", "-verbose", "-no-color"], cwd=cwd, env=env)
    assert res.returncode == 0, res.stdout[-4000:] + res.stderr
    return ANSI.sub("", res.stdout)


@pytest.fixture(scope="module")
def core_aks_values(tmp_path_factory) -> dict[str, dict]:
    out = _verbose_plan("applications/deployments/core-aks", tmp_path_factory)
    first_run = out.split('run "app_routing_and_synced_secrets"')[0]
    vals: dict[str, dict] = {}
    for m in re.finditer(r'# helm_release\.app\["([a-z-]+)"\] will be created.*?\+ <<-EOT\n(.*?)\n\s*EOT', first_run, re.S):
        vals.setdefault(m.group(1), yaml.safe_load(textwrap.dedent(m.group(2))))
    assert set(vals) == {"hello-bff", "hello-orders-api", "hello-catalog-api", "hello-worker"}, sorted(vals)
    return vals


@pytest.fixture(scope="module")
def aro_values(tmp_path_factory) -> dict:
    out = _verbose_plan("applications/deployments/specialized", tmp_path_factory)
    m = re.search(r"\+ values\s+= <<-EOT\n(.*?)\n\s*EOT", out, re.S)
    assert m, "aro.helm.values not found in the specialized plan output"
    return yaml.safe_load(textwrap.dedent(m.group(1)))


def test_terraform_core_aks_values_match_examples(core_aks_values):
    for name, values in core_aks_values.items():
        path = CHART / "examples" / f"aks-{name.removeprefix('hello-')}.yaml"
        if os.environ.get("REGEN_EXAMPLES") == "1":
            path.write_text(HEADER.format(name=name) + yaml.safe_dump(values, sort_keys=True, width=200))
        assert yaml.safe_load(path.read_text()) == values, f"{path.name} drifted from core-aks (REGEN_EXAMPLES=1 to update)"


def test_terraform_core_aks_values_render(core_aks_values, helm_bin, tmp_path):
    for name, values in core_aks_values.items():
        docs = render(values, tmp=tmp_path)
        kinds = sorted(d["kind"] for d in docs)
        expected = {"Deployment", "ServiceAccount", "PodDisruptionBudget", "HorizontalPodAutoscaler"}
        assert expected <= set(kinds), (name, kinds)
        assert ("Service" in kinds) == (name != "hello-worker")
        assert "SecretProviderClass" not in kinds and "Secret" not in kinds
        env = {e["name"]: e for e in by_kind(docs, "Deployment")[0]["spec"]["template"]["spec"]["containers"][0]["env"]}
        assert env["DSV_AUTH"]["value"] == "azure" and env["DSV_BASE_URL"]["value"].endswith("/v1")
        if name != "hello-worker":   # secret settings are dsv:// references resolved by the app (workload identity)
            assert env["FAULT_TOKEN"]["value"].startswith("dsv://")


def test_terraform_aro_values_render(aro_values, helm_bin, tmp_path):
    vf = tmp_path / "aro.yaml"
    vf.write_text(yaml.safe_dump(aro_values))
    lint = run([helm_bin, "lint", "--strict", str(CHART), "-n", "hello", "-f", str(vf)])
    assert lint.returncode == 0, lint.stdout + lint.stderr
    docs = render(vf)
    assert by_kind(docs, "Route") and not by_kind(docs, "Ingress")
    dep = by_kind(docs, "Deployment")[0]
    assert dep["spec"]["replicas"] == 2 and "runAsUser" not in dep["spec"]["template"]["spec"]["securityContext"]
