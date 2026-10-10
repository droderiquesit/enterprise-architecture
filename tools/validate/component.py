#!/usr/bin/env python3
"""Validate one component (one leg of the Validate stage matrix). No credentials needed.

    python3 tools/validate/component.py --component foundation-network [--env dev]

terraform  tools/validate/terraform.sh <path> + render.py --stdout (settings render for the env)
artifact   unit tests by detected toolchain: .NET (dotnet test on *Tests.csproj), Python (pytest when a
           tests/ dir exists, after installing the shared package and the service), Node (npm ci, npm test,
           npm run build); otherwise structure-only
docs       relative Markdown links resolve
module:<dir> shared Terraform module changed in a PR (tools/validate/terraform.sh <dir>)
A registry component whose path does not exist yet is reported as `cataloged` (not a failure).
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
CPUS = int(os.environ.get("CI_CPUS") or os.cpu_count() or 2)
# pytest-xdist when available (pipelines/requirements-tools.txt): one worker per CPU, files kept together
XDIST = ["-n", str(CPUS), "--dist", "loadfile"] if importlib.util.find_spec("xdist") and CPUS > 1 else []


def run(cmd, cwd=None) -> int:
    print("+ " + " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, cwd=cwd).returncode


def validate_terraform(repo: Path, comp, env: str) -> int:
    rc = run(["bash", "tools/validate/terraform.sh", comp.path], cwd=repo)
    if rc == 0 and comp.pipeline != "manual":
        rc = run([sys.executable, "tools/config/render.py", "--env", env, "--component", comp.id, "--stdout"], cwd=repo)
    return rc


def validate_artifact(repo: Path, comp) -> int:
    path = repo / comp.path
    rc = 0
    test_projects = sorted(p for p in path.rglob("*.csproj") if p.stem.endswith("Tests"))
    if test_projects:
        # Microsoft.Testing.Platform runner (applications/dotnet/global.json applies from that directory): all test
        # projects of the component in one invocation, modules in parallel, parallel MSBuild nodes
        dotnet_dir = repo / "applications/dotnet"
        cmd = ["dotnet", "test", "-c", "Release", "--max-parallel-test-modules", str(CPUS)]   # MSBuild builds in parallel by default
        for proj in test_projects:
            cmd += ["--project", os.path.relpath(proj, dotnet_dir)]
        return run(cmd, cwd=dotnet_dir if dotnet_dir.is_dir() else repo)
    if list(path.rglob("*.csproj")):
        return run(["dotnet", "build", str(next(path.rglob("*.csproj"))), "--configuration", "Release"], cwd=repo)
    if (path / "package.json").exists():
        rc |= run(["npm", "ci", "--no-audit", "--no-fund"], cwd=path)
        rc |= run(["npm", "test", "--if-present"], cwd=path)
        rc |= run(["npm", "run", "build", "--if-present"], cwd=path)
        return rc
    py_build = repo / "applications/python/build.sh"
    if py_build.exists() and comp.path.startswith("applications/services/") and \
            f"{Path(comp.path).name}" in (py_build.read_text().split('SERVICES="', 1)[-1].split('"', 1)[0]).split(","):
        # the application team's canonical test path: an isolated venv from the service's pinned requirements +
        # pinned test deps (pytest-asyncio, ...); xdist through the build script's TEST_DEPS_EXTRA hook
        env = dict(os.environ)
        if CPUS > 1:
            env.update(TEST_DEPS_EXTRA="pytest-xdist==3.8.0", PYTEST_ADDOPTS=f"-n {CPUS} --dist loadfile")
        print(f"+ applications/python/build.sh --steps lint,test --services {Path(comp.path).name}", flush=True)
        return subprocess.run(["bash", str(py_build), "--steps", "lint,test", "--services", Path(comp.path).name],
                              cwd=repo, env=env).returncode
    if (path / "pyproject.toml").exists() or (path / "requirements.txt").exists():
        # isolated venv per component (never the agent's / developer's system Python), created with uv when present
        shared = repo / "applications/shared/python/hello_common"
        venv = repo / ".ci-cache" / "venvs" / comp.id
        uv = shutil.which("uv")
        if not (venv / "bin" / "python").exists():
            rc |= run([uv, "venv", "--quiet", "--python", sys.executable, str(venv)] if uv
                      else [sys.executable, "-m", "venv", str(venv)])
        py = str(venv / "bin" / "python")
        pip = [uv, "pip", "install", "--quiet", "--python", py] if uv else [py, "-m", "pip", "install", "--quiet"]
        if (path / "requirements.txt").exists():
            rc |= run([*pip, "-r", str(path / "requirements.txt")])
        leftovers = [d for d in (path / "build", shared / "build") if not d.exists()]
        rc |= run([*pip, "pytest==9.1.1", "pytest-xdist==3.8.0", *([str(shared)] if shared.exists() else []),
                   *([str(path)] if (path / "pyproject.toml").exists() else [])])
        for d in leftovers:          # setuptools writes build/ into the source tree: never leave it behind
            shutil.rmtree(d, ignore_errors=True)
        if (path / "tests").is_dir() and rc == 0:
            rc |= run([py, "-m", "pytest", "-q", "-p", "no:cacheprovider", *XDIST, str(path / "tests")], cwd=repo)
        return rc
    if (path / "tests").is_dir() and list(path.glob("*.py")):
        # stdlib-only Python helpers (e.g. observability/images/dsv-fetch): unit tests only
        return run([sys.executable, "-m", "pytest", "-q", *XDIST, str(path / "tests")], cwd=repo)
    print(f"{comp.id}: no recognised toolchain; structure only")
    return 0


def validate_docs(repo: Path, comp) -> int:
    tree = WorkTree(repo)
    broken = []
    for p in tree.files():
        if not p.endswith(".md"):
            continue
        text = tree.read_text(p) or ""
        for link in LINK_RE.findall(text):
            if re.match(r"^[a-z]+:", link) or link.startswith("#"):
                continue
            target = (repo / Path(p).parent / link.split("#", 1)[0]).resolve()
            if link.split("#", 1)[0] and not target.exists():
                broken.append(f"{p}: {link}")
    for b in broken:
        print(f"broken link: {b}")
    return 1 if broken else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--component", required=True)
    ap.add_argument("--env", default="dev")
    ap.add_argument("--repo", default=".")
    args = ap.parse_args(argv)
    repo = Path(args.repo).resolve()
    if args.component.startswith("module:"):
        path = args.component.split(":", 1)[1]
        return run(["bash", "tools/validate/terraform.sh", path], cwd=repo)
    comp = load_registry(WorkTree(repo)).get(args.component)
    if not (repo / comp.path).exists():
        print(f"{comp.id}: {comp.path} does not exist yet (status: cataloged) - nothing to validate")
        return 0
    if comp.is_terraform:
        return validate_terraform(repo, comp, args.env)
    if comp.is_artifact:
        return validate_artifact(repo, comp)
    return validate_docs(repo, comp)


if __name__ == "__main__":
    sys.exit(main())
