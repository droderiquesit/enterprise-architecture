#!/usr/bin/env python3
"""Validate one component (one leg of the Validate stage matrix). No credentials needed.

    python3 tools/validate/component.py --component foundation-network [--env dev]

terraform  tools/validate/terraform.sh <path> + render.py --stdout (settings render for the env)
artifact   unit tests by detected toolchain: .NET (dotnet test on *Tests.csproj), Python (pytest when a
           tests/ dir exists, after installing the shared package and the service), Node (npm ci, npm test,
           npm run build); otherwise structure-only
docs       relative Markdown links resolve
A registry component whose path does not exist yet is reported as `cataloged` (not a failure).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")


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
        for proj in test_projects:
            rc |= run(["dotnet", "test", str(proj), "--configuration", "Release"], cwd=repo)
        return rc
    if list(path.rglob("*.csproj")):
        return run(["dotnet", "build", str(next(path.rglob("*.csproj"))), "--configuration", "Release"], cwd=repo)
    if (path / "package.json").exists():
        rc |= run(["npm", "ci", "--no-audit", "--no-fund"], cwd=path)
        rc |= run(["npm", "test", "--if-present"], cwd=path)
        rc |= run(["npm", "run", "build", "--if-present"], cwd=path)
        return rc
    if (path / "pyproject.toml").exists() or (path / "requirements.txt").exists():
        shared = repo / "applications/shared/python/hello_common"
        if (path / "requirements.txt").exists():
            rc |= run([sys.executable, "-m", "pip", "install", "--quiet", "-r", str(path / "requirements.txt")])
        if shared.exists():
            rc |= run([sys.executable, "-m", "pip", "install", "--quiet", str(shared)])
        if (path / "pyproject.toml").exists():
            rc |= run([sys.executable, "-m", "pip", "install", "--quiet", str(path)])
        if (path / "tests").is_dir():
            rc |= run([sys.executable, "-m", "pytest", "-q", str(path / "tests")], cwd=repo)
        return rc
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
