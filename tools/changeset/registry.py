"""Component registry loading and validation (catalog/components.yaml)."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Dict, List, Optional

import yaml

from .trees import Tree

REGISTRY_PATH = "catalog/components.yaml"
REGISTRY_SCHEMA = "catalog/schemas/component.schema.json"
DEFAULT_TIMEOUT_MINUTES = 60
SCOPES = ("platform", "applications")


def derive_scope(raw: dict) -> str:
    """Owning pipeline: explicit `scope`, else by layer (observability components that read application
    contracts - after_deployments / discovers_resources - belong to the applications pipeline)."""
    if raw.get("scope"):
        return raw["scope"]
    layer = raw.get("layer")
    if layer == "applications":
        return "applications"
    if layer == "observability" and (raw.get("after_deployments") or raw.get("discovers_resources")):
        return "applications"
    return "platform"


class RegistryError(Exception):
    pass


@dataclass
class Component:
    id: str
    layer: str
    kind: str
    path: str
    pipeline: str = "auto"
    produces: List[str] = field(default_factory=list)
    consumes: List[str] = field(default_factory=list)
    optional_consumes: List[str] = field(default_factory=list)
    depends_on: List[str] = field(default_factory=list)
    artifacts: List[str] = field(default_factory=list)
    artifact: Optional[dict] = None
    inputs: List[str] = field(default_factory=list)
    profiles: List[str] = field(default_factory=list)
    catalog_refs: List[str] = field(default_factory=list)
    discovers_resources: bool = False
    after_deployments: bool = False
    timeout_minutes: int = DEFAULT_TIMEOUT_MINUTES
    scope: str = "platform"
    secret_env: Dict[str, str] = field(default_factory=dict)
    dsv_state_output: Optional[str] = None
    secret_outputs: Optional[str] = None
    retry: Dict[str, int] = field(default_factory=dict)          # {attempts, max_minutes} (tools/deploy/retry.py)
    drift_auto_remediate: bool = False                           # drift.auto_remediate (additive-only plan+apply)
    owners: List[str] = field(default_factory=list)              # review groups (default: branching.yaml owners_by_layer)
    optional: bool = False                                       # in no built-in profile; enabled via profile custom
    raw: dict = field(default_factory=dict)

    @property
    def is_terraform(self) -> bool:
        return self.kind == "terraform"

    @property
    def is_artifact(self) -> bool:
        return self.kind == "artifact"

    @property
    def is_docs(self) -> bool:
        return self.kind == "docs"

    @property
    def deployable(self) -> bool:
        """Terraform roots handled by the universal pipeline (bootstrap is manual)."""
        return self.kind == "terraform" and self.pipeline != "manual"

    @property
    def var_id(self) -> str:
        return var_id(self.id)

    @property
    def stage_name(self) -> str:
        return "C_" + self.var_id

    def canonical(self) -> str:
        return json.dumps(self.raw, sort_keys=True, separators=(",", ":"))


def var_id(component_id: str) -> str:
    return component_id.replace("-", "_")


@dataclass
class Registry:
    components: Dict[str, Component]
    producers: Dict[str, str]  # contract name -> producing component id

    def __iter__(self):
        return iter(self.components.values())

    def __contains__(self, cid: str) -> bool:
        return cid in self.components

    def get(self, cid: str) -> Component:
        try:
            return self.components[cid]
        except KeyError:
            raise RegistryError(f"unknown component '{cid}'") from None

    def producer_of(self, contract_or_component: str) -> Optional[str]:
        """Resolve a consumes entry (contract name, or a component id) to a component id."""
        if contract_or_component in self.producers:
            return self.producers[contract_or_component]
        if contract_or_component in self.components:
            return contract_or_component
        return None

    def contract_name_for(self, entry: str) -> str:
        return entry

    def owner_paths(self) -> Dict[str, str]:
        return {c.path.rstrip("/"): c.id for c in self}


def _validate_schema(tree: Tree, doc: dict) -> None:
    text = tree.read_text(REGISTRY_SCHEMA)
    if text is None:
        return
    try:
        import jsonschema
    except ImportError:  # pragma: no cover - jsonschema is a declared dependency
        return
    schema = json.loads(text)
    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.absolute_path))
    if errors:
        msgs = [f"{'/'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}" for e in errors[:20]]
        raise RegistryError("component registry does not match schema:\n  " + "\n  ".join(msgs))


def scope_errors(reg: "Registry") -> List[str]:
    """The platform pipeline runs first and must never wait for the applications pipeline."""
    errors = []
    for c in reg:
        if c.scope != "platform":
            continue
        ups = list(c.depends_on) + list(c.artifacts) + [reg.producer_of(e) for e in c.consumes + c.optional_consumes]
        for up in ups:
            if up in reg.components and reg.components[up].scope == "applications":
                errors.append(f"{c.id} (scope platform) depends on {up} (scope applications): "
                              f"set `scope: applications` on {c.id} or remove the dependency")
    return errors


def load_registry(tree: Tree, path: str = REGISTRY_PATH) -> Registry:
    text = tree.read_text(path)
    if text is None:
        raise RegistryError(f"{path} not found in {tree.label}")
    doc = yaml.safe_load(text) or {}
    _validate_schema(tree, doc)
    components: Dict[str, Component] = {}
    producers: Dict[str, str] = {}
    errors: List[str] = []
    seen_paths: Dict[str, str] = {}
    for raw in doc.get("components", []):
        c = Component(
            id=raw["id"],
            layer=raw["layer"],
            kind=raw["kind"],
            path=raw["path"].rstrip("/"),
            pipeline=raw.get("pipeline", "auto"),
            produces=list(raw.get("produces", [])),
            consumes=list(raw.get("consumes", [])),
            optional_consumes=list(raw.get("optional_consumes", [])),
            depends_on=list(raw.get("depends_on", [])),
            artifacts=list(raw.get("artifacts", [])),
            artifact=raw.get("artifact"),
            inputs=list(raw.get("inputs", [])),
            profiles=list(raw.get("profiles", [])),
            catalog_refs=list(raw.get("catalog_refs", [])),
            discovers_resources=bool(raw.get("discovers_resources", False)),
            after_deployments=bool(raw.get("after_deployments", False)),
            timeout_minutes=int(raw.get("timeout_minutes", DEFAULT_TIMEOUT_MINUTES)),
            scope=derive_scope(raw),
            secret_env=dict(raw.get("secret_env") or {}),
            dsv_state_output=raw.get("dsv_state_output"),
            secret_outputs=raw.get("secret_outputs"),
            retry=dict(raw.get("retry") or {}),
            drift_auto_remediate=bool((raw.get("drift") or {}).get("auto_remediate", False)),
            owners=list(raw.get("owners") or []),
            optional=bool(raw.get("optional", False)),
            raw=raw,
        )
        if c.id in components:
            errors.append(f"duplicate component id '{c.id}'")
        if c.path in seen_paths:
            errors.append(f"components '{seen_paths[c.path]}' and '{c.id}' share path '{c.path}'")
        seen_paths[c.path] = c.id
        components[c.id] = c
        for p in c.produces:
            if p in producers:
                errors.append(f"contract '{p}' produced by both '{producers[p]}' and '{c.id}'")
            producers[p] = c.id
        if c.kind == "artifact" and not c.artifact:
            errors.append(f"artifact component '{c.id}' has no 'artifact' block")
    reg = Registry(components, producers)
    for c in reg:
        for entry in c.consumes + c.optional_consumes:
            if reg.producer_of(entry) is None:
                errors.append(f"{c.id}: consumes '{entry}' but no component produces it")
        for dep in c.depends_on:
            if dep not in components:
                errors.append(f"{c.id}: depends_on unknown component '{dep}'")
        for art in c.artifacts:
            if art not in components:
                errors.append(f"{c.id}: artifacts references unknown component '{art}'")
            elif components[art].kind != "artifact":
                errors.append(f"{c.id}: artifacts entry '{art}' is not an artifact component")
        if (c.secret_env or c.dsv_state_output or c.secret_outputs) and c.kind != "terraform":
            errors.append(f"{c.id}: secret_env / dsv_state_output / secret_outputs are only valid on terraform components")
        if c.artifacts and c.kind != "terraform":
            errors.append(f"{c.id}: only terraform components can declare artifacts")
    if errors:
        raise RegistryError("invalid component registry:\n  " + "\n  ".join(errors))
    return reg
