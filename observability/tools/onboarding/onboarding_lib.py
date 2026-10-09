"""Shared logic for the onboarding tools (render.py, validate.py).

Merge precedence (lowest -> highest):
    1. archetypes/global-defaults.yaml
    2. archetypes/platform/<x>.yaml whose match.architectures contains spec.architecture
    3. archetypes/platform/<x>.yaml whose match.resource_types intersects the manifest resource types
       (alphabetical by archetype name)
    4. archetypes/profiles/<spec.telemetry.profile>.yaml, preceded by its `extends` chain
    5. the service manifest (metadata, spec, spec.monitors.params, spec.monitors.overrides)
    6. post-expansion: spec.monitors.overrides["<key>@<role>"], then spec.monitors.disabled

Maps deep-merge. Lists are replaced, unless the key ends with "+", in which case the list is appended
to the list under the key without "+".

Template placeholders are [[name]]. render.py expands everything except [[resource.*]], which
Terraform expands after resolving ${contract:...} references (resource ids are only known then).
"""
from __future__ import annotations

import copy
import fnmatch
import hashlib
import json
import re
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
RENDERED_SCHEMA = "rendered-service/v1"
MANAGED_BY_TAG = "managed_by:observability-package"

PLACEHOLDER_RE = re.compile(r"\[\[([A-Za-z0-9_.]+)\]\]")
REF_RE = re.compile(r"\$\{contract:([A-Za-z0-9_-]+)((?:\.[A-Za-z0-9_-]+)+)\}")
ARM_ID_RE = re.compile(r"^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/[A-Za-z]+\.[A-Za-z]+/.+$")
TF_PLACEHOLDERS = ("resource.scope", "resource.name", "resource.role", "resource.id")


class OnboardingError(Exception):
    """A manifest/archetype problem that must fail the run."""


@dataclass
class Diagnostics:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def error(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


# --------------------------------------------------------------------------- io helpers
def load_yaml(path: Path) -> Any:
    with path.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def load_schema(name: str) -> dict:
    return json.loads((SCHEMA_DIR / name).read_text(encoding="utf-8"))


def schema_errors(document: Any, schema_name: str) -> list[str]:
    if jsonschema is None:
        raise OnboardingError("python package 'jsonschema' is required for schema validation")
    validator = jsonschema.Draft202012Validator(load_schema(schema_name))
    out = []
    for err in sorted(validator.iter_errors(document), key=lambda e: list(e.absolute_path)):
        loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
        out.append(f"{loc}: {err.message}")
    return out


def dump_json(data: Any) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


# --------------------------------------------------------------------------- merge
def deep_merge(base: Any, overlay: Any) -> Any:
    """Return base deep-merged with overlay (neither input is mutated)."""
    if not isinstance(base, dict) or not isinstance(overlay, dict):
        return copy.deepcopy(overlay)
    result = copy.deepcopy(base)
    for key, value in overlay.items():
        if isinstance(key, str) and key.endswith("+"):
            target = key[:-1]
            existing = result.get(target) or []
            if not isinstance(existing, list) or not isinstance(value, list):
                raise OnboardingError(f"'{key}' appends to a list but '{target}' is not a list")
            result[target] = existing + copy.deepcopy(value)
        elif isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


# --------------------------------------------------------------------------- archetypes
@dataclass
class ArchetypeSet:
    root: Path
    global_defaults: dict
    platform: dict[str, dict]
    profiles: dict[str, dict]

    @classmethod
    def load(cls, root: Path, diag: Diagnostics | None = None) -> "ArchetypeSet":
        root = Path(root)
        diag = diag or Diagnostics()
        gd_path = root / "global-defaults.yaml"
        if not gd_path.exists():
            raise OnboardingError(f"missing {gd_path}")
        docs: dict[Path, dict] = {gd_path: load_yaml(gd_path)}
        for sub in ("platform", "profiles"):
            for p in sorted((root / sub).glob("*.yaml")):
                docs[p] = load_yaml(p)
        for p, d in docs.items():
            for e in schema_errors(d, "archetype.v1.schema.json"):
                diag.error(f"{p.relative_to(root)}: {e}")
        if diag.errors:
            raise OnboardingError("archetype schema errors:\n  " + "\n  ".join(diag.errors))
        platform = {d["metadata"]["name"]: d for p, d in docs.items() if p.parent.name == "platform"}
        profiles = {d["metadata"]["name"]: d for p, d in docs.items() if p.parent.name == "profiles"}
        for p, d in docs.items():
            stem = p.stem
            if p != gd_path and d["metadata"]["name"] != stem:
                raise OnboardingError(f"{p}: metadata.name '{d['metadata']['name']}' must equal file name '{stem}'")
        return cls(root, docs[gd_path], platform, profiles)

    def profile_chain(self, name: str) -> list[dict]:
        chain: list[dict] = []
        seen: set[str] = set()
        current: str | None = name
        while current:
            if current in seen:
                raise OnboardingError(f"profile extends cycle at '{current}'")
            seen.add(current)
            if current not in self.profiles:
                raise OnboardingError(f"unknown application profile '{current}' (archetypes/profiles/{current}.yaml)")
            doc = self.profiles[current]
            chain.insert(0, doc)
            current = doc.get("extends")
        return chain

    def layers_for(self, manifest: dict) -> list[tuple[str, dict]]:
        spec = manifest["spec"]
        arch = spec["architecture"]
        rtypes = {r["type"].lower() for r in spec.get("resources", [])}
        layers: list[tuple[str, dict]] = [("global-defaults", self.global_defaults)]
        for name in sorted(self.platform):
            doc = self.platform[name]
            if arch in doc.get("match", {}).get("architectures", []):
                layers.append((f"platform/{name}", doc))
        for name in sorted(self.platform):
            doc = self.platform[name]
            want = {t.lower() for t in doc.get("match", {}).get("resource_types", [])}
            if want & rtypes:
                layers.append((f"platform/{name}", doc))
        for doc in self.profile_chain(spec["telemetry"]["profile"]):
            layers.append((f"profiles/{doc['metadata']['name']}", doc))
        return layers


def _layer_doc(arch_doc: dict) -> dict:
    defaults = arch_doc.get("defaults") or {}
    out: dict[str, Any] = {}
    if "metadata" in defaults:
        out["metadata"] = defaults["metadata"]
    if "spec" in defaults:
        out["spec"] = defaults["spec"]
    for key in ("params", "monitors", "synthetics", "slo_burn_rate", "runbook_base_url"):
        if key in arch_doc:
            out[key] = arch_doc[key]
    return out


def _manifest_layer(manifest: dict) -> tuple[dict, dict]:
    """Split manifest into the merge layer and the post-expansion (@role) overrides."""
    spec = copy.deepcopy(manifest["spec"])
    monitors = spec.pop("monitors", {}) or {}
    overrides = monitors.get("overrides", {}) or {}
    plain = {k: v for k, v in overrides.items() if "@" not in k}
    role_specific = {k: v for k, v in overrides.items() if "@" in k}
    layer = {"metadata": copy.deepcopy(manifest["metadata"]), "spec": spec}
    if monitors.get("params"):
        layer["params"] = monitors["params"]
    if plain:
        layer["monitors"] = plain
    return layer, {"role_overrides": role_specific, "disabled": monitors.get("disabled", []) or []}


# --------------------------------------------------------------------------- templating
def _lookup(ctx: dict, dotted: str) -> Any:
    cur: Any = ctx
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            raise KeyError(dotted)
    return cur


def expand(text: str, ctx: dict, where: str) -> str:
    """Expand [[...]] placeholders (except Terraform-time [[resource.*]]) up to 5 nesting levels."""
    if not isinstance(text, str):
        return text
    for _ in range(5):
        def repl(m: re.Match) -> str:
            name = m.group(1)
            if name in TF_PLACEHOLDERS:
                return m.group(0)
            try:
                value = _lookup(ctx, name)
            except KeyError:
                raise OnboardingError(f"{where}: unknown placeholder [[{name}]]") from None
            if isinstance(value, (dict, list)):
                raise OnboardingError(f"{where}: placeholder [[{name}]] is not a scalar")
            if isinstance(value, bool):
                return "true" if value else "false"
            if isinstance(value, float) and value.is_integer():
                return str(int(value))
            return str(value)

        new = PLACEHOLDER_RE.sub(repl, text)
        if new == text:
            break
        text = new
    leftovers = [n for n in PLACEHOLDER_RE.findall(text) if n not in TF_PLACEHOLDERS]
    if leftovers:
        raise OnboardingError(f"{where}: unresolved placeholders {leftovers}")
    return text


def to_number(value: Any, where: str) -> int | float:
    if isinstance(value, bool):
        raise OnboardingError(f"{where}: boolean is not a threshold")
    if isinstance(value, (int, float)):
        num = value
    else:
        try:
            num = float(str(value))
        except ValueError:
            raise OnboardingError(f"{where}: threshold '{value}' is not numeric") from None
    if isinstance(num, float) and num.is_integer():
        return int(num)
    return num


def eval_when(conditions: list[str], effective: dict) -> bool:
    for cond in conditions or []:
        negate = cond.startswith("!")
        expr = cond[1:] if negate else cond
        if "!=" in expr:
            path, val = expr.split("!=", 1)
            ok = str(_safe_get(effective, path)) != val
        elif "=" in expr:
            path, val = expr.split("=", 1)
            ok = str(_safe_get(effective, path)) == val
        else:
            ok = bool(_safe_get(effective, expr))
        if negate:
            ok = not ok
        if not ok:
            return False
    return True


def _safe_get(doc: dict, dotted: str) -> Any:
    try:
        return _lookup(doc, dotted)
    except KeyError:
        return None


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


def render_manifest(
    manifest: dict,
    source: str,
    source_bytes: bytes,
    archetypes: ArchetypeSet,
    env: str,
    package_version: str,
    references: dict[str, str] | None = None,
    diag: Diagnostics | None = None,
) -> RenderResult:
    diag = diag or Diagnostics()
    layers = archetypes.layers_for(manifest)
    effective: dict[str, Any] = {}
    for _, doc in layers:
        effective = deep_merge(effective, _layer_doc(doc))
    manifest_layer, post = _manifest_layer(manifest)
    effective = deep_merge(effective, manifest_layer)
    layer_names = [n for n, _ in layers] + ["manifest"]

    meta = effective["metadata"]
    spec = effective["spec"]
    service = meta["service"]
    params = effective.get("params", {})
    server_op = spec["telemetry"]["traces"].get("server_operation", "http.server.request")

    # ---- resources / endpoints (reference resolution happens before expansion so drops are known)
    resources = []
    for r in spec.get("resources", []):
        item = {"id": r["id"], "type": r["type"], "role": r["role"], "required": r.get("required", True),
                "entities": r.get("entities", []), "tags": r.get("tags", {})}
        if references is not None:
            resolved, missing = resolve_string(r["id"], references)
            if missing:
                if item["required"]:
                    raise OnboardingError(f"{source}: required resource '{r['role']}' has unresolved references {missing}")
                diag.warn(f"{source}: optional resource '{r['role']}' dropped (unresolved {missing})")
                continue
            item["id"] = resolved
        if not REF_RE.search(item["id"]) and not ARM_ID_RE.match(item["id"]):
            raise OnboardingError(f"{source}: resource '{r['role']}' id is not an Azure resource id: {item['id']}")
        resources.append(item)
    roles = [r["role"] for r in spec.get("resources", [])]
    if len(roles) != len(set(roles)):
        raise OnboardingError(f"{source}: duplicate resource roles {roles}")

    endpoints = []
    synth_defaults = effective.get("synthetics", {})
    for e in spec.get("endpoints", []):
        item = copy.deepcopy(e)
        item.setdefault("health_path", "/healthz")
        item.setdefault("required", True)
        item.setdefault("browser_journey", False)
        if item["browser_journey"]:
            item.setdefault("browser_steps", [{"name": "Page renders", "type": "assertPageContains",
                                              "value": params.get("browser_assert_text", service)}])
        else:
            item.setdefault("browser_steps", [])
        syn = deep_merge({"enabled": True, "locations": synth_defaults.get("locations", []),
                          "private_location": e["visibility"] == "private",
                          "tick_every": synth_defaults.get("tick_every", 300)}, e.get("synthetic", {}))
        item["synthetic"] = syn
        if references is not None:
            resolved, missing = resolve_string(e["url"], references)
            if missing:
                if item["required"]:
                    raise OnboardingError(f"{source}: required endpoint '{e['name']}' has unresolved references {missing}")
                diag.warn(f"{source}: optional endpoint '{e['name']}' dropped (unresolved {missing})")
                continue
            item["url"] = resolved
        endpoints.append(item)

    runbook = meta.get("runbook_url")
    if not runbook:
        base = effective.get("runbook_base_url")
        if not base:
            raise OnboardingError(f"{source}: metadata.runbook_url is not set and no archetype defines runbook_base_url")
        rb_ctx = {"service": service, "env": env, "team": meta["team"]}
        if meta.get("repository"):
            rb_ctx["repository"] = meta["repository"].rstrip("/")
        runbook = expand(base, rb_ctx, f"{source}: runbook_base_url (set metadata.repository or metadata.runbook_url)")
    if not re.match(r"^https?://", runbook):
        raise OnboardingError(f"{source}: runbook URL must be http(s): {runbook}")
    tier = meta.get("tier", "medium")
    base_tags = sorted({
        f"env:{env}", f"service:{service}", f"team:{meta['team']}", f"tier:{tier}",
        f"application:{meta.get('application', 'unspecified')}", f"domain:{meta.get('domain', 'unspecified')}",
        MANAGED_BY_TAG,
    } | {f"{k}:{v}" for k, v in (meta.get("tags") or {}).items()})
    ctx = {
        "service": service, "env": env, "team": meta["team"], "server_operation": server_op,
        "service_scope": f"service:{service},env:{env}", "params": params,
    }
    notifications = spec.get("notifications", {})

    # ---- monitors
    monitors: dict[str, dict] = {}
    expanded_specs: dict[str, tuple[dict, dict | None]] = {}
    for key in sorted(effective.get("monitors", {})):
        mspec = effective["monitors"][key]
        if mspec.get("enabled", True) is False:
            continue
        if not eval_when(mspec.get("when", []), effective):
            continue
        for field_name in ("name", "type", "query", "thresholds"):
            if field_name not in mspec:
                raise OnboardingError(f"{source}: monitor '{key}' (after merge) lacks '{field_name}'")
        if mspec.get("scope", "service") == "resource":
            applies = mspec.get("applies_to", {})
            types = {t.lower() for t in applies.get("resource_types", [])}
            pattern = applies.get("role_pattern", "*")
            for r in resources:
                if r["type"].lower() in types and fnmatch.fnmatch(r["role"], pattern):
                    expanded_specs[f"{key}@{r['role']}"] = (mspec, r)
        else:
            expanded_specs[key] = (mspec, None)

    for ekey, override in post["role_overrides"].items():
        if ekey in expanded_specs:
            mspec, r = expanded_specs[ekey]
            expanded_specs[ekey] = (deep_merge(mspec, override), r)
        else:
            diag.warn(f"{source}: override '{ekey}' matches no rendered monitor")
    for pattern in post["disabled"]:
        hits = [k for k in expanded_specs if fnmatch.fnmatch(k, pattern) or fnmatch.fnmatch(k.split("@")[0], pattern)]
        if not hits:
            diag.warn(f"{source}: disabled entry '{pattern}' matches no monitor")
        for k in hits:
            del expanded_specs[k]

    for ekey in sorted(expanded_specs):
        mspec, res = expanded_specs[ekey]
        if mspec.get("enabled", True) is False:
            continue
        where = f"{source}: monitor {ekey}"
        thresholds = {}
        for tkey, tval in (mspec.get("thresholds") or {}).items():
            thresholds[tkey] = to_number(expand(str(tval), ctx, where), f"{where} threshold {tkey}")
        if "critical" not in thresholds:
            raise OnboardingError(f"{where}: thresholds.critical is required")
        mctx = dict(ctx, critical=_fmt(thresholds["critical"]), warning=_fmt(thresholds.get("warning", "")))
        severity = mspec.get("severity", "warning")
        name = expand(mspec["name"], mctx, where)
        query = expand(mspec["query"], mctx, where)
        anchor = mspec.get("runbook_section", ekey.split("@")[0].replace(".", "-"))
        runbook_link = f"{runbook}#{anchor}" if "#" not in runbook else runbook
        summary = expand(mspec.get("summary", ""), mctx, where).strip()
        troubleshooting = expand(mspec.get("troubleshooting", ""), mctx, where).strip()
        body_lines = [
            f"{{{{#is_alert}}}}**{severity.upper()}**: {summary}{{{{/is_alert}}}}",
            f"{{{{#is_warning}}}}**WARNING**: {summary}{{{{/is_warning}}}}",
            "{{#is_no_data}}**NO DATA**: the monitored signal stopped arriving. Check the telemetry pipeline canary first "
            "(a broken pipeline looks like silence).{{/is_no_data}}",
            "{{#is_recovery}}Recovered.{{/is_recovery}}",
            "",
            f"Service: `{service}` | env: `{env}` | team: `{meta['team']}` | owner: {meta['owner']} | tier: {tier}",
        ]
        if res is not None:
            body_lines.append(f"Resource: [[resource.role]] `[[resource.id]]`")
        body_lines += ["", "Troubleshooting:", troubleshooting or "-", "", f"Runbook: {runbook_link}"]
        alert_routes = list(notifications.get(severity) or notifications.get("default") or [])
        warn_routes = list(notifications.get("warning") or notifications.get("default") or [])
        mon = {
            "key": ekey,
            "name": name,
            "type": mspec["type"],
            "query": query,
            "thresholds": thresholds,
            "severity": severity,
            "priority": int(mspec.get("priority", params.get("priority_default", 3))),
            "notify_no_data": bool(mspec.get("notify_no_data", False)),
            "no_data_timeframe": mspec.get("no_data_timeframe"),
            "require_full_window": bool(mspec.get("require_full_window", False)),
            "evaluation_delay": mspec.get("evaluation_delay", 900 if query.find("azure.") >= 0 else None),
            "new_group_delay": mspec.get("new_group_delay", 60),
            "renotify_interval": mspec.get("renotify_interval", 0),
            "message": "\n".join(body_lines),
            "runbook_url": runbook_link,
            "notify": {"alert": alert_routes, "warning": warn_routes},
            "resource_role": res["role"] if res else None,
            "tags": sorted(set(base_tags + [f"monitor:{ekey.split('@')[0]}", f"severity:{severity}"]
                               + list(mspec.get("tags", [])))),
        }
        if mon["notify_no_data"] and not mon["no_data_timeframe"]:
            mon["no_data_timeframe"] = 30
        monitors[ekey] = mon

    # ---- SLOs
    slos = []
    burn_table = effective.get("slo_burn_rate", {})
    traces_on = bool(spec["telemetry"]["traces"].get("enabled"))
    for slo in spec.get("slos", []) or []:
        where = f"{source}: slo {slo['name']}"
        if not traces_on:
            raise OnboardingError(f"{where}: trace-metric SLOs require spec.telemetry.traces.enabled=true")
        scope = ctx["service_scope"]
        item = {
            "name": slo["name"], "type": slo["type"], "target": slo["target"], "warning": slo.get("warning"),
            "timeframe": slo["timeframe"], "display_name": f"[{env}] {service} {slo['name']}",
            "description": f"{slo['type']} SLO for {service} ({env}). Runbook: {runbook}#slo-{slo['name']}",
            "tags": base_tags,
        }
        if slo.get("warning") is not None and slo["warning"] <= slo["target"]:
            raise OnboardingError(f"{where}: warning ({slo['warning']}) must be stricter (higher) than target")
        if slo["type"] == "availability":
            item["numerator"] = (f"sum:trace.{server_op}.hits{{{scope}}}.as_count() - "
                                 f"sum:trace.{server_op}.errors{{{scope}}}.as_count()")
            item["denominator"] = f"sum:trace.{server_op}.hits{{{scope}}}.as_count()"
        else:
            if not slo.get("threshold_ms"):
                raise OnboardingError(f"{where}: latency SLO needs threshold_ms")
            item["time_slice"] = {"query": f"p95:trace.{server_op}{{{scope}}}", "comparator": "<=",
                                  "threshold": round(slo["threshold_ms"] / 1000.0, 3)}
        burn = []
        if slo.get("burn_rate_alerts", True):
            max_rate = 1.0 / (1.0 - slo["target"] / 100.0)
            for pair in burn_table.get(slo["timeframe"], []):
                thr = float(pair["threshold"])
                limit = round(max_rate * 0.9, 1)
                if thr > limit:
                    diag.warn(f"{where}: burn rate {thr} > 90% of max {max_rate:.1f}; clamped to {limit}")
                    thr = limit
                if thr <= 1:
                    continue
                sev = pair["severity"]
                routes = list(notifications.get(sev) or notifications.get("default") or [])
                burn.append({
                    "severity": sev, "long_window": pair["long_window"], "short_window": pair["short_window"],
                    "threshold": thr,
                    "name": f"[{env}] {service} {slo['name']} SLO burn rate {sev} ({pair['long_window']}/{pair['short_window']})",
                    "message": (f"{{{{#is_alert}}}}**{sev.upper()}**: error budget of SLO `{slo['name']}` is burning "
                                f"{thr}x faster than sustainable over {pair['long_window']} (confirmed over "
                                f"{pair['short_window']}).{{{{/is_alert}}}}\n{{{{#is_recovery}}}}Burn rate back below "
                                f"threshold.{{{{/is_recovery}}}}\n\nService: `{service}` | env: `{env}` | team: "
                                f"`{meta['team']}`\n\nTroubleshooting:\n1. Open the SLO and the service error/latency "
                                f"monitors.\n2. Check recent deployments and dependency health.\n\nRunbook: "
                                f"{runbook}#slo-burn-rate"),
                    "notify": {"alert": routes},
                    "runbook_url": f"{runbook}#slo-burn-rate",
                })
        item["burn_rate_alerts"] = burn
        slos.append(item)

    # ---- quiet hours -> recurring downtime for this service's monitors
    quiet = (spec.get("idle_behavior") or {}).get("expected_quiet_hours")

    catalog = spec.get("catalog", {})
    data = {
        "schema": RENDERED_SCHEMA,
        "package_version": package_version,
        "generated_from": {"manifest": source, "sha256": hashlib.sha256(source_bytes).hexdigest(), "layers": layer_names},
        "env": env,
        "service": service,
        "enabled": bool(spec.get("enabled", True)),
        "presence_ref": spec.get("presence_ref"),
        "metadata": {
            "display_name": meta.get("display_name", service), "team": meta["team"], "owner": meta["owner"],
            "application": meta.get("application", "unspecified"), "domain": meta.get("domain", "unspecified"),
            "tier": tier, "repository": meta.get("repository"), "runbook_url": runbook,
            "description": meta.get("description", ""), "languages": meta.get("languages", []),
            "depends_on": meta.get("depends_on", []), "contacts": meta.get("contacts", []),
        },
        "architecture": spec["architecture"],
        "runtime": spec.get("runtime", "other"),
        "tags": base_tags,
        "resources": resources,
        "endpoints": endpoints,
        "telemetry": spec["telemetry"],
        "idle_behavior": {"scale_to_zero": bool((spec.get("idle_behavior") or {}).get("scale_to_zero", False)),
                          "expected_quiet_hours": quiet},
        "monitors": monitors,
        "slos": slos,
        "synthetics_defaults": {k: v for k, v in synth_defaults.items() if k not in ("locations", "tick_every")},
        "dashboards": {"enabled": bool((spec.get("dashboards") or {}).get("enabled", True)),
                       "workflow_metric_prefix": params.get("workflow_metric_prefix")},
        "catalog": {"enabled": bool(catalog.get("enabled", True)), "lifecycle": catalog.get("lifecycle", "production"),
                    "type": catalog.get("type", "web"), "component_of": catalog.get("component_of", [])},
        "notifications": notifications,
    }
    return RenderResult(service, env, data)


def _fmt(v: Any) -> str:
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


# --------------------------------------------------------------------------- manifests
def load_manifests(paths: list[Path]) -> list[tuple[Path, dict, bytes]]:
    files: list[Path] = []
    for p in paths:
        p = Path(p)
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


def package_version() -> str:
    v = PACKAGE_ROOT / "VERSION"
    return v.read_text(encoding="utf-8").strip() if v.exists() else "0.0.0"
