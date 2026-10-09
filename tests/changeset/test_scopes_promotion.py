"""Two pipelines (platform / applications), cross-scope ordering, promotion mode, charts as inputs, explain."""

from __future__ import annotations

import json

import pytest
import yaml
from fixture_repo import commit_all, git, make_synthetic_repo, record_successful_deployment, write

from tools.changeset.cli import main as cli
from tools.changeset.registry import load_registry
from tools.changeset.select import SelectionError, select_deploy, select_pr, select_promote
from tools.changeset.store import LocalStore
from tools.changeset.trees import WorkTree
from tools.contracts.materialize import contract_values, values_digest


def _publish_all(repo, contracts: LocalStore, env="dev", overrides=None):
    """Publish a v1 envelope for every produced contract (data may be overridden per contract)."""
    reg = load_registry(WorkTree(repo))
    for c in reg:
        for name in c.produces:
            data = (overrides or {}).get(name, {"id": name})
            contracts.put_json(f"{env}/{name}/v1.json", {
                "contract": name, "version": "1.0.0", "environment": env,
                "produced_by": {"component": c.id, "commit": "x"}, "data": data})


def _record_contracts(repo, records: LocalStore, contracts: LocalStore, env="dev"):
    """Store the contracts digest each component was deployed with (what record.py takes from the manifest)."""
    from tools.changeset.select import Context

    ctx = Context(repo, env)
    for cid in ctx.enabled:
        c = ctx.registry.get(cid)
        rec = records.get_json(f"{env}/{cid}.json")
        if rec and c.deployable:
            values, _ = contract_values(ctx.tree, ctx.registry, ctx.enabled, env, cid, contracts)
            rec["contracts_sha"] = values_digest(values)
            records.put_json(f"{env}/{cid}.json", rec)


def _deploy_records(repo, records: LocalStore, doc: dict, env="dev"):
    """Simulate a successful run of `doc`: planned/built components get succeeded records."""
    for cid, e in doc["components"].items():
        if e["plan"] or e["build"] or e["resolve"]:
            old = records.get_json(f"{env}/{cid}.json") or {}
            records.put_json(f"{env}/{cid}.json", dict(old, component=cid, env=env, kind=e["kind"], path=e["path"],
                                                        status="succeeded", deploy_fp=e["deploy_fp"],
                                                        fp_parts=e["fp_parts"], scope=e["scope"],
                                                        upstream=e["upstream"], produces=e["produces"]))


@pytest.fixture()
def lab(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    records, contracts = LocalStore(tmp_path / "records"), LocalStore(tmp_path / "contracts")
    record_successful_deployment(repo, tmp_path / "records")
    _publish_all(repo, contracts)
    _record_contracts(repo, records, contracts)
    return repo, records, contracts


def test_scopes_split_selection(lab):
    repo, records, contracts = lab
    write(repo, "platform/data/sql/main.tf", "# sql v2\nlocals {\n  component = \"platform-db-sql\"\n}\n")
    write(repo, "applications/services/bff/src/Program.cs", "// bff v2\n")
    commit_all(repo, "both scopes")
    plat = select_deploy(repo, "dev", records, scope="platform", contracts_store=contracts)
    apps = select_deploy(repo, "dev", records, scope="applications", contracts_store=contracts)
    assert plat["summary"]["plan"] == ["platform-db-sql"]
    assert plat["artifacts_to_build"] == []                       # artifacts belong to the applications pipeline
    assert apps["artifacts_to_build"] == ["svc-bff"]
    # deploy-core-aca ships svc-bff but consumes platform-db-sql, which the platform pipeline has not deployed yet
    assert apps["summary"]["plan"] == []
    assert apps["components"]["deploy-core-aca"]["waiting_for"] == ["platform-db-sql"]


def test_cross_scope_ordering_replans_consumers_after_platform_contract_change(lab):
    repo, records, contracts = lab
    write(repo, "foundation/network/main.tf", "# network v2\nlocals {\n  component = \"foundation-network\"\n}\n")
    commit_all(repo, "network change")
    # 1. applications run on the same commit (its own CI trigger): consumers wait, nothing applies against
    #    contracts that are about to change
    apps = select_deploy(repo, "dev", records, scope="applications", contracts_store=contracts)
    assert apps["summary"]["plan"] == [] and "deploy-core-aca" in apps["summary"]["waiting"]
    # 2. platform run deploys network (+ re-plans its platform consumers); shared's contract changes
    plat = select_deploy(repo, "dev", records, scope="platform", contracts_store=contracts)
    assert "foundation-network" in plat["summary"]["plan"]
    _deploy_records(repo, records, plat)
    _publish_all(repo, contracts, overrides={"platform-shared": {"id": "platform-shared", "acr": "new"}})
    # 3. the applications run triggered by the successful platform run re-plans exactly the consumers whose
    #    materialized contracts changed (deploy-core-aca consumes platform-shared; dbadapters does not)
    apps = select_deploy(repo, "dev", records, scope="applications", contracts_store=contracts)
    assert apps["summary"]["waiting"] == []
    assert "deploy-core-aca" in apps["summary"]["plan"]
    assert "upstream contract changed since the last deployment" in apps["components"]["deploy-core-aca"]["reason"]
    assert "deploy-dbadapters" not in apps["summary"]["plan"]


def test_platform_change_without_contract_change_redeploys_no_application(lab):
    repo, records, contracts = lab
    write(repo, "foundation/network/main.tf", "# network v2\nlocals {\n  component = \"foundation-network\"\n}\n")
    commit_all(repo, "network change")
    plat = select_deploy(repo, "dev", records, scope="platform", contracts_store=contracts)
    _deploy_records(repo, records, plat)
    apps = select_deploy(repo, "dev", records, scope="applications", contracts_store=contracts)
    assert apps["summary"]["plan"] == [] and apps["summary"]["waiting"] == []


def test_docs_only_change_selects_nothing_in_either_pipeline(lab):
    repo, records, contracts = lab
    git(repo, "checkout", "-q", "-b", "docs")
    write(repo, "docs/index.md", "# docs v2\n")
    commit_all(repo, "docs")
    for scope in ("platform", "applications"):
        assert select_deploy(repo, "dev", records, scope=scope, contracts_store=contracts)["summary"]["plan"] == []
        pr = select_pr(repo, "dev", target="main", scope=scope)
        assert pr["summary"]["plan"] == [] and pr["artifacts_to_build"] == []
    assert select_pr(repo, "dev", target="main", scope="platform")["summary"]["validate"] == ["docs"]
    assert select_pr(repo, "dev", target="main", scope="applications")["summary"]["validate"] == []


def test_pr_validation_is_split_by_scope(lab):
    repo, _records, _contracts = lab
    git(repo, "checkout", "-q", "-b", "feature")
    write(repo, "foundation/network/main.tf", "# network v2\nlocals {\n  component = \"foundation-network\"\n}\n")
    commit_all(repo, "network")
    plat = select_pr(repo, "dev", target="main", scope="platform")
    apps = select_pr(repo, "dev", target="main", scope="applications")
    assert "foundation-network" in plat["summary"]["validate"] and "deploy-core-aca" not in plat["summary"]["validate"]
    assert "deploy-core-aca" in apps["summary"]["validate"] and "foundation-network" not in apps["summary"]["validate"]


def test_helm_chart_change_selects_the_deploy_root_that_uses_it(lab):
    repo, records, contracts = lab
    write(repo, "applications/charts/hello/Chart.yaml", "apiVersion: v2\nname: hello\nversion: 0.1.0\n")
    write(repo, "applications/charts/hello/templates/cm.yaml", "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n")
    main = (repo / "applications/deployments/core-aca/main.tf").read_text()
    write(repo, "applications/deployments/core-aca/main.tf",
          main + '\nlocals {\n  chart = "${path.module}/../../charts/hello"\n}\n')
    commit_all(repo, "use chart")
    plat = select_deploy(repo, "dev", records, scope="platform", contracts_store=contracts)
    apps = select_deploy(repo, "dev", records, scope="applications", contracts_store=contracts)
    _deploy_records(repo, records, apps)
    write(repo, "applications/charts/hello/templates/cm.yaml", "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: y\n")
    commit_all(repo, "chart change")
    apps = select_deploy(repo, "dev", records, scope="applications", contracts_store=contracts)
    assert "deploy-core-aca" in apps["summary"]["plan"]
    assert apps["components"]["deploy-core-aca"]["changed_parts"] == ["source"]
    # its contract consumers are re-planned (apply only if their plan changes); unrelated roots are not
    assert set(apps["summary"]["plan"]) == {"deploy-core-aca", "deploy-frontend", "obs-monitoring"}
    assert plat["summary"]["plan"] == []


def _promotion_fixture(repo):
    write(repo, "environments/promotion.yaml", yaml.safe_dump({"schema_version": 1, "chains": [{"name": "lab", "environments": [
        {"name": "dev", "ado_environment": "lab-dev", "retire_environment": "lab-dev-retire", "ci_trigger": True,
         "allowed_modes": ["auto", "manual", "reconcile", "drift", "retire"]},
        {"name": "test", "promote_from": "dev", "ado_environment": "lab-test", "retire_environment": "lab-test-retire",
         "allowed_modes": ["promote", "drift", "retire"]}]}]}))
    env = yaml.safe_load((repo / "environments/dev/environment.yaml").read_text())
    env["environment"]["name"] = "test"
    write(repo, "environments/test/environment.yaml", yaml.safe_dump(env))
    commit_all(repo, "test env")


def test_promote_mode_requires_source_environment_to_run_the_same_code(lab, tmp_path):
    repo, dev_records, _contracts = lab
    _promotion_fixture(repo)
    # dev records were written before the promotion commit, but that commit changed no component input
    test_records = LocalStore(tmp_path / "test-records")
    doc = select_promote(repo, "test", test_records, "auto", dev_records, scope="platform")
    assert doc["mode"] == "promote" and doc["promotion"]["source"] == "dev"
    assert "foundation-network" in doc["summary"]["plan"]           # test has never been deployed
    apps = select_promote(repo, "test", test_records, "dev", dev_records, scope="applications")
    assert "svc-bff" in apps["artifacts_to_build"]                    # promoted (copied), never rebuilt
    # new code that dev has not deployed cannot be promoted
    write(repo, "platform/data/sql/main.tf", "# sql v3\nlocals {\n  component = \"platform-db-sql\"\n}\n")
    commit_all(repo, "sql v3")
    with pytest.raises(SelectionError) as exc:
        select_promote(repo, "test", test_records, "auto", dev_records, scope="platform")
    assert "platform-db-sql" in str(exc.value) and "deploy this commit there first" in str(exc.value)
    # the applications pipeline is unaffected by a platform-only difference
    select_promote(repo, "test", test_records, "auto", dev_records, scope="applications")
    with pytest.raises(SelectionError):
        select_promote(repo, "test", test_records, "prod", dev_records, scope="platform")
    with pytest.raises(SelectionError):
        select_promote(repo, "dev", dev_records, "auto", dev_records, scope="platform")


def test_promotion_policy_check_cli(lab):
    repo, _r, _c = lab
    _promotion_fixture(repo)
    from tools.config.promotion import check

    assert check(repo, "dev", "auto", False) == []
    assert check(repo, "test", "promote", False) == []
    assert any("not allowed" in e for e in check(repo, "test", "auto", False))
    assert any("cannot be promoted into" in e for e in check(repo, "dev", "promote", False))
    assert check(repo, "nope", "auto", False)


def test_explain_previews_working_tree(lab, capsys):
    repo, records, contracts = lab
    git(repo, "checkout", "-q", "-b", "wip")
    write(repo, "observability/archetypes/web-service.yaml", "monitors: [latency, uncommitted]\n")
    assert cli(["--repo", str(repo), "explain", "--env", "dev", "--target", "main"]) == 0
    out = capsys.readouterr().out
    assert "obs-monitoring" in out and "applications" in out
    assert "azure-pipelines.applications.yml" in out
    assert cli(["--repo", str(repo), "explain", "--env", "dev", "--records-dir", str(records.root),
                "--contracts-dir", str(contracts.root), "--scope", "applications", "--json"]) == 0
    doc = json.loads(capsys.readouterr().out)
    assert doc["summary"]["plan"] == ["obs-monitoring"]


def test_platform_artifact_consumed_by_applications_root_waits_for_platform_build(tmp_path):
    """img-dsv-fetch (scope platform) is an artifact of deploy-core-aca (applications): a change to it is built by the
    platform pipeline; the applications pipeline waits, then re-deploys the consumer with the recorded digest."""
    import copy

    from fixture_repo import FIXTURE_ENABLED, SYNTHETIC_REGISTRY

    reg = copy.deepcopy(SYNTHETIC_REGISTRY)
    reg["components"].insert(-1, {"id": "img-dsv-fetch", "layer": "observability", "kind": "artifact",
                                  "path": "observability/images/dsv-fetch", "scope": "platform",
                                  "artifact": {"type": "container-image", "name": "dsv-fetch"}})
    for c in reg["components"]:
        if c["id"] in ("deploy-core-aca", "obs-telemetry-transport"):
            c["artifacts"] = list(c.get("artifacts", [])) + ["img-dsv-fetch"]
    repo = make_synthetic_repo(tmp_path, enabled=FIXTURE_ENABLED + ["img-dsv-fetch"], registry=reg)
    records, contracts = LocalStore(tmp_path / "records"), LocalStore(tmp_path / "contracts")
    record_successful_deployment(repo, tmp_path / "records")
    _publish_all(repo, contracts)
    _record_contracts(repo, records, contracts)

    write(repo, "observability/images/dsv-fetch/src/Program.cs", "// dsv-fetch v2\n")
    commit_all(repo, "dsv-fetch change")
    apps = select_deploy(repo, "dev", records, scope="applications", contracts_store=contracts)
    assert apps["components"]["img-dsv-fetch"]["build"] is False            # never built by the applications pipeline
    assert "img-dsv-fetch" in apps["components"]["deploy-core-aca"]["waiting_for"]
    plat = select_deploy(repo, "dev", records, scope="platform", contracts_store=contracts)
    assert plat["components"]["img-dsv-fetch"]["build"] is True
    assert "obs-telemetry-transport" in plat["summary"]["plan"]             # in-scope consumer re-deploys
    _deploy_records(repo, records, plat)
    apps = select_deploy(repo, "dev", records, scope="applications", contracts_store=contracts)
    assert apps["summary"]["waiting"] == [] and "deploy-core-aca" in apps["summary"]["plan"]
    assert "deploy-dbadapters" not in apps["summary"]["plan"]
