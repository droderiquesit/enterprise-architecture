"""The lab's DSV secret catalogue (foundation/identity/secrets.yaml) joined with the component registry.

required_names(env) = catalogue secrets whose `required_by` lists an enabled component
                      + non-optional `secret_env` entries of enabled components (catalog/components.yaml).
"""

from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Optional, Set

import yaml

CATALOGUE = "foundation/identity/secrets.yaml"


def load_catalogue(repo: Path) -> Dict[str, dict]:
    return (yaml.safe_load((repo / CATALOGUE).read_text()) or {}).get("secrets") or {}


def enabled_components(repo: Path, env: str) -> Set[str]:
    from tools.changeset.graph import Graph
    from tools.changeset.registry import load_registry
    from tools.changeset.trees import WorkTree
    from tools.config.lib import resolve_for_env

    tree = WorkTree(repo)
    reg = load_registry(tree)
    enabled, _env, _profile, _notes = resolve_for_env(tree, reg, Graph(reg), env)
    return set(enabled)


def secret_env_of(repo: Path, component: str) -> Dict[str, str]:
    from tools.changeset.registry import load_registry
    from tools.changeset.trees import WorkTree

    return dict(load_registry(WorkTree(repo)).get(component).secret_env)


def required(repo: Path, env: str, enabled: Optional[Set[str]] = None) -> Dict[str, List[str]]:
    """{secret name: [components that need it]} for one environment."""
    from tools.changeset.registry import load_registry
    from tools.changeset.trees import WorkTree

    enabled = enabled if enabled is not None else enabled_components(repo, env)
    out: Dict[str, List[str]] = {}
    for name, meta in load_catalogue(repo).items():
        users = sorted(set(meta.get("required_by") or []) & enabled)
        if users:
            out[name] = users
    for c in load_registry(WorkTree(repo)):
        if c.id not in enabled:
            continue
        for spec in c.secret_env.values():
            if spec.endswith("?") or spec.startswith("dsv://"):
                continue
            name = spec.split("#", 1)[0]
            out.setdefault(name, [])
            if c.id not in out[name]:
                out[name].append(c.id)
    return dict(sorted(out.items()))
