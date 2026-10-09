"""The resource-log category policy (modules/diagnostic-settings/category-policy.json) names only categories that
Microsoft Learn lists for the resource type (snapshot taken from the 'Supported resource log categories' pages),
never routes an application category to the platform hub, and keeps the tiers cumulative and non-overlapping.
No network: the snapshot is committed next to the policy (refresh it when Microsoft adds categories)."""
from __future__ import annotations

import json
from pathlib import Path

PKG = Path(__file__).resolve().parents[2]
MOD = PKG / "modules" / "diagnostic-settings"
POLICY = json.loads((MOD / "category-policy.json").read_text())["types"]
SNAP = json.loads((MOD / "supported-categories.snapshot.json").read_text())["pages"]
APP = {"AppServiceConsoleLogs", "AppServiceAppLogs", "FunctionAppLogs", "WorkflowRuntime", "ContainerAppConsoleLogs",
       "AppEnvSpringAppConsoleLogs", "AppEnvSessionConsoleLogs"}
TIERS = ("security", "standard", "verbose")


def _page(rtype: str) -> str:
    return "microsoft-" + rtype.split("microsoft.", 1)[1].replace(".", "-").replace("/", "-")


def test_every_category_is_documented_by_microsoft():
    bad = []
    for rtype, p in POLICY.items():
        supported = set(SNAP[_page(rtype)])
        assert p["learn_page"].endswith(f"/{_page(rtype)}-logs"), rtype
        for tier in TIERS:
            bad += [(rtype, c) for c in p[tier] if c not in supported]
        for c, drops in p["supersedes"].items():
            bad += [(rtype, x) for x in [c, *drops] if x not in supported]
    assert not bad, bad


def test_no_application_category_in_platform_tiers():
    leaked = [(t, c) for t, p in POLICY.items() for tier in TIERS for c in p[tier] if c in APP]
    assert not leaked, leaked


def test_tiers_do_not_repeat_and_have_cost_notes():
    for rtype, p in POLICY.items():
        seen: set[str] = set()
        for tier in TIERS:
            assert not (seen & set(p[tier])), (rtype, tier)
            seen |= set(p[tier])
        assert p["cost"], rtype


def test_aks_defaults_avoid_full_kube_audit():
    aks = POLICY["microsoft.containerservice/managedclusters"]
    assert aks["security"] == ["kube-audit-admin", "guard"]
    assert "kube-apiserver" in aks["standard"] and "kube-audit" in aks["verbose"]
    assert aks["supersedes"] == {"kube-audit": ["kube-audit-admin"]}


def test_security_essentials_present():
    assert POLICY["microsoft.keyvault/vaults"]["security"] == ["AuditEvent"]
    assert "SQLSecurityAuditEvents" in POLICY["microsoft.sql/servers/databases"]["security"]
    assert "StorageRead" in POLICY["microsoft.storage/storageaccounts/blobservices"]["verbose"]
    assert "ControlPlaneRequests" in POLICY["microsoft.documentdb/databaseaccounts"]["security"]
    assert "DataPlaneRequests" in POLICY["microsoft.documentdb/databaseaccounts"]["verbose"]
