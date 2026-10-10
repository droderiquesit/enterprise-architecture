"""ServiceOnboarding manifest v2 library: identity + tags + resources + telemetry routing (package 3.0.0).

A manifest declares who a service is (identity, rendered into a Datadog tag set through the tag policy,
config/tag-policy.yaml), which Azure resources belong to it, and how its telemetry is collected (log route, APM mode,
profiler, DBM, RUM application). Rendering is deterministic; the committed output feeds Terraform (diagnostic-settings
targets, Observability Pipelines / aggregator resource-scope tags, OTel gateway per-service defaults, instrumentation
identity) and tools/tags/check_coverage.py. The package creates no monitors / SLOs / dashboards: the 2.x content
sections are ignored here (notice) and used only by the optional extras/content add-on.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

try:  # jsonschema is a hard requirement for validate.py, optional for render-only use.
    import jsonschema
except ImportError:  # pragma: no cover
    jsonschema = None

PACKAGE_ROOT = Path(__file__).resolve().parents[2]  # observability/
SCHEMA_DIR = PACKAGE_ROOT / "schemas"
MANIFEST_SCHEMA = "onboarding-manifest.v2.schema.json"
RENDERED_SCHEMA_FILE = "rendered-service.v2.schema.json"
RENDERED_SCHEMA = "rendered-service/v2"

sys.path.insert(0, str(PACKAGE_ROOT / "tools" / "tags"))
from tag_policy import TagPolicy  # noqa: E402

REF_RE = re.compile(r"\$\{contract:([A-Za-z0-9_-]+)((?:\.[A-Za-z0-9_-]+)+)\}")
ARM_ID_RE = re.compile(r"^/subscriptions/[0-9a-fA-F-]{36}(/resourceGroups/[^/]+(/providers/[A-Za-z]+\.[A-Za-z]+/.+)?)?$")
DEPRECATED_SPEC = ("monitors", "notifications", "catalog", "endpoints", "slos", "idle_behavior", "dashboards")
LOG_ROUTE_BY_ARCH = {
    "aks": "daemonset", "aro": "daemonset", "vm": "host", "vmss": "host", "batch": "host", "aca": "sidecar", "aci": "sidecar",
    "appservice": "eventhub", "functions": "eventhub", "logicapp": "eventhub", "swa": "none", "external": "none",
}
IDENTITY_KEYS = ("team", "owner", "application", "domain", "tier", "region", "cost_center", "component")


class OnboardingError(Exception):
    """A manifest problem that must fail the run."""


@dataclass
class Diagnostics:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    notices: list[str] = field(default_factory=list)

    def error(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)

    def notice(self, msg: str) -> None:
        """Informational (deprecations): never fails --strict."""
        self.notices.append(msg)


# --------------------------------------------------------------------------- io helpers
def load_yaml(path: Path) -> Any:
    with Path(path).open(encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def load_schema(name: str) -> dict:
    return json.loads((SCHEMA_DIR / name).read_text(encoding="utf-8"))


def schema_errors(document: Any, schema_name: str) -> list[str]:
    if jsonschema is None:
        raise OnboardingError("python package 'jsonschema' is required for schema validation")
    validator = jsonschema.Draft202012Validator(load_schema(schema_name))
    out = []
    for err in sorted(validator.iter_errors(document), key=lambda e: [str(p) for p in e.absolute_path]):
        loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
        out.append(f"{loc}: {err.message}")
    return out


def dump_json(data: Any) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


# --------------------------------------------------------------------------- references
def find_refs(value: Any) -> list[str]:
    out: list[str] = []
    if isinstance(value, str):
        out.extend(m.group(1) + m.group(2) for m in REF_RE.finditer(value))
    elif isinstance(value, dict):
        for v in value.values():
            out.extend(find_refs(v))
    elif isinstance(value, list):
        for v in value:
            out.extend(find_refs(v))
    return out


def flatten_contracts(contracts_dir: Path) -> dict[str, str]:
    """Flatten contract JSON files into {'<contract>.<dot.path>': 'scalar'}.

    Accepted layouts: <dir>/<contract>.json or <dir>/<contract>/v<major>.json; either the ADR-0001 envelope
    ({"contract", "data", ...}) or the bare data object. Only the highest major version per contract is used.
    """
    contracts_dir = Path(contracts_dir)
    found: dict[str, tuple[int, Path]] = {}
    for p in sorted(contracts_dir.glob("*.json")):
        found[p.stem] = (0, p)
    for p in sorted(contracts_dir.glob("*/v*.json")):
        m = re.fullmatch(r"v(\d+)", p.stem)
        if m:
            major = int(m.group(1))
            if p.parent.name not in found or found[p.parent.name][0] <= major:
                found[p.parent.name] = (major, p)
    flat: dict[str, str] = {}
    for name, (_, path) in sorted(found.items()):
        doc = json.loads(path.read_text(encoding="utf-8"))
        data = doc["data"] if isinstance(doc, dict) and "data" in doc and "contract" in doc else doc
        _flatten(name, data, flat)
    return flat


def _flatten(prefix: str, value: Any, out: dict[str, str]) -> None:
    if isinstance(value, dict):
        for k, v in value.items():
            _flatten(f"{prefix}.{k}", v, out)
    elif isinstance(value, list):
        for i, v in enumerate(value):
            _flatten(f"{prefix}.{i}", v, out)
    elif value is None:
        return
    elif isinstance(value, bool):
        out[prefix] = "true" if value else "false"
    else:
        out[prefix] = str(value)


def resolve_string(value: str, refs: dict[str, str]) -> tuple[str | None, list[str]]:
    missing: list[str] = []

    def repl(m: re.Match) -> str:
        key = m.group(1) + m.group(2)
        if key not in refs:
            missing.append(key)
            return m.group(0)
        return refs[key]

    out = REF_RE.sub(repl, value)
    return (None if missing else out), missing


# --------------------------------------------------------------------------- rendering
@dataclass
class RenderResult:
    service: str
    env: str
    data: dict


def manifest_envs(manifest: dict) -> list[str]:
    env = manifest["metadata"]["env"]
    return [env] if isinstance(env, str) else list(env)


def identity_of(manifest: dict, env: str) -> dict[str, str]:
    md = manifest["metadata"]
    ident = {"env": env, "service": md["service"]}
    for k in IDENTITY_KEYS:
        if md.get(k) not in (None, ""):
            ident[k] = str(md[k])
    return ident


def render_manifest(manifest: dict, source: str, source_bytes: bytes, env: str, package_version: str, *,
                    policy: TagPolicy, references: dict[str, str] | None = None,
                    diag: Diagnostics | None = None) -> RenderResult:
    diag = diag or Diagnostics()
    md, spec = manifest["metadata"], manifest["spec"]
    service = md["service"]
    tel = spec.get("telemetry") or {}

    deprecated = sorted([s for s in DEPRECATED_SPEC if s in spec] + (["telemetry.profile"] if "profile" in tel else []) +
                        (["metadata.runbook_url"] if "runbook_url" in md else []))
    if deprecated:
        diag.notice(f"{source}: content sections ignored by the core package (monitors/SLOs/dashboards are not created; "
                    f"see extras/content): {', '.join(deprecated)}")

    ident = identity_of(manifest, env)
    # version is a deploy-time value (DD_VERSION of the artifact): rendered tags exclude it
    rendered = policy.render({**ident, "version": "deploy-time"}, md.get("tags") or {})
    missing = [k for k in rendered["missing_required"] if k != "version"]
    if missing:
        msg = f"{source}: tag policy required key(s) without a value for env {env}: {', '.join(missing)}"
        if policy.enforce:
            raise OnboardingError(msg)
        diag.warn(msg)
    for bad in rendered["invalid_values"]:
        diag.error(f"{source}: tag value outside allowed_values: {bad}")
    version_keys = set(policy.dd_keys("version")) if "version" in policy.keys else {"version"}
    tags = {k: v for k, v in rendered["tags"].items() if k not in version_keys}
    azure_tags = {k: v for k, v in rendered["azure_tags"].items()
                  if k != (policy.keys.get("version", {}).get("azure_tag_keys") or ["version"])[0]}

    resources = []
    for r in spec.get("resources") or []:
        rid = r["id"]
        required = r.get("required", True)
        if references is not None and find_refs(rid):
            resolved, miss = resolve_string(rid, references)
            if resolved is None:
                if required:
                    raise OnboardingError(f"{source}: required resource '{r['role']}' unresolved: {miss}")
                diag.warn(f"{source}: optional resource '{r['role']}' dropped (unresolved {miss})")
                continue
            rid = resolved
        if not find_refs(rid) and not ARM_ID_RE.match(rid):
            raise OnboardingError(f"{source}: resource '{r['role']}' id is not an ARM resource id: {rid}")
        rtags = dict(tags)
        rtags.update({k: policy.norm(str(v)) for k, v in (r.get("tags") or {}).items()})
        resources.append({"id": rid, "type": r["type"], "role": r["role"], "required": required, "tier": r.get("tier"),
                          "tags": dict(sorted(rtags.items()))})
    roles = [r["role"] for r in spec.get("resources") or []]
    if len(roles) != len(set(roles)):
        raise OnboardingError(f"{source}: duplicate resource roles {roles}")

    arch = spec["architecture"]
    route = (tel.get("logs") or {}).get("route", "auto")
    if route == "auto":
        route = LOG_ROUTE_BY_ARCH.get(arch, "none")
    apm = tel.get("apm") or {}
    traces = tel.get("traces") or {}
    apm_mode = apm.get("mode", "none" if traces.get("enabled") is False else "policy")
    sample = apm.get("sample_rate", traces.get("sample_rate"))
    dbm = tel.get("dbm")
    rum = tel.get("rum")
    data = {
        "schema": RENDERED_SCHEMA,
        "package_version": package_version,
        "source": source,
        "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
        "env": env,
        "service": service,
        "display_name": md.get("display_name", service),
        "identity": dict(sorted(ident.items())),
        "tags": dict(sorted(tags.items())),
        "azure_tags": dict(sorted(azure_tags.items())),
        "architecture": arch,
        "runtime": spec.get("runtime", "browser" if arch == "swa" else "other"),
        "os_type": spec.get("os_type", "linux"),
        "telemetry": {
            "logs_route": route,
            "apm_mode": apm_mode,
            "apm_sample_rate": sample,
            "profiling": (tel.get("profiling") or {}).get("enabled"),
            "dbm": dbm if dbm and dbm.get("enabled", True) else None,
            "rum": rum if rum and rum.get("enabled", True) else None,
        },
        "resources": resources,
        "presence_ref": spec.get("presence_ref"),
        "deprecated_sections": deprecated,
    }
    return RenderResult(service, env, data)


# --------------------------------------------------------------------------- manifests
def load_manifests(paths: list[Path]) -> list[tuple[Path, dict, bytes]]:
    files: list[Path] = []
    for item in paths:
        p = Path(item)
        if p.is_dir():
            files.extend(sorted(x for x in p.glob("*.y*ml") if not x.name.startswith("_")))
        else:
            files.append(p)
    out = []
    for f in files:
        raw = f.read_bytes()
        doc = yaml.safe_load(raw)
        if not isinstance(doc, dict) or doc.get("kind") != "ServiceOnboarding":
            continue
        out.append((f, doc, raw))
    return out


def check_api_version(doc: dict, source: str) -> None:
    if doc.get("apiVersion") == "observability/v1":
        raise OnboardingError(f"{source}: apiVersion observability/v1 is the 2.x content manifest. Migrate to observability/v2 "
                              "(UPGRADING.md 3.0.0: tools/onboarding/migrate_v1.py) or render it with extras/content/tools/onboarding.")


def package_version() -> str:
    v = PACKAGE_ROOT / "VERSION"
    return v.read_text(encoding="utf-8").strip() if v.exists() else "0.0.0"
