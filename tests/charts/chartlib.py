"""Helpers for the hello-service Helm chart tests (imported by conftest.py and the test modules).

Tools (pinned by the applications pipeline; see applications/charts/hello-service/README.md):
  helm         Helm CLI (v4; the Terraform helm provider 3.x embeds the Helm v3 SDK, so `helm3` is also used if present)
  kubeconform  schema validation against the AKS Kubernetes version (platform/compute/aks default kubernetes_version)
Environment:
  HELM_BIN / HELM3_BIN / KUBECONFORM_BIN   override binaries
  KUBECONFORM_CACHE                         schema cache dir (download once; reused offline)
  K8S_SCHEMA_VERSION                        default: derived from platform/compute/aks (1.36 -> 1.36.0)
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
CHART = REPO / "applications" / "charts" / "hello-service"
EXAMPLES = CHART / "examples"
AKS_VARIABLES = REPO / "platform" / "compute" / "aks" / "variables.tf"


def _which(env: str, name: str) -> str | None:
    return os.environ.get(env) or shutil.which(name) or (f"/opt/tools/bin/{name}" if Path(f"/opt/tools/bin/{name}").exists() else None)


HELM = _which("HELM_BIN", "helm")
HELM3 = _which("HELM3_BIN", "helm3")
KUBECONFORM = _which("KUBECONFORM_BIN", "kubeconform")


def aks_kubernetes_version() -> str:
    if os.environ.get("K8S_SCHEMA_VERSION"):
        return os.environ["K8S_SCHEMA_VERSION"]
    m = re.search(r'kubernetes_version\s*=\s*optional\(string,\s*"(\d+\.\d+)(\.\d+)?"\)', AKS_VARIABLES.read_text())
    assert m, "platform/compute/aks default kubernetes_version not found"
    return m.group(1) + (m.group(2) or ".0")


def example_files() -> list[Path]:
    return sorted(EXAMPLES.glob("*.yaml"))


def load_values(path: Path) -> dict:
    return yaml.safe_load(path.read_text()) or {}


def helm_binaries() -> list[str]:
    return [b for b in (HELM, HELM3) if b]


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def template(values: dict | Path, release: str | None = None, namespace: str = "hello", helm: str | None = None,
             extra: list[str] | None = None, tmp: Path | None = None) -> subprocess.CompletedProcess:
    helm = helm or HELM
    if isinstance(values, dict):
        assert tmp is not None
        vf = tmp / f"values-{abs(hash(json.dumps(values, sort_keys=True)))}.yaml"
        vf.write_text(yaml.safe_dump(values))
    else:
        vf = values
    if release is None:  # release name == workload name (deploy convention)
        release = ((yaml.safe_load(Path(vf).read_text()) or {}).get("service") or {}).get("name") or "test"
    return run([helm, "template", release, str(CHART), "-n", namespace, "-f", str(vf), *(extra or [])])


def render(values: dict | Path, **kw) -> list[dict]:
    res = template(values, **kw)
    assert res.returncode == 0, res.stderr
    return [d for d in yaml.safe_load_all(res.stdout) if d]


def by_kind(docs: list[dict], kind: str) -> list[dict]:
    return [d for d in docs if d.get("kind") == kind]
