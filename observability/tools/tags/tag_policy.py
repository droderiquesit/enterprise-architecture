"""Tag policy library: load / validate schemas/tag-policy.v1 and render a tag set with the SAME semantics as
modules/tagging (Terraform). Used by tools/tags/check_coverage.py, tools/tags/derive_from_monitors.py,
tools/onboarding (per-service tag sets) and tools/verify/telemetry_verify.py.

Parity with Terraform is a test (tests/tags/test_parity.py renders identical inputs through both).
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import yaml

PACKAGE_ROOT = Path(__file__).resolve().parents[2]  # observability/
DEFAULT_POLICY = PACKAGE_ROOT / "config" / "tag-policy.yaml"
SCHEMA = PACKAGE_ROOT / "schemas" / "tag-policy.v1.schema.json"
UNIFIED = ("env", "service", "version")
LABEL_VALUE_RE = re.compile(r"^(([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9])?$")
LABEL_KEY_RE = re.compile(r"^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$")
_UNDERSCORES = re.compile(r"_+")


class PolicyError(ValueError):
    """The policy file is invalid."""


def schema_errors(policy: Any) -> list[str]:
    import jsonschema

    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    validator = jsonschema.Draft202012Validator(schema)
    return [f"{'/'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}" for e in validator.iter_errors(policy)]


def load_policy(path: str | Path | None = None, validate: bool = True) -> dict:
    p = Path(path) if path else DEFAULT_POLICY
    doc = yaml.safe_load(p.read_text(encoding="utf-8"))
    if validate:
        errs = schema_errors(doc)
        if errs:
            raise PolicyError(f"{p}: invalid tag policy:\n  " + "\n  ".join(errs))
    return doc


def normalize_value(value: str) -> str:
    """Datadog tag normalisation (lowercase; letters, digits, _ : . / - kept; other characters -> '_'; runs of '_'
    collapsed; leading/trailing '_' removed). Mirrors modules/tagging."""
    out = "".join(ch if (ch.isalpha() or ch.isnumeric() or ch in "_:./-") else "_" for ch in str(value).lower())
    return _UNDERSCORES.sub("_", out).strip("_")


def _str(v: Any) -> str:
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


class TagPolicy:
    def __init__(self, doc: dict):
        self.doc = doc
        self.keys: dict[str, dict] = {k: (v or {}) for k, v in (doc.get("keys") or {}).items()}
        self.normalize = doc.get("normalize", "datadog") == "datadog"
        self.enforce = bool(doc.get("enforce_required", True))

    @classmethod
    def load(cls, path: str | Path | None = None) -> TagPolicy:
        return cls(load_policy(path))

    # ------------------------------------------------------------------ key metadata
    def primary(self, k: str) -> str:
        return self.keys[k].get("key") or k

    def dd_keys(self, k: str) -> list[str]:
        out = [self.primary(k)]
        for a in self.keys[k].get("aliases") or []:
            if a not in out:
                out.append(a)
        return out

    def required_keys(self) -> list[str]:
        return sorted({dk for k, s in self.keys.items() if s.get("required") for dk in self.dd_keys(k)})

    def canonical_for(self, dd_key: str) -> str | None:
        """Canonical policy key whose primary key or alias is dd_key (None for static / unknown keys)."""
        for k in self.keys:
            if dd_key in self.dd_keys(k):
                return k
        return None

    def static_tags(self, env: str) -> dict[str, str]:
        out = dict(self.doc.get("static_tags") or {})
        out.update(((self.doc.get("environments") or {}).get(env) or {}).get("static_tags") or {})
        return {k: _str(v) for k, v in out.items()}

    def norm(self, v: str) -> str:
        return normalize_value(v) if self.normalize else v

    def map_value(self, k: str, raw: str) -> str:
        vm = self.keys[k].get("value_map") or {}
        return _str(vm.get(raw.lower(), raw)) if isinstance(vm, dict) else raw

    # ------------------------------------------------------------------ rendering (== modules/tagging)
    def render(self, identity: dict[str, Any], extra_tags: dict[str, str] | None = None) -> dict:
        raw: dict[str, str] = {}
        for k, s in self.keys.items():
            v = _str(identity.get(k)).strip()
            raw[k] = v if v else _str(s.get("default"))
        mapped = {k: self.map_value(k, v) for k, v in raw.items()}
        value = {k: self.norm(v) for k, v in mapped.items()}
        static_raw = self.static_tags(value.get("env", ""))
        static_raw.update({k: _str(v) for k, v in (extra_tags or {}).items()})
        static = {k: self.norm(v) for k, v in static_raw.items() if v != ""}
        canonical: dict[str, str] = {}
        for k in self.keys:
            if value[k] != "":
                for dk in self.dd_keys(k):
                    canonical[dk] = value[k]
        merged = {**static, **canonical}
        tags = {dk: v[: max(1, 199 - len(dk))] for dk, v in merged.items()}
        extra = {dk: v for dk, v in tags.items() if dk not in UNIFIED}
        otel: dict[str, str] = dict(static)
        for k, s in self.keys.items():
            if value[k] == "":
                continue
            attrs = list(s.get("otel_attributes") or [self.primary(k)]) + list(s.get("aliases") or [])
            for a in dict.fromkeys(attrs):
                otel[a] = value[k]
        no_label = {dk for k, s in self.keys.items() if s.get("k8s_label") is False for dk in self.dd_keys(k)}
        labels = {f"tags.datadoghq.com/{k}": tags[k] for k in UNIFIED
                  if k in tags and len(tags[k]) <= 63 and LABEL_VALUE_RE.match(tags[k])}
        labels.update({dk: v for dk, v in extra.items()
                       if dk not in no_label and LABEL_KEY_RE.match(dk) and len(v) <= 63 and LABEL_VALUE_RE.match(v)})
        azure = dict(static_raw)
        for k, s in self.keys.items():
            if value[k] != "":
                az = (s.get("azure_tag_keys") or [self.primary(k)])[0]
                azure[az] = mapped[k]
        missing = sorted(self.primary(k) for k, s in self.keys.items() if s.get("required") and value[k] == "")
        invalid = sorted(f"{self.primary(k)}:{value[k]}" for k, s in self.keys.items()
                         if value[k] and s.get("allowed_values") and value[k] not in s["allowed_values"])
        dd_list = [f"{k}:{tags[k]}" for k in sorted(tags)]
        return {
            "tags": tags,
            "unified": {k: tags.get(k, "") for k in UNIFIED},
            "extra_tags": extra,
            "dd_tags": ",".join(dd_list),
            "dd_tags_list": dd_list,
            "dd_tags_extra": ",".join(f"{k}:{extra[k]}" for k in sorted(extra)),
            "otel_resource_attributes": otel,
            "otel_resource_attributes_string": ",".join(
                f"{a}={otel[a].replace(',', '%2C').replace('=', '%3D')}" for a in sorted(otel)),
            "k8s_labels": labels,
            "k8s_annotations": {"ad.datadoghq.com/tags": json.dumps(extra, sort_keys=True, separators=(",", ":"))} if extra else {},
            "azure_tags": azure,
            "missing_required": missing,
            "invalid_values": invalid,
        }

    def azure_tag_key_map(self) -> dict[str, list[str]]:
        out: dict[str, list[str]] = {}
        for k, s in self.keys.items():
            for az in dict.fromkeys(a.lower() for a in (s.get("azure_tag_keys") or [self.primary(k)])):
                out[az] = self.dd_keys(k)
        return out


def parse_tag(tag: str) -> tuple[str, str | None]:
    """'key:value' -> (key, value); 'value-only' -> (tag, None). Keys lowercased like Datadog does."""
    if ":" in tag:
        k, v = tag.split(":", 1)
        return k.strip().lower(), v.strip()
    return tag.strip().lower(), None
