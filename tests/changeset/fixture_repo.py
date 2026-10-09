"""Temporary git repositories for change-detection tests.

`make_synthetic_repo` builds a minimal, self-contained registry (no other builder's code needed);
`make_real_registry_repo` copies the real catalog/environments/versions and creates stub files at
every registered path. Both commit an initial state on branch `main`.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.changeset.store import LocalStore  # noqa: E402

SYNTHETIC_REGISTRY = {
    "schema_version": 1,
    "components": [
        {"id": "bootstrap", "layer": "bootstrap", "kind": "terraform", "path": "bootstrap", "pipeline": "manual",
         "produces": ["bootstrap"]},
        {"id": "foundation-network", "layer": "foundation", "kind": "terraform", "path": "foundation/network",
         "produces": ["foundation-network"]},
        {"id": "foundation-identity", "layer": "foundation", "kind": "terraform", "path": "foundation/identity",
         "consumes": ["foundation-network"], "produces": ["foundation-identity"]},
        {"id": "platform-shared", "layer": "platform", "kind": "terraform", "path": "platform/shared",
         "consumes": ["foundation-network", "foundation-identity"], "produces": ["platform-shared"]},
        {"id": "platform-containerapps", "layer": "platform", "kind": "terraform", "path": "platform/compute/containerapps",
         "consumes": ["foundation-network", "foundation-identity", "platform-shared"], "produces": ["platform-containerapps"]},
        {"id": "platform-aks", "layer": "platform", "kind": "terraform", "path": "platform/compute/aks",
         "consumes": ["foundation-network", "foundation-identity", "platform-shared"], "produces": ["platform-aks"]},
        {"id": "platform-db-sql", "layer": "platform", "kind": "terraform", "path": "platform/data/sql",
         "consumes": ["foundation-network", "foundation-identity"], "produces": ["platform-db-sql"]},
        {"id": "platform-db-cosmos", "layer": "platform", "kind": "terraform", "path": "platform/data/cosmos",
         "produces": ["platform-db-cosmos"]},
        {"id": "obs-prereqs", "layer": "observability", "kind": "terraform", "path": "observability/lab/prereqs",
         "produces": ["obs-prereqs"]},
        {"id": "obs-telemetry-transport", "layer": "observability", "kind": "terraform",
         "path": "observability/lab/telemetry-transport",
         "consumes": ["foundation-network", "platform-containerapps"], "produces": ["obs-telemetry-transport"]},
        {"id": "obs-monitoring", "layer": "observability", "kind": "terraform", "path": "observability/lab/monitoring",
         "consumes": ["obs-prereqs"], "optional_consumes": ["deploy-core-aks", "deploy-core-aca", "deploy-frontend"],
         "after_deployments": True, "inputs": ["observability/onboarding/**", "observability/archetypes/**"]},
        {"id": "svc-frontend", "layer": "applications", "kind": "artifact", "path": "applications/services/frontend",
         "artifact": {"type": "static-bundle", "name": "hello-frontend"}},
        {"id": "svc-bff", "layer": "applications", "kind": "artifact", "path": "applications/services/bff",
         "inputs": ["applications/shared/dotnet/**"], "artifact": {"type": "container-image", "name": "hello-bff"}},
        {"id": "svc-orders-api", "layer": "applications", "kind": "artifact", "path": "applications/services/orders-api",
         "inputs": ["applications/shared/dotnet/**"], "artifact": {"type": "container-image", "name": "hello-orders-api"}},
        {"id": "deploy-core-aks", "layer": "applications", "kind": "terraform", "path": "applications/deployments/core-aks",
         "consumes": ["platform-aks", "platform-shared", "platform-db-sql", "obs-telemetry-transport"],
         "artifacts": ["svc-bff", "svc-orders-api"], "produces": ["deploy-core-aks"]},
        {"id": "deploy-core-aca", "layer": "applications", "kind": "terraform", "path": "applications/deployments/core-aca",
         "consumes": ["platform-containerapps", "platform-shared", "platform-db-sql", "obs-telemetry-transport"],
         "artifacts": ["svc-bff", "svc-orders-api"], "produces": ["deploy-core-aca"]},
        {"id": "deploy-frontend", "layer": "applications", "kind": "terraform", "path": "applications/deployments/frontend",
         "consumes": ["obs-prereqs"], "optional_consumes": ["deploy-core-aca", "deploy-core-aks"],
         "artifacts": ["svc-frontend"], "produces": ["deploy-frontend"]},
        {"id": "deploy-dbadapters", "layer": "applications", "kind": "terraform", "path": "applications/deployments/dbadapters",
         "consumes": ["platform-db-cosmos"], "produces": ["deploy-dbadapters"]},
        {"id": "docs", "layer": "docs", "kind": "docs", "path": "docs", "inputs": ["**/*.md", "!observability/**/*.md"]},
    ],
}

# everything except AKS (the "minimal"-like fixture profile)
FIXTURE_ENABLED = [c["id"] for c in SYNTHETIC_REGISTRY["components"]
                   if c["kind"] != "docs" and c.get("pipeline") != "manual" and c["id"] not in ("platform-aks", "deploy-core-aks")]
USES_NAMING = {"foundation-network", "foundation-identity", "platform-shared", "platform-db-sql"}


def git(repo: Path, *args: str) -> str:
    proc = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {proc.stderr}")
    return proc.stdout.strip()


def commit_all(repo: Path, message: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message, "--allow-empty")
    return git(repo, "rev-parse", "HEAD")


def write(repo: Path, rel: str, text: str) -> None:
    p = repo / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


def _init(repo: Path) -> None:
    repo.mkdir(parents=True, exist_ok=True)
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "tests@example.com")
    git(repo, "config", "user.name", "tests")
    git(repo, "config", "commit.gpgsign", "false")


def _copy_common(repo: Path) -> None:
    for rel in ("catalog/schemas/component.schema.json", "catalog/schemas/contract-envelope.schema.json",
                "environments/schema/environment.schema.json", "environments/schema/profile.schema.json",
                "environments/schema/retirements.schema.json", "environments/schema/approvals.schema.json",
                "versions.yaml"):
        (repo / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO_ROOT / rel, repo / rel)


def _env_doc(profile: str = "minimal", components: dict | None = None) -> dict:
    doc = yaml.safe_load((REPO_ROOT / "environments/dev/environment.yaml").read_text())
    doc["profile"] = profile
    doc["components"] = components or {}
    return doc


def tf_root(repo: Path, comp: dict, uses_naming: bool) -> None:
    path = comp["path"]
    depth = len(path.split("/"))
    rel_modules = "/".join([".."] * depth) + "/foundation/modules/naming"
    variables = ['variable "environment" {\n  type = any\n}\n', 'variable "settings" {\n  type    = any\n  default = {}\n}\n']
    for c in comp.get("consumes", []) + comp.get("optional_consumes", []):
        variables.append(f'variable "{c.replace("-", "_")}" {{\n  type    = any\n  default = null\n}}\n')
    if comp["id"] == "foundation-network":
        variables.append('variable "network" {\n  type = any\n}\n')
    write(repo, f"{path}/variables.tf", "\n".join(variables))
    main = f'# {comp["id"]}\nlocals {{\n  component = "{comp["id"]}"\n}}\n'
    if uses_naming:
        main += f'\nmodule "naming" {{\n  source = "{rel_modules}"\n}}\n'
    write(repo, f"{path}/main.tf", main)
    write(repo, f"{path}/outputs.tf", 'output "contract" {\n  value = { id = local.component }\n}\n')
    write(repo, f"{path}/README.md", f"# {comp['id']}\n")
    write(repo, f"{path}/tests/plan.tftest.hcl", 'run "plan" {\n  command = plan\n}\n')


def make_synthetic_repo(tmp: Path, enabled: list[str] | None = None, registry: dict | None = None) -> Path:
    repo = tmp / "repo"
    _init(repo)
    _copy_common(repo)
    reg = registry or SYNTHETIC_REGISTRY
    write(repo, "catalog/components.yaml", yaml.safe_dump(reg, sort_keys=False))
    write(repo, "catalog/contracts/foundation-network.v1.schema.json", json.dumps({
        "$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object",
        "required": ["id"], "properties": {"id": {"type": "string"}}}))
    write(repo, "environments/dev/environment.yaml", yaml.safe_dump(_env_doc(), sort_keys=False))
    write(repo, "environments/profiles/minimal.yaml", yaml.safe_dump({
        "profile": "minimal", "description": "fixture", "components": enabled or FIXTURE_ENABLED, "features": {}}))
    write(repo, "foundation/modules/naming/main.tf", 'variable "workload" {\n  type    = string\n  default = "x"\n}\n')
    write(repo, "foundation/modules/naming/README.md", "# naming\n")
    for comp in reg["components"]:
        if comp["kind"] == "terraform":
            tf_root(repo, comp, comp["id"] in USES_NAMING)
        elif comp["kind"] == "artifact":
            write(repo, f"{comp['path']}/src/Program.cs", f"// {comp['id']}\n")
            write(repo, f"{comp['path']}/tests/UnitTests.cs", "// tests\n")
            write(repo, f"{comp['path']}/README.md", f"# {comp['id']}\n")
            write(repo, f"{comp['path']}/Dockerfile", "FROM scratch\n")
    write(repo, "applications/shared/dotnet/Hello.Common/Common.cs", "// shared\n")
    write(repo, "observability/archetypes/web-service.yaml", "monitors: [latency]\n")
    write(repo, "observability/onboarding/services.yaml", "services: [hello-bff]\n")
    write(repo, "docs/index.md", "# docs\n")
    write(repo, "README.md", "# lab\n")
    commit_all(repo, "initial")
    return repo


def make_real_registry_repo(tmp: Path) -> Path:
    repo = tmp / "real"
    _init(repo)
    _copy_common(repo)
    for rel in ("catalog/components.yaml",):
        shutil.copy(REPO_ROOT / rel, repo / rel)
    shutil.copytree(REPO_ROOT / "catalog/contracts", repo / "catalog/contracts")
    shutil.copytree(REPO_ROOT / "environments/profiles", repo / "environments/profiles")
    write(repo, "environments/dev/environment.yaml", (REPO_ROOT / "environments/dev/environment.yaml").read_text())
    reg = yaml.safe_load((REPO_ROOT / "catalog/components.yaml").read_text())
    for comp in reg["components"]:
        if comp["kind"] == "terraform":
            tf_root(repo, comp, False)
        elif comp["kind"] == "artifact":
            write(repo, f"{comp['path']}/src/main.txt", comp["id"] + "\n")
        else:
            write(repo, f"{comp['path']}/index.md", "# docs\n")
    write(repo, "applications/shared/dotnet/Hello.Common/Common.cs", "// shared\n")
    write(repo, "applications/shared/python/hello_common/src/x.py", "# shared\n")
    commit_all(repo, "initial")
    return repo


def record_successful_deployment(repo: Path, records: Path, env: str = "dev") -> dict:
    """Simulate a fully successful deploy-mode run: write a succeeded record for everything selected."""
    from tools.changeset.select import select_deploy

    store = LocalStore(records)
    doc = select_deploy(repo, env, store)
    for cid, e in doc["components"].items():
        if e["plan"] or e["build"] or e["resolve"]:
            store.put_json(f"{env}/{cid}.json", {
                "component": cid, "env": env, "kind": e["kind"], "path": e["path"], "status": "succeeded",
                "deploy_fp": e["deploy_fp"], "fp_parts": e["fp_parts"], "commit": doc["head"],
                "upstream": e["upstream"], "produces": e["produces"], "run_id": "1",
            })
    return doc
