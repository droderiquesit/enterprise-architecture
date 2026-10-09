"""Tests for the Azure service catalog (catalog/services, telemetry capabilities, provider gaps, coverage docs).

Run from the repository root:  python3 -m pytest tests/catalog -q
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

import pytest
import yaml

REPO = pathlib.Path(__file__).resolve().parents[2]
TOOLS = REPO / "tools" / "catalog"
sys.path.insert(0, str(TOOLS))

import catalog_lib  # noqa: E402
import render_coverage  # noqa: E402
import validate  # noqa: E402


def _entries() -> dict[str, dict]:
    return {e["id"]: e for _, e in catalog_lib.all_entries(catalog_lib.load_service_files())}


def test_validator_passes_cli():
    proc = subprocess.run([sys.executable, str(TOOLS / "validate.py")], cwd=REPO, capture_output=True, text=True)
    assert proc.returncode == 0, proc.stdout + proc.stderr


def test_rendered_docs_up_to_date(tmp_path):
    assert render_coverage.main(["--out", str(tmp_path)]) == 0
    for name in ("coverage-matrix.md", "telemetry-capability-matrix.md"):
        committed = catalog_lib.COVERAGE_DIR / name
        assert committed.exists(), f"{committed} missing - run python3 tools/catalog/render_coverage.py"
        assert (tmp_path / name).read_text() == committed.read_text(), (
            f"{name} is stale - run python3 tools/catalog/render_coverage.py")


def test_render_check_mode():
    assert render_coverage.main(["--check"]) == 0


def test_every_component_and_matrix_ref_exists():
    ids = set(_entries())
    for comp in catalog_lib.load_components():
        for ref in comp.get("catalog_refs") or []:
            assert ref in ids, f"{comp['id']} -> {ref}"
    matrix = catalog_lib.load_yaml(catalog_lib.MATRIX_PATH)
    for section in ("architectures", "databases"):
        for key in matrix[section]:
            assert key in ids, f"{section}.{key}"


def test_required_coverage_present():
    ids = set(_entries())
    required = {
        "sql-database-provisioned", "sql-database-serverless", "sql-elastic-pool", "sql-hyperscale", "sql-managed-instance",
        "sql-server-on-vm", "postgresql-flexible", "postgresql-elastic-cluster", "mysql-flexible", "cosmos-nosql",
        "cosmos-mongodb-ru", "cosmos-cassandra", "cosmos-gremlin", "cosmos-table", "documentdb", "managed-cassandra",
        "managed-redis", "azure-cache-for-redis", "table-storage", "confidential-ledger", "cosmos-postgresql", "mariadb",
        "horizondb", "data-explorer", "synapse-sql", "synapse-serverless-sql", "synapse-spark", "ai-search", "blob-storage",
        "adls-gen2", "databricks", "hdinsight", "stream-analytics", "oracle-database-azure", "fabric-sql-database",
        "fabric-cosmos-db", "fabric-eventhouse", "fabric-warehouse", "functions-consumption-linux", "spring-apps",
        "cloud-services-extended-support", "avs", "managed-devops-pools", "arc-servers", "service-bus", "event-hubs",
        "event-grid", "container-registry", "log-analytics", "key-vault", "app-configuration", "durable-task-scheduler",
        "static-web-apps", "logic-apps-consumption", "logic-apps-standard", "container-apps-job-event",
    }
    missing = required - ids
    assert not missing, sorted(missing)


def test_lifecycle_facts():
    e = _entries()
    redis = e["azure-cache-for-redis"]
    assert redis["lifecycle"]["status"] == "retiring"
    assert redis["lifecycle"]["retirement_date"] == "2028-09-30"
    assert redis["status"]["default_profiles"] == []
    assert e["functions-consumption-linux"]["lifecycle"]["retirement_date"] == "2028-09-30"
    assert e["mariadb"]["lifecycle"]["status"] == "retired"
    assert e["cosmos-postgresql"]["lifecycle"]["status"] == "not-recommended"
    assert e["horizondb"]["lifecycle"]["status"] == "preview"
    assert e["documentdb"]["iac"]["terraform_resources"][0] == "azurerm_mongo_cluster"
    assert e["managed-redis"]["iac"]["terraform_resources"][0] == "azurerm_managed_redis"


def test_dbm_matrix_matches_datadog_docs():
    e = _entries()
    for yes in ("sql-database-provisioned", "sql-managed-instance", "sql-server-on-vm", "postgresql-flexible"):
        assert e[yes]["telemetry"]["signals"]["dbm"]["supported"] == "yes", yes
    assert e["mysql-flexible"]["telemetry"]["signals"]["dbm"]["supported"] == "partial"
    for no in ("cosmos-nosql", "cosmos-mongodb-ru", "documentdb", "managed-redis", "managed-cassandra"):
        assert e[no]["telemetry"]["signals"]["dbm"]["supported"] == "no", no


def test_provider_gaps_cover_azapi_usage():
    gaps = {g["service_id"]: g for g in catalog_lib.load_yaml(catalog_lib.GAPS_PATH)["gaps"]}
    for sid, ent in _entries().items():
        for a in ent["iac"]["azapi"]:
            assert sid in gaps, sid
            assert {"type": a["type"], "api_version": a["api_version"]} in gaps[sid]["arm_types"], sid


def test_validator_detects_broken_entry(tmp_path, monkeypatch):
    """A retired service marked implemented and an unknown component must be rejected."""
    docs = catalog_lib.load_service_files()
    bad = yaml.safe_load(yaml.safe_dump(docs["databases.yaml"]))
    mariadb = next(s for s in bad["services"] if s["id"] == "mariadb")
    mariadb["status"]["implementation"] = "implemented"
    mariadb["iac"]["component"] = "does-not-exist"
    services_dir = tmp_path / "services"
    services_dir.mkdir()
    for name, doc in docs.items():
        (services_dir / name).write_text(yaml.safe_dump(bad if name == "databases.yaml" else doc, sort_keys=False))
    monkeypatch.setattr(catalog_lib, "SERVICES_DIR", services_dir)
    monkeypatch.setattr(validate, "load_service_files", catalog_lib.load_service_files)
    assert validate.main(["--quiet"]) == 1


@pytest.mark.parametrize("path", sorted((REPO / "catalog" / "services").glob("*.yaml")), ids=lambda p: p.name)
def test_every_entry_has_https_reference(path):
    doc = yaml.safe_load(path.read_text())
    for svc in doc["services"]:
        assert any(r.startswith("https://") for r in svc["references"]), svc["id"]
