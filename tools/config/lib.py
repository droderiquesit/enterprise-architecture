"""Shared configuration logic used by resolve.py, render.py and tools/changeset.

All functions take a `Tree` so they work for the working tree and for any git commit
(PR mode compares the merge-base with HEAD).
"""

from __future__ import annotations

import hashlib
import json
import re
from typing import List, Optional, Set, Tuple

import yaml

from tools.changeset.graph import Graph
from tools.changeset.registry import Registry
from tools.changeset.trees import Tree
from tools.config.features import FeatureError, feature_settings, validate_features

ENV_SCHEMA = "environments/schema/environment.schema.json"
PROFILE_SCHEMA = "environments/schema/profile.schema.json"
RETIREMENTS_SCHEMA = "environments/schema/retirements.schema.json"
APPROVALS_SCHEMA = "environments/schema/approvals.schema.json"

# ADR-0001 §6: keys of the `environment` object every root declares.
ENVIRONMENT_KEYS = [
    "name", "location", "subscription_id", "tenant_id", "name_prefix",
    "owner", "team", "cost_center", "expires_on", "tags",
]
# Global sections a root may opt into by declaring a variable with the same name.
OPTIONAL_GLOBALS = ["network", "datadog", "budget", "features", "profile_name", "secrets"]

VARIABLE_RE = re.compile(r'^\s*variable\s+"([A-Za-z0-9_]+)"', re.MULTILINE)


class ConfigError(Exception):
    pass


def canonical_json(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _schema_validate(tree: Tree, schema_path: str, doc, what: str) -> None:
    text = tree.read_text(schema_path)
    if text is None:
        return
    import jsonschema

    validator = jsonschema.Draft202012Validator(json.loads(text))
    errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.absolute_path))
    if errors:
        msgs = [f"{'/'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}" for e in errors[:20]]
        raise ConfigError(f"{what} is invalid:\n  " + "\n  ".join(msgs))


def load_environment(tree: Tree, env: str, validate: bool = True) -> dict:
    path = f"environments/{env}/environment.yaml"
    text = tree.read_text(path)
    if text is None:
        raise ConfigError(f"{path} not found")
    doc = yaml.safe_load(text) or {}
    if validate:
        _schema_validate(tree, ENV_SCHEMA, doc, path)
    if doc.get("environment", {}).get("name") not in (None, env):
        raise ConfigError(f"{path}: environment.name '{doc['environment']['name']}' does not match directory '{env}'")
    return doc


def load_profile(tree: Tree, name: str, validate: bool = True) -> dict:
    path = f"environments/profiles/{name}.yaml"
    text = tree.read_text(path)
    if text is None:
        raise ConfigError(f"profile '{name}' not found ({path})")
    doc = yaml.safe_load(text) or {}
    if validate:
        _schema_validate(tree, PROFILE_SCHEMA, doc, path)
        try:
            validate_features(doc.get("features") or {})
        except FeatureError as exc:
            raise ConfigError(f"{path}: {exc}") from None
    return doc


def load_retirements(tree: Tree, env: str) -> List[dict]:
    path = f"environments/{env}/retirements.yaml"
    text = tree.read_text(path)
    if text is None:
        return []
    doc = yaml.safe_load(text) or {}
    _schema_validate(tree, RETIREMENTS_SCHEMA, doc, path)
    return list(doc.get("retirements") or [])


def load_approvals(tree: Tree, env: str) -> List[dict]:
    path = f"environments/{env}/approvals.yaml"
    text = tree.read_text(path)
    if text is None:
        return []
    doc = yaml.safe_load(text) or {}
    _schema_validate(tree, APPROVALS_SCHEMA, doc, path)
    return list(doc.get("allow_destroy") or [])


# --------------------------------------------------------------------- resolve
def resolve_enabled(registry: Registry, graph: Graph, env_doc: dict, profile_doc: dict) -> Tuple[Set[str], List[str]]:
    """Return (enabled component ids, notes).

    custom profile: selected components + automatically added hard upstream dependencies.
    other profiles: the profile list must already be closed under hard dependencies, otherwise
    ConfigError explains exactly which dependency is missing.
    Optional dependencies are never added; they are honoured only when their producer is enabled.
    """
    profile = profile_doc.get("profile") or env_doc.get("profile")
    notes: List[str] = []
    if profile == "custom":
        requested = list(env_doc.get("custom_components") or []) + list(profile_doc.get("components") or [])
    else:
        requested = list(profile_doc.get("components") or [])
    unknown = [c for c in requested if c not in registry]
    if unknown:
        raise ConfigError(f"profile '{profile}' references unknown components: {', '.join(sorted(unknown))}")
    if profile != "custom":
        optional = [c for c in requested if registry.get(c).optional]
        if optional:
            raise ConfigError(f"profile '{profile}' lists optional components {', '.join(sorted(optional))} "
                              "(optional components are enabled only through profile custom / custom_components)")
    enabled: Set[str] = set()
    for cid in requested:
        c = registry.get(cid)
        if c.pipeline == "manual":
            notes.append(f"{cid}: pipeline=manual, never deployed by the universal pipeline (ignored)")
            continue
        if c.is_docs:
            continue
        enabled.add(cid)
    missing: List[str] = []
    changed = True
    while changed:
        changed = False
        for cid in sorted(enabled):
            for up in sorted(graph.hard_upstream(cid)):
                if up in enabled:
                    continue
                upc = registry.get(up)
                if upc.pipeline == "manual":
                    continue
                if profile == "custom":
                    enabled.add(up)
                    notes.append(f"{up}: added automatically (required by {cid})")
                    changed = True
                else:
                    missing.append(f"{cid} requires {up} ({graph.edges[cid][up]} dependency) which is not enabled in profile '{profile}'")
    if missing:
        raise ConfigError("profile is not closed under hard dependencies:\n  " + "\n  ".join(sorted(set(missing))))
    for cid in sorted(enabled):
        for up, kind in graph.upstream(cid).items():
            if kind == "optional" and up not in enabled:
                notes.append(f"{cid}: optional input {up} not enabled (ignored)")
    return enabled, notes


def resolve_for_env(tree: Tree, registry: Registry, graph: Graph, env: str) -> Tuple[Set[str], dict, dict, List[str]]:
    env_doc = load_environment(tree, env)
    profile_name = env_doc.get("profile", "minimal")
    profile_doc = load_profile(tree, profile_name)
    enabled, notes = resolve_enabled(registry, graph, env_doc, profile_doc)
    return enabled, env_doc, profile_doc, notes


# ---------------------------------------------------------------------- render
def deep_merge(base: dict, override: dict) -> dict:
    """Recursive dict merge; `override` wins. Lists and scalars are replaced, not merged."""
    out = dict(base)
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def declared_variables(tree: Tree, root_dir: str) -> Set[str]:
    prefix = root_dir.rstrip("/") + "/"
    names: Set[str] = set()
    for path in tree.files():
        if path.startswith(prefix) and "/" not in path[len(prefix):] and path.endswith(".tf"):
            names.update(VARIABLE_RE.findall(tree.read_text(path) or ""))
    return names


def render_component(tree: Tree, registry: Registry, env_doc: dict, profile_doc: dict, component_id: str,
                     declared: Optional[Set[str]] = None) -> dict:
    """The terraform.tfvars.json content for one component.

    `environment` is the ADR §6 object; `settings` is the deep merge of (lowest to highest precedence)
    the profile `features` mapped by tools/config/features.py, the profile's component_settings.<id>
    and environment.components.<id>.
    Optional globals (network, datadog, budget, features, profile_name, secrets) are included only when the
    root declares a variable of that name, so unrelated global edits never change this component.
    """
    c = registry.get(component_id)
    env = env_doc.get("environment") or {}
    try:
        from_features = feature_settings(profile_doc.get("features") or {}, component_id)
    except FeatureError as exc:
        raise ConfigError(f"profile '{profile_doc.get('profile')}': {exc}") from None
    settings = deep_merge(from_features, (profile_doc.get("component_settings") or {}).get(component_id) or {})
    settings = deep_merge(settings, (env_doc.get("components") or {}).get(component_id) or {})
    rendered = {
        "environment": {k: env.get(k) for k in ENVIRONMENT_KEYS if k in env},
        "settings": settings,
    }
    rendered["environment"].setdefault("tags", {})
    if declared is None:
        declared = declared_variables(tree, c.path) if c.is_terraform else set()
    globals_ = {
        "network": env_doc.get("network"),
        "datadog": env_doc.get("datadog"),
        "budget": env_doc.get("budget"),
        "secrets": env_doc.get("secrets"),
        "features": profile_doc.get("features") or {},
        "profile_name": env_doc.get("profile"),
    }
    for name in OPTIONAL_GLOBALS:
        if name in declared and globals_.get(name) is not None:
            rendered[name] = globals_[name]
    return rendered
