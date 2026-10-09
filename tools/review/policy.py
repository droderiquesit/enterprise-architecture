"""Load and validate the review policy (.review/policy.yaml, schema tools/review/policy.schema.json).

The policy is DATA from the trusted target branch. Unknown keys are rejected (schema additionalProperties=false) so a
typo can never silently disable a rule. Defaults are applied after validation.
"""

from __future__ import annotations

import copy
import fnmatch
import hashlib
import json
from pathlib import Path
from typing import Any, Dict, Optional

import yaml

from tools.changeset import globs

POLICY_PATH = ".review/policy.yaml"
SCHEMA_PATH = Path(__file__).with_name("policy.schema.json")

DEFAULTS: Dict[str, Any] = {
    "owner_protected": [".review/**"],
    "decision": {
        "require_build_green": True,
        "blocking_severities": ["critical", "high", "medium"],
        "wait_for_author_severities": ["critical", "high"],
        "never_approve_target_branches": ["release/*"],
        "human_required_vote": 0,
        "max_files_for_auto_approve": 40,
    },
    "limits": {"max_changed_lines": 2000, "max_files": 150, "max_file_bytes": 512000, "max_inline_threads": 30},
    "secrets": {"entropy_min_length": 32, "entropy_threshold_base64": 4.3, "entropy_threshold_hex": 3.2,
                "fixture_paths": [], "skip_paths": []},
    "terraform": {"sensitive_resource_types": ["azurerm_role_assignment"], "security_attributes": []},
    "observability": {"manifest_schema": "", "prod_envs": ["prod"], "threshold_paths": []},
    "dependencies": {"allow_new_packages": False},
    "ai": {"enabled": False, "model": "claude-opus-5-5", "api_key_env": "ANTHROPIC_API_KEY", "effort": "medium",
           "max_input_chars": 120000, "max_file_chars": 20000, "max_output_tokens": 8000, "max_findings": 25,
           "timeout_seconds": 120, "max_retries": 2, "server_fallbacks": True, "exclude_globs": [],
           "blocking_severities": ["critical", "high"]},
}


class PolicyError(Exception):
    pass


def _merge(base: dict, over: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


class Policy:
    def __init__(self, doc: dict, source: str = POLICY_PATH, raw_text: str = ""):
        self.doc = doc
        self.source = source
        self.hash = hashlib.sha256((raw_text or json.dumps(doc, sort_keys=True)).encode()).hexdigest()[:16]

    def __getitem__(self, key: str) -> Any:
        return self.doc[key]

    @property
    def classes(self) -> list:
        return self.doc["classes"]

    def class_def(self, name: str) -> Optional[dict]:
        for c in self.classes:
            if c["name"] == name:
                return c
        return None

    def never_approve(self, name: str) -> bool:
        c = self.class_def(name)
        return bool(c and c.get("never_approve"))

    def is_owner(self, *identities: str) -> bool:
        owners = {o.lower() for o in self.doc["owners"]}
        return any(i and i.lower() in owners for i in identities)

    def owner_protected(self, path: str) -> bool:
        return globs.match_any(self.doc.get("owner_protected", []), path)

    def is_bot(self, *identities: str) -> bool:
        names = {n.lower() for n in self.doc["bot"]["names"]}
        return any(i and i.lower() in names for i in identities)

    def target_never_approved(self, target_branch: str) -> bool:
        branch = target_branch.removeprefix("refs/heads/")
        return any(fnmatch.fnmatchcase(branch, g) for g in self.doc["decision"]["never_approve_target_branches"])


def validate(doc: Any) -> None:
    import jsonschema

    schema = json.loads(SCHEMA_PATH.read_text())
    errors = sorted(jsonschema.Draft202012Validator(schema).iter_errors(doc), key=lambda e: list(e.absolute_path))
    if errors:
        msgs = [f"{'/'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}" for e in errors[:15]]
        raise PolicyError("review policy does not match tools/review/policy.schema.json:\n  " + "\n  ".join(msgs))
    names = [c["name"] for c in doc["classes"]]
    if len(names) != len(set(names)):
        raise PolicyError("duplicate class names in review policy")
    refined = {"dependency-patch", "dependency-change", "observability-thresholds", "onboarding-manifest", "observability-config"}
    unknown = [c for c in doc["decision"]["auto_approve_classes"] if c not in names and c not in refined]
    if unknown:
        raise PolicyError(f"decision.auto_approve_classes names unknown classes: {unknown}")
    never = [c for c in doc["decision"]["auto_approve_classes"] if any(d["name"] == c and d.get("never_approve") for d in doc["classes"])]
    if never:
        raise PolicyError(f"classes {never} are never_approve but listed in auto_approve_classes")


def parse(text: str, source: str = POLICY_PATH) -> Policy:
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise PolicyError(f"{source}: invalid YAML ({exc.__class__.__name__})") from None
    validate(doc)
    return Policy(_merge(DEFAULTS, doc), source, text)


def load_file(path: Path) -> Policy:
    return parse(Path(path).read_text(), str(path))
