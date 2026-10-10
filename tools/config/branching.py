#!/usr/bin/env python3
"""Branching model enforcement (environments/branching.yaml): which branch may run which mode where.

    python3 tools/config/branching.py check --ref refs/heads/feature/x --reason Manual --env dev --mode auto --dry-run false
    python3 tools/config/branching.py kind --ref refs/heads/release/2026.10

Trunk-based development:
  trunk (main)            every mode the environment allows (environments/promotion.yaml); CI deploys dev
  release/<yyyy.mm>       only `release.modes` (hotfix / promote / drift) into `release.environments` (test, prod),
                          same gates as main (hotfix = promote of cherry-picked fixes, tools/changeset select_hotfix)
  short-lived / other     never apply: only `dryRun: true` runs in the first environment of the chain (PR
                          validation is the normal path); scheduled runs only on the trunk
  PR builds               always allowed (they never receive credentials)
  tags                    observability-v* package release only (platform pipeline release stage)
The pipelines also compile non-trunk/non-release runs as dry runs (pipelines/templates/universal.yml), so even a
bypassed check cannot apply.
"""

from __future__ import annotations

import argparse
import fnmatch
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import List

import yaml

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
BRANCHING_FILE = "environments/branching.yaml"


@dataclass
class Model:
    trunk: str = "main"
    short_lived: List[str] = field(default_factory=lambda: ["feature/*", "fix/*"])
    release_pattern: str = "release/*"
    release_regex: str = r"^release/\d{4}\.\d{2}$"
    release_modes: List[str] = field(default_factory=lambda: ["hotfix", "promote", "drift"])
    release_envs: List[str] = field(default_factory=lambda: ["test", "prod"])
    package_tag: str = "observability-v*"
    raw: dict = field(default_factory=dict)


def load(repo: Path = REPO) -> Model:
    p = Path(repo) / BRANCHING_FILE
    if not p.exists():
        return Model()
    doc = yaml.safe_load(p.read_text()) or {}
    rel = doc.get("release") or {}
    return Model(trunk=doc.get("trunk", "main"), short_lived=list(doc.get("short_lived") or []),
                 release_pattern=rel.get("pattern", "release/*"), release_regex=rel.get("name_regex", r"^release/.+$"),
                 release_modes=list(rel.get("modes") or []), release_envs=list(rel.get("environments") or []),
                 package_tag=(doc.get("tags") or {}).get("package", "observability-v*"), raw=doc)


def kind(model: Model, ref: str) -> str:
    """trunk | release | short-lived | other | tag | pr"""
    if ref.startswith("refs/pull/"):
        return "pr"
    if ref.startswith("refs/tags/"):
        return "tag"
    branch = ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref
    if branch == model.trunk:
        return "trunk"
    if fnmatch.fnmatch(branch, model.release_pattern):
        return "release"
    if any(fnmatch.fnmatch(branch, p) for p in model.short_lived):
        return "short-lived"
    return "other"


def check(repo: Path, ref: str, reason: str, env: str, mode: str, dry_run: bool) -> List[str]:
    model = load(repo)
    k = kind(model, ref)
    branch = ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref
    if reason == "PullRequest" or k == "pr":
        return []
    if k == "tag":
        tag = ref[len("refs/tags/"):]
        return [] if fnmatch.fnmatch(tag, model.package_tag) else [f"tag '{tag}' does not match {model.package_tag}: tags only release the package"]
    errors: List[str] = []
    if reason == "Schedule" and k != "trunk":
        errors.append(f"scheduled runs only run on '{model.trunk}' (branch '{branch}')")
    if mode == "hotfix" and k != "release":
        errors.append(f"mode 'hotfix' only runs from {model.release_pattern} branches (cherry-picked fixes), not '{branch}'")
    if k == "trunk":
        return errors
    if k == "release":
        if not re.match(model.release_regex, branch):
            errors.append(f"release branch '{branch}' must match {model.release_regex} (release/<yyyy.mm>)")
        if mode not in model.release_modes:
            errors.append(f"release branches only run modes {model.release_modes} (got '{mode}')")
        if env not in model.release_envs:
            errors.append(f"release branches only deploy to {model.release_envs} (got '{env}'); fixes land on "
                          f"'{model.trunk}' first and reach dev from there")
        return errors
    # short-lived / other branches never apply
    from tools.config.promotion import load as load_promotion

    try:
        first = [n for n, s in load_promotion(Path(repo)).items() if not s.promote_from]
    except Exception:  # noqa: BLE001 - a broken promotion.yaml fails `promotion.py check` in the same Select step
        first = ["dev"]
    if not dry_run:
        errors.append(f"branch '{branch}' ({k}) can never apply: open a PR into '{model.trunk}', or queue dryRun: true")
    if env not in first:
        errors.append(f"branch '{branch}' ({k}) may only plan against {first}, not '{env}'")
    if mode in ("promote", "hotfix", "retire"):
        errors.append(f"mode '{mode}' is not available from branch '{branch}'")
    return errors


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--ref", required=True, help="Build.SourceBranch")
    c.add_argument("--reason", default="Manual", help="Build.Reason")
    c.add_argument("--env", required=True)
    c.add_argument("--mode", required=True)
    c.add_argument("--dry-run", default="false")
    c.add_argument("--repo", default=str(REPO))
    k = sub.add_parser("kind")
    k.add_argument("--ref", required=True)
    args = ap.parse_args(argv)
    if args.cmd == "kind":
        print(kind(load(), args.ref))
        return 0
    errors = check(Path(args.repo), args.ref, args.reason, args.env, args.mode, str(args.dry_run).lower() == "true")
    for e in errors:
        print(f"##vso[task.logissue type=error]branching policy: {e}")
        print(f"ERROR: {e}", file=sys.stderr)
    if not errors:
        print(f"branching policy: {kind(load(Path(args.repo)), args.ref)} '{args.ref}' may run mode {args.mode} in {args.env}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
