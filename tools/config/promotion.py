#!/usr/bin/env python3
"""Promotion chains (environments/promotion.yaml): build once, promote the same digests.

    python3 tools/config/promotion.py check --env prod --mode auto [--dry-run true|false]
    python3 tools/config/promotion.py source --env test            # prints the promote_from env ('' if it builds)
    python3 tools/config/promotion.py list                          # all environments, chain order

`check` is run by the Select stage: it fails the run early when the mode is not allowed for the
environment (e.g. blanket `reconcile` in prod) or the environment is unknown.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

PROMOTION_FILE = "environments/promotion.yaml"
PROMOTION_SCHEMA = "environments/schema/promotion.schema.json"


class PromotionError(Exception):
    pass


@dataclass
class EnvSpec:
    name: str
    chain: str
    index: int
    ado_environment: str
    retire_environment: str
    allowed_modes: List[str]
    promote_from: Optional[str] = None
    ci_trigger: bool = False
    allow_dry_run: bool = True
    require_apply_approval: bool = False
    raw: dict = field(default_factory=dict)

    @property
    def builds(self) -> bool:
        return self.promote_from is None


def load(repo: Path) -> Dict[str, EnvSpec]:
    path = Path(repo) / PROMOTION_FILE
    if not path.exists():
        raise PromotionError(f"{PROMOTION_FILE} not found")
    doc = yaml.safe_load(path.read_text()) or {}
    schema_path = Path(repo) / PROMOTION_SCHEMA
    if schema_path.exists():
        import jsonschema

        errors = sorted(jsonschema.Draft202012Validator(json.loads(schema_path.read_text())).iter_errors(doc),
                        key=lambda e: list(e.absolute_path))
        if errors:
            raise PromotionError(f"{PROMOTION_FILE} invalid: " + "; ".join(
                f"{'/'.join(str(p) for p in e.absolute_path)}: {e.message}" for e in errors[:10]))
    envs: Dict[str, EnvSpec] = {}
    problems: List[str] = []
    for chain in doc.get("chains", []):
        names = []
        for i, e in enumerate(chain["environments"]):
            name = e["name"]
            if name in envs:
                problems.append(f"environment '{name}' appears in more than one chain position")
            spec = EnvSpec(name=name, chain=chain["name"], index=i, ado_environment=e["ado_environment"],
                           retire_environment=e["retire_environment"], allowed_modes=list(e["allowed_modes"]),
                           promote_from=e.get("promote_from"), ci_trigger=bool(e.get("ci_trigger", False)),
                           allow_dry_run=bool(e.get("allow_dry_run", True)),
                           require_apply_approval=bool(e.get("require_apply_approval", False)), raw=e)
            if i == 0 and spec.promote_from:
                problems.append(f"{name}: the first environment of chain '{chain['name']}' builds and cannot promote_from")
            if i > 0 and spec.promote_from != names[-1]:
                problems.append(f"{name}: promote_from must be the previous environment '{names[-1]}' (got {spec.promote_from!r})")
            if spec.ado_environment != f"lab-{name}" or spec.retire_environment != f"lab-{name}-retire":
                problems.append(f"{name}: ADO environments must be lab-{name} / lab-{name}-retire (template convention)")
            names.append(name)
            envs[name] = spec
    if problems:
        raise PromotionError("; ".join(problems))
    return envs


def check(repo: Path, env: str, mode: str, dry_run: bool) -> List[str]:
    envs = load(repo)
    if env not in envs:
        return [f"environment '{env}' is not part of any promotion chain in {PROMOTION_FILE}"]
    spec = envs[env]
    errors = []
    if mode not in spec.allowed_modes:
        errors.append(f"mode '{mode}' is not allowed for environment '{env}' (allowed: {', '.join(spec.allowed_modes)})")
    if mode == "promote" and not spec.promote_from:
        errors.append(f"environment '{env}' builds from source and cannot be promoted into (first of its chain)")
    if dry_run and not spec.allow_dry_run:
        errors.append(f"dryRun is not allowed for environment '{env}'")
    return errors


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--env", required=True)
    c.add_argument("--mode", required=True)
    c.add_argument("--dry-run", default="false")
    s = sub.add_parser("source")
    s.add_argument("--env", required=True)
    sub.add_parser("list")
    args = ap.parse_args(argv)
    repo = Path(args.repo).resolve()
    try:
        if args.cmd == "check":
            errors = check(repo, args.env, args.mode, str(args.dry_run).lower() == "true")
            for e in errors:
                print(f"ERROR: {e}", file=sys.stderr)
                print(f"##vso[task.logissue type=error]{e}")
            if not errors:
                spec = load(repo)[args.env]
                print(f"{args.env}: mode {args.mode} allowed; "
                      + ("builds artifacts" if spec.builds else f"promotes artifacts from {spec.promote_from}"))
            return 1 if errors else 0
        envs = load(repo)
        if args.cmd == "source":
            if args.env not in envs:
                raise PromotionError(f"unknown environment {args.env}")
            print(envs[args.env].promote_from or "")
            return 0
        for e in sorted(envs.values(), key=lambda x: (x.chain, x.index)):
            print(f"{e.chain}:{e.index} {e.name} <- {e.promote_from or '(builds)'} modes={','.join(e.allowed_modes)}")
        return 0
    except PromotionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
