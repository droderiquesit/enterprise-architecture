#!/usr/bin/env python3
"""Check Terraform version pins against versions.yaml (ADR §2).

    python3 tools/validate/versions.py [--strict]

For every Terraform root in the registry (that exists on disk) and every module directory:
  - `required_version` equals versions.yaml terraform.required_version (roots: mandatory; modules: if set)
  - every `required_providers` entry with a source listed in versions.yaml uses exactly its constraint
  - providers not listed in versions.yaml are errors (except hashicorp/azuread in bootstrap, ADR §2)
  - roots have a committed .terraform.lock.hcl whose provider versions equal versions.yaml versions (roots without
    providers, e.g. foundation/secrets, have none: terraform init creates no lock file for built-ins)
Registry roots that do not exist yet are reported (failure only with --strict).
Image pins shared with the observability fleet policy (single Agent pin, package 4.0.0):
  - images.datadog_agent           == observability/config/fleet-policy.yaml agent.image:agent.version
  - images.datadog_serverless_init == fleet-policy agent.serverless_init.image:agent.serverless_init.version
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402

ALLOWED_EXTRA = {("bootstrap", "hashicorp/azuread")}
REQ_VERSION_RE = re.compile(r'required_version\s*=\s*"([^"]+)"')
PROVIDER_ENTRY_RE = re.compile(r'([A-Za-z0-9_-]+)\s*=\s*\{([^{}]*)\}', re.S)
ATTR_RE = re.compile(r'(source|version)\s*=\s*"([^"]+)"')
LOCK_RE = re.compile(r'provider\s+"registry\.terraform\.io/([^"]+)"\s*\{[^}]*?version\s*=\s*"([^"]+)"', re.S)


def _block(text: str, keyword: str) -> str | None:
    """Concatenated bodies of every top-level `<keyword> {` block (a root may split terraform {} blocks)."""
    bodies = []
    for m in re.finditer(r"(?m)^\s*" + keyword + r"\s*\{", text):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        bodies.append(text[m.end(): i - 1])
    return "\n".join(bodies) if bodies else None


def check_dir(repo: Path, rel: str, pins: dict, is_root: bool, owner: str) -> tuple[list[str], list[str]]:
    errors, notes = [], []
    d = repo / rel
    tf_text = "\n".join(p.read_text() for p in sorted(d.glob("*.tf")))
    tf_block = _block(tf_text, "terraform")
    req = REQ_VERSION_RE.search(tf_block or "")
    want_req = pins["required_version"]
    if req and req.group(1) != want_req:
        errors.append(f"{rel}: required_version '{req.group(1)}' != '{want_req}'")
    if is_root and not req:
        errors.append(f"{rel}: missing terraform.required_version")
    providers = {}
    rp = _block(tf_block or "", "required_providers")
    for name, body in PROVIDER_ENTRY_RE.findall(rp or ""):
        attrs = dict(ATTR_RE.findall(body))
        source = attrs.get("source", f"hashicorp/{name}")
        providers[source.lower()] = attrs.get("version")
    pinned = {k.lower(): v for k, v in pins["providers"].items()}
    for source, constraint in providers.items():
        if source not in pinned:
            if (owner, source) not in ALLOWED_EXTRA:
                errors.append(f"{rel}: provider {source} is not pinned in versions.yaml")
            continue
        if constraint != pinned[source]["constraint"]:
            errors.append(f"{rel}: {source} constraint '{constraint}' != '{pinned[source]['constraint']}'")
    if is_root and not providers and not (d / ".terraform.lock.hcl").exists():
        notes.append(f"{rel}: no providers (built-ins only) - no lock file needed")
    elif is_root:
        lock = d / ".terraform.lock.hcl"
        if not lock.exists():
            errors.append(f"{rel}: missing committed .terraform.lock.hcl")
        else:
            for source, version in LOCK_RE.findall(lock.read_text()):
                src = source.lower()
                if src in pinned and version != pinned[src]["version"]:
                    errors.append(f"{rel}: lock file pins {source} {version}, versions.yaml says {pinned[src]['version']}")
            locked = {s.lower() for s, _ in LOCK_RE.findall(lock.read_text())}
            for source in providers:
                if source not in locked:
                    errors.append(f"{rel}: provider {source} missing from .terraform.lock.hcl")
    return errors, notes


FLEET_POLICY = "observability/config/fleet-policy.yaml"


def check_fleet_pins(repo: Path, images: dict) -> list[str]:
    """versions.yaml images.* that the fleet policy also pins must be identical (one Agent version for the fleet)."""
    path = repo / FLEET_POLICY
    if not path.exists():
        return []
    agent = (yaml.safe_load(path.read_text()) or {}).get("agent") or {}
    errors = []
    pairs = {
        "datadog_agent": (agent.get("image"), agent.get("version")),
        "datadog_serverless_init": ((agent.get("serverless_init") or {}).get("image"), (agent.get("serverless_init") or {}).get("version")),
    }
    for key, (image, version) in pairs.items():
        want = f"{image}:{version}" if image and version else None
        have = images.get(key)
        if want is None:
            errors.append(f"{FLEET_POLICY}: agent pin for versions.yaml images.{key} missing")
        elif have != want:
            errors.append(f"versions.yaml images.{key} '{have}' != {FLEET_POLICY} '{want}'")
    return errors


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args(argv)
    repo = Path(args.repo).resolve()
    versions = yaml.safe_load((repo / "versions.yaml").read_text())
    tf = versions["terraform"]
    pins = {"required_version": tf["required_version"],
            "providers": {k: {"version": str(v["version"]), "constraint": v["constraint"]} for k, v in tf["providers"].items()}}
    reg = load_registry(WorkTree(repo))
    errors, missing, checked = [], [], 0
    for c in reg:
        if not c.is_terraform:
            continue
        if not (repo / c.path).is_dir() or not list((repo / c.path).glob("*.tf")):
            missing.append(c.path)
            continue
        e, _ = check_dir(repo, c.path, pins, True, c.id)
        errors += e
        checked += 1
    for d in sorted({p.parent for p in repo.glob("**/modules/*/*.tf") if ".terraform" not in p.parts}):
        rel = d.relative_to(repo).as_posix()
        e, _ = check_dir(repo, rel, pins, False, rel.split("/")[0])
        errors += e
        checked += 1
    errors += check_fleet_pins(repo, versions.get("images") or {})
    for e in errors:
        print(f"ERROR: {e}")
    if missing:
        print(f"{'ERROR' if args.strict else 'note'}: {len(missing)} registry roots not present yet: {', '.join(missing)}")
    print(f"versions: checked {checked} directories, {len(errors)} error(s)")
    return 1 if errors or (args.strict and missing) else 0


if __name__ == "__main__":
    sys.exit(main())
