"""Observability onboarding manifest changes, judged as YAML DATA.

observability-thresholds   only numeric values at policy `threshold_paths` changed, each inside its guardrail range
onboarding-manifest        a NEW manifest for a non-production env that validates against the onboarding schema
observability-config       anything else (human review)
"""

from __future__ import annotations

import json
import re
from collections.abc import Callable
from typing import Any

import yaml

from .model import Finding

ENV_RE = re.compile(r"^observability/onboarding/([^/]+)/[^/]+\.ya?ml$")


def _flatten(node: Any, prefix: str = "") -> dict[str, Any]:
    out: dict[str, Any] = {}
    if isinstance(node, dict):
        for k, v in node.items():
            out.update(_flatten(v, f"{prefix}.{k}" if prefix else str(k)))
        if not node:
            out[prefix] = {}
    elif isinstance(node, list):
        for i, v in enumerate(node):
            out.update(_flatten(v, f"{prefix}[{i}]"))
        if not node:
            out[prefix] = []
    else:
        out[prefix] = node
    return out


def _pattern(path: str) -> re.Pattern:
    rx = re.escape(path).replace(r"\[\*\]", r"\[\d+\]").replace(r"\*", r"[^.\[]+")
    return re.compile("^" + rx + "$")


def _load(text: str | None) -> tuple[Any | None, str | None]:
    if text is None:
        return None, None
    try:
        return yaml.safe_load(text), None
    except yaml.YAMLError as exc:
        return None, exc.__class__.__name__


def refine(path: str, base: str | None, head: str | None, cfg: dict, schema_loader: Callable[[str], str | None]) -> tuple[str, list[Finding]]:
    m = ENV_RE.match(path)
    env = m.group(1) if m else ""
    findings: list[Finding] = []
    if env in cfg.get("prod_envs", ["prod"]):
        return "prod-config", findings
    new, err = _load(head)
    if err:
        findings.append(
            Finding(
                rule="observability.invalid-yaml",
                severity="high",
                kind="violation",
                category="observability",
                message=f"Manifest is not valid YAML ({err}).",
                file=path,
                evidence="invalid-yaml",
            )
        )
        return "observability-config", findings
    if head is None:
        return "observability-config", findings  # deleting a manifest removes monitoring: human
    if base is None:
        schema_text = schema_loader(cfg.get("manifest_schema") or "")
        if not schema_text:
            return "observability-config", findings
        import jsonschema

        errors = list(jsonschema.Draft202012Validator(json.loads(schema_text)).iter_errors(new))
        if errors:
            findings.append(
                Finding(
                    rule="observability.schema",
                    severity="high",
                    kind="violation",
                    category="observability",
                    message=f"New manifest does not validate against {cfg.get('manifest_schema')}: {errors[0].message[:200]}",
                    file=path,
                    evidence=f"schema:{errors[0].message[:80]}",
                    suggestion="Run the onboarding renderer locally (observability/README.md) and fix the manifest.",
                )
            )
            return "observability-config", findings
        meta_env = ((new or {}).get("metadata") or {}).get("env")
        if meta_env and meta_env != env:
            findings.append(
                Finding(
                    rule="observability.env-mismatch",
                    severity="medium",
                    kind="violation",
                    category="observability",
                    message=f"metadata.env '{meta_env}' does not match the directory env '{env}'.",
                    file=path,
                    evidence=f"env:{meta_env}:{env}",
                )
            )
            return "observability-config", findings
        return "onboarding-manifest", findings
    old, _ = _load(base)
    fa, fb = _flatten(old), _flatten(new)
    changed = sorted(k for k in set(fa) | set(fb) if fa.get(k) != fb.get(k))
    if not changed:
        return "observability-thresholds", findings  # whitespace/comments only
    guards = [(_pattern(g["path"]), g) for g in cfg.get("threshold_paths", [])]
    for key in changed:
        guard = next((g for rx, g in guards if rx.match(key)), None)
        val = fb.get(key)
        if guard is None or key not in fa or key not in fb or isinstance(val, bool) or not isinstance(val, (int, float)):
            return "observability-config", findings
        if not (guard["min"] <= val <= guard["max"]):
            findings.append(
                Finding(
                    rule="observability.guardrail",
                    severity="medium",
                    kind="violation",
                    category="observability",
                    message=f"`{key}` = {val} is outside the guardrail range [{guard['min']}, {guard['max']}].",
                    file=path,
                    evidence=f"guardrail:{key}",
                    suggestion="Keep thresholds inside the policy guardrails or ask an observability owner to review.",
                )
            )
            return "observability-config", findings
    return "observability-thresholds", findings
