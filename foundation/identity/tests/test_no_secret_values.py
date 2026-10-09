"""Static guards: foundation-identity never manages secret values or Key Vault (ADR-0001 sections 5 and 14).

Run: python3 -m pytest foundation/identity/tests -q
"""
import pathlib
import re

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
FORBIDDEN = re.compile(r'(resource|data)\s+"(azurerm_key_vault\w*|random_password|dsv_\w+)"')


def test_no_secret_value_or_key_vault_resources():
    offenders = [str(p) for p in ROOT.glob("*.tf") if FORBIDDEN.search(p.read_text())]
    assert offenders == [], f"secret values live in DSV and are set out-of-band, found in: {offenders}"


def test_contract_exposes_references_only():
    outputs = (ROOT / "outputs.tf").read_text()
    assert "dsv://${local.base_path}/${s}#value" in outputs
    assert "key_vault" not in outputs and "secret_ids" not in outputs


def test_catalogue_is_metadata_only():
    doc = yaml.safe_load((ROOT / "secrets.yaml").read_text())
    allowed = {"source", "publisher", "description", "origin", "required_by", "dbm_engine", "optional"}
    for name, meta in doc["secrets"].items():
        assert re.fullmatch(r"[a-z0-9][a-z0-9-]{1,62}", name), name
        assert set(meta) <= allowed, f"{name}: unexpected keys {set(meta) - allowed} (never put values here)"
        assert meta["source"] in ("operator", "generated")
        if meta["source"] == "generated":
            assert meta.get("publisher"), f"{name}: generated secrets name their publisher component"
