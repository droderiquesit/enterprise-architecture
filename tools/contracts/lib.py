"""Contract envelopes: schema validation, storage keys and major-version compatibility (ADR §5)."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Optional

from tools.changeset.fingerprint import contract_majors
from tools.changeset.trees import Tree

ENVELOPE_SCHEMA = "catalog/schemas/contract-envelope.schema.json"


class ContractError(Exception):
    pass


def var_name(contract: str) -> str:
    return contract.replace("-", "_")


def expected_major(tree: Tree, contract: str) -> int:
    """Highest schema major in catalog/contracts (the version this commit's consumers are written for).
    Contracts without a schema default to v1."""
    return contract_majors(tree).get(contract, 1)


def envelope_key(env: str, contract: str, major: int) -> str:
    return f"{env}/{contract}/v{major}.json"


def schema_path(contract: str, major: int) -> str:
    return f"catalog/contracts/{contract}.v{major}.schema.json"


def _validator(schema: dict):
    import jsonschema

    jsonschema.Draft202012Validator.check_schema(schema)
    return jsonschema.Draft202012Validator(schema, format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER)


def validate_against(schema: dict, doc, what: str) -> List[str]:
    errors = sorted(_validator(schema).iter_errors(doc), key=lambda e: list(e.absolute_path))
    return [f"{what}: {'/'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}" for e in errors]


def load_schema(tree: Tree, path: str) -> Optional[dict]:
    text = tree.read_text(path)
    return json.loads(text) if text else None


def validate_data(tree: Tree, contract: str, major: int, data) -> List[str]:
    schema = load_schema(tree, schema_path(contract, major))
    if schema is None:
        return []
    return validate_against(schema, data, f"{contract} v{major}")


def validate_envelope(tree: Tree, envelope: dict, contract: str, env: str, major: int) -> List[str]:
    errors: List[str] = []
    schema = load_schema(tree, ENVELOPE_SCHEMA)
    if schema is not None:
        errors += validate_against(schema, envelope, "envelope")
    if errors:
        return errors
    if envelope.get("contract") != contract:
        errors.append(f"envelope names contract '{envelope.get('contract')}', expected '{contract}'")
    if envelope.get("environment") != env:
        errors.append(f"envelope environment '{envelope.get('environment')}' != '{env}'")
    try:
        got_major = int(str(envelope.get("version", "0")).split(".")[0])
    except ValueError:
        got_major = -1
    if got_major != major:
        errors.append(f"incompatible major version: {contract} envelope is v{got_major}, consumers at this commit "
                      f"expect v{major} (publish v{major} alongside the old major before switching consumers)")
    errors += validate_data(tree, contract, major, envelope.get("data"))
    return errors


SECRET_KEY_HINTS = ("password", "secret", "connection_string", "connection-string", "access_key", "primary_key",
                    "api_key", "api-key", "app_key", "app-key", "sas_token", "client_secret", "shared-key", "fault-token")
REFERENCE_SUFFIXES = ("_secret_id", "_secret_name", "_secret_uri", "_secret_ref", "_ref")
DSV_REF_PREFIX = "dsv://"


def is_reference(value) -> bool:
    """A Delinea DSV reference (dsv://<path>#<element>) names a secret; it is not one (ADR-0001 section 14)."""
    return isinstance(value, str) and value.startswith(DSV_REF_PREFIX)


def secret_like_keys(data, path: str = "") -> List[str]:
    """Contracts must not carry secrets (ADR §5/§14): flag secret-looking keys whose value is a literal string.
    DSV references (dsv://...) and *_secret_id / *_ref style reference keys are allowed."""
    bad = []
    if isinstance(data, dict):
        for k, v in data.items():
            p = f"{path}.{k}" if path else k
            lk = k.lower()
            if any(s in lk for s in SECRET_KEY_HINTS) and not lk.endswith(REFERENCE_SUFFIXES):
                if isinstance(v, str) and v and not is_reference(v):
                    bad.append(p)
            bad += secret_like_keys(v, p)
    elif isinstance(data, list):
        for i, v in enumerate(data):
            bad += secret_like_keys(v, f"{path}[{i}]")
    return bad


def write_json(path: Path, obj) -> str:
    text = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    path.write_text(text + "\n", encoding="utf-8")
    import hashlib

    return hashlib.sha256(text.encode()).hexdigest()


def produced_contracts(component) -> Dict[str, str]:
    """{contract: terraform output name}. A single produced contract uses `output "contract"`;
    several use `output "contract_<name with _>"`."""
    if len(component.produces) == 1:
        return {component.produces[0]: "contract"}
    return {p: "contract_" + var_name(p) for p in component.produces}
