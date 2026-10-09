"""Static guard: foundation-identity must never manage secret values (ADR-0001 §5).

Run: python3 -m pytest foundation/identity/tests -q
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
FORBIDDEN = re.compile(r'resource\s+"(azurerm_key_vault_secret|azurerm_key_vault_key|azurerm_key_vault_certificate|random_password)"')


def test_no_secret_value_resources():
    offenders = [str(p) for p in ROOT.glob("*.tf") if FORBIDDEN.search(p.read_text())]
    assert offenders == [], f"secret values must be set out-of-band, found in: {offenders}"


def test_contract_exposes_versionless_ids_only():
    outputs = (ROOT / "outputs.tf").read_text()
    assert "secrets/${s}" in outputs
    assert "version" not in re.sub(r"#.*", "", outputs.split("secret_ids", 1)[1]).split("}")[0]
