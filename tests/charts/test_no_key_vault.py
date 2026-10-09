"""Static guard for the Delinea DSV migration (ADR-0001 §14): no Azure Key Vault in the application deployment roots,
the hello-service chart or the observability package/lab, and no data source that reads a secret value.

Scans *.tf, *.tftpl, chart templates and values (tests, docs and vendored copies excluded). Runs without terraform.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
ROOTS = ["applications/deployments", "applications/charts/hello-service", "observability/modules", "observability/lab",
         "observability/examples/existing-environment", "observability/config"]
SKIP_PARTS = {".terraform", ".vendor", "tests", "__pycache__"}
SUFFIXES = {".tf", ".tftpl", ".yaml", ".yml", ".tpl", ".json"}

FORBIDDEN = {
    "azurerm_key_vault resource/data source": re.compile(r'(resource|data|ephemeral)\s+"azurerm_key_vault'),
    "Container Apps Key Vault secret reference": re.compile(r"key_vault_secret_id|keyVaultUrl"),
    "App Service Key Vault reference": re.compile(r"@Microsoft\.KeyVault\("),
    "Key Vault reference identity": re.compile(r"key_vault_reference_identity_id"),
    "Secrets Store CSI driver": re.compile(r"secrets-store\.csi|SecretProviderClass"),
    "Key Vault secret backend": re.compile(r"secret_backend_type\W+azure\.keyvault"),
    "Key Vault data plane URL": re.compile(r"vault\.azure\.net"),
}
# data sources whose attributes would put secret values into state
SECRET_DATA_SOURCES = re.compile(r'data\s+"(azurerm_key_vault_secret|azurerm_key_vault_certificate_data|azapi_resource_action)"')


def files():
    for root in ROOTS:
        for p in (REPO / root).rglob("*"):
            if p.is_file() and p.suffix in SUFFIXES and not (SKIP_PARTS & set(p.relative_to(REPO).parts)):
                # rendered monitoring content describes Azure Key Vault *resources* (platform logs), not secrets
                if "rendered" in p.parts or p.name in {"supported-categories.snapshot.json", "category-policy.json"}:
                    continue
                yield p


@pytest.mark.parametrize("label", sorted(FORBIDDEN))
def test_no_key_vault(label):
    rx = FORBIDDEN[label]
    hits = [f"{p.relative_to(REPO)}:{n}" for p in files() for n, line in enumerate(p.read_text(errors="ignore").splitlines(), 1)
            if rx.search(line) and not line.lstrip().startswith(("#", "//")) and "regex(" not in line and "not\"" not in line
            and '"pattern"' not in line]
    assert not hits, f"{label}: " + ", ".join(hits[:20])


def test_no_secret_reading_data_sources():
    hits = [str(p.relative_to(REPO)) for p in files() if p.suffix == ".tf" and SECRET_DATA_SOURCES.search(p.read_text())]
    assert not hits, hits


def test_sidecar_platforms_have_dsv_fetch():
    """Every place that runs a third-party collector without our code wires the dsv-fetch helper."""
    expect = {
        "observability/modules/instrumentation/main.tf": ["init_containers", "refresher_containers", "fetcher"],
        "observability/modules/telemetry-transport/apps.tf": ["initContainers = local.agg_init", "initContainers = local.gw_init"],
        "observability/modules/kubernetes/main.tf": ["initContainers", "secretBackend"],
        "observability/modules/dbm/main.tf": ["secret_backend_command"],
        "observability/modules/host-agents/scripts/linux-install.sh.tftpl": ["ExecStartPre=$DSV_DIR/dsv-fetch", "secret_backend_command"],
        "applications/deployments/modules/container-app/main.tf": ['dynamic "init_container"', "local.refreshers"],
        "applications/deployments/partner-sim/main.tf": ["local.fetcher"],
        "applications/deployments/functions/main.tf": ["initContainers = local.aca_init"],
    }
    for path, needles in expect.items():
        text = (REPO / path).read_text()
        for n in needles:
            assert n in text, f"{path}: missing {n!r}"
