"""tools/ci: test impact selection, fingerprint test result cache, balancing, local runner, report, scanners."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from tools.changeset.registry import load_registry
from tools.changeset.trees import Tree, WorkTree
from tools.ci import balance, catalog, impact, report, scan, tfmirror
from tools.ci.cache import ResultCache
from tools.ci.cli import build_plan, execute, main as ci_main, record_passes

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def real():
    tree = WorkTree(ROOT)
    reg = load_registry(tree)
    return tree, reg, catalog.load(tree, reg)


def _sel(changed, validate=(), modules=(), comps_extra=None):
    reg = load_registry(WorkTree(ROOT))
    comps = {}
    for c in reg:
        comps[c.id] = {"validate": c.id in validate, "validation_fp": f"vfp-{c.id}", "reason": [f"{c.id} changed"]}
    comps.update(comps_extra or {})
    doc = {"components": comps, "modules_to_validate": list(modules)}
    if changed is not None:
        doc["changed_files"] = [{"path": p, "status": "M", "old_path": None} for p in changed]
    return doc


def _ids(sel):
    return set(sel)


# ----------------------------------------------------------------------------------------- impact selection
def test_docs_only_change_selects_gate_and_link_check_only(real):
    tree, reg, cat = real
    sel = impact.select(cat, _sel(["docs/guides/quick-start.md"], validate=["docs"]), tree, reg)
    assert _ids(sel) == {"gates", "docs-links", "component:docs"}


def test_tool_change_selects_its_suites_not_unrelated_ones(real):
    tree, reg, cat = real
    sel = impact.select(cat, _sel(["tools/review/engine.py"]), tree, reg)
    assert {"py-review", "py-pr-reviewer", "py-tools", "gates"} <= _ids(sel)
    assert not {"py-charts", "obs-content", "e2e", "py-hello-common"} & _ids(sel)
    assert not any(s.startswith("component:") for s in sel)


def test_component_and_consumers_and_covering_suites(real):
    tree, reg, cat = real
    # the changeset selection validates the changed component AND its transitive consumers; tools/ci maps both
    sel = impact.select(cat, _sel(["applications/shared/python/hello_common/src/hello_common/app.py"],
                                  validate=["svc-catalog-api", "svc-worker"]), tree, reg)
    assert {"component:svc-catalog-api", "component:svc-worker", "py-hello-common", "e2e"} <= _ids(sel)
    assert "component:svc-bff" not in sel and "dotnet-hello-common" not in sel
    assert sel["py-hello-common"]["reasons"][0].startswith("input changed")
    # a service-only change does not run the shared library's suite; a suite that `covers` it does run
    svc = impact.select(cat, _sel(["applications/services/catalog-api/src/x.py"], validate=["svc-catalog-api"]), tree, reg)
    assert "component:svc-catalog-api" in svc and "py-hello-common" not in svc
    transport = impact.select(cat, _sel(["observability/lab/hosts/main.tf"], validate=["obs-hosts"]), tree, reg)
    assert "covers selected component(s): obs-hosts" in transport["obs-transport"]["reasons"]


def test_shared_module_change_selects_module_suite(real):
    tree, reg, cat = real
    sel = impact.select(cat, _sel(["foundation/modules/naming/main.tf"], modules=["foundation/modules/naming"]), tree, reg)
    assert "module:foundation/modules/naming" in sel


def test_global_input_change_selects_everything(real):
    tree, reg, cat = real
    sel = impact.select(cat, _sel(["versions.yaml"]), tree, reg)
    non_component = {s for s in cat.suites if not s.startswith("component:")}
    assert non_component <= _ids(sel)
    assert all("global input changed" in v["reasons"][0] for v in sel.values())


def test_scope_filter_and_deploy_runs(real):
    tree, reg, cat = real
    sel = impact.select(cat, _sel(["versions.yaml"]), tree, reg, scope="applications")
    assert "py-charts" in sel and "py-tools" not in sel
    assert all(cat.suites[s].scope == "applications" for s in sel if s in cat.suites)
    deploy = impact.select(cat, _sel(None), tree, reg)            # no diff (main deploy run): all, via the cache
    assert "py-tools" in deploy and "deploy run" in deploy["py-tools"]["reasons"][0]


def test_suites_catalog_is_valid_and_sorted():
    assert ci_main(["check"]) == 0
    import yaml

    doc = yaml.safe_load((ROOT / catalog.SUITES_FILE).read_text())
    bad = dict(doc, suites=list(reversed(doc["suites"])))
    assert "suites must be sorted by id" in catalog.validate_doc(bad)
    broken = dict(doc, suites=[dict(doc["suites"][0], tier="slow")])
    assert any("tier" in e for e in catalog.validate_doc(broken))


# ----------------------------------------------------------------------------------------- fingerprints + cache
class DictTree(Tree):
    def __init__(self, files):
        self._f = files

    def files(self):
        return {p: str(hash(v)) for p, v in self._f.items()}

    def read_bytes(self, path):
        v = self._f.get(path)
        return None if v is None else v.encode()


def test_fingerprint_changes_only_with_inputs():
    cat = catalog.Catalog(suites={}, global_inputs=["versions.yaml"], defaults={})
    s = catalog.Suite(id="py-x", inputs=["tools/x/**"], paths=["tests/x"])
    base = {"versions.yaml": "terraform: {cli: 1.16.5}\n", "tools/x/a.py": "a", "docs/readme.md": "r"}
    fp = catalog.fingerprint(s, DictTree(base), cat)
    assert fp == catalog.fingerprint(s, DictTree(dict(base, **{"docs/readme.md": "changed"})), cat)   # not an input
    assert fp != catalog.fingerprint(s, DictTree(dict(base, **{"tools/x/a.py": "b"})), cat)           # input
    assert fp != catalog.fingerprint(s, DictTree(dict(base, **{"versions.yaml": "terraform: {cli: 1.17.0}\n"})), cat)


def test_cached_pass_is_skipped_and_full_runs_ignore_the_cache(tmp_path):
    cache = ResultCache.open(str(tmp_path / "tc"))
    sel = _sel(["docs/guides/quick-start.md"], validate=["docs"])
    plan = build_plan(ROOT, sel, cache=cache)
    assert {s for s, e in plan["suites"].items() if e["status"] == "run"} == {"gates", "docs-links", "component:docs"}
    fp = plan["suites"]["docs-links"]["fingerprint"]
    cache.record("docs-links", fp, 3.2)
    again = build_plan(ROOT, sel, cache=cache)
    assert again["suites"]["docs-links"]["status"] == "cached"
    assert all("docs-links" not in [u["suite"] for u in lg["units"]] for lg in again["legs"])
    assert build_plan(ROOT, sel, cache=cache, full=True)["suites"]["docs-links"]["status"] == "run"
    assert again["suites"]["gates"]["status"] == "run"          # gates are never cached (cache: false)
    # sharded suites: all parts must pass before the suite counts as cached
    cache.record("py-tools", "fpX", 1.0, ["a.py"])
    assert cache.hit("fpX") is None and not cache.promote("py-tools", "fpX", [["a.py"], ["b.py"]])
    cache.record("py-tools", "fpX", 1.0, ["b.py"])
    assert cache.promote("py-tools", "fpX", [["a.py"], ["b.py"]]) and cache.hit("fpX")


# ----------------------------------------------------------------------------------------- balancing
def test_sharding_and_packing_are_balanced_and_deterministic():
    timings = {"suites": {}, "files": {f"t/test_{i}.py": float(10 + i) for i in range(20)}}
    s = catalog.Suite(id="py-big", paths=["t"], toolchain="python")
    files = sorted(timings["files"])
    units = balance.units_for(s, timings, target=60, files=files)
    assert len(units) == 7 and sorted(f for u in units for f in u.files) == files       # ceil(390 s / 60 s)
    loads = [u.seconds for u in units]
    assert max(loads) - min(loads) <= 29                                                 # LPT: within one item
    assert units == balance.units_for(s, timings, target=60, files=list(reversed(files)))
    gate = balance.Unit("gates", "terraform", "gate", 20)
    tf = [balance.Unit(f"component:r{i}", "terraform", "unit", 25) for i in range(30)]
    legs = balance.pack([gate, *units, *tf], target=120, max_legs=8)
    assert legs[0].name == "gates" and [u.suite for u in legs[0].units] == ["gates"]
    assert len(legs) <= 8 and {lg.toolchain for lg in legs} == {"terraform", "python"}
    assert sum(len(lg.units) for lg in legs) == 1 + len(units) + len(tf)


def test_timings_merge_is_ewma_and_sorted():
    m = balance.merge_timings({"suites": {"b": 10.0}}, {"suites": {"b": 20.0, "a": 4.0}, "files": {"x": 1.0}})
    assert m["suites"] == {"a": 4.0, "b": 15.0} and list(m["suites"]) == ["a", "b"]


# ----------------------------------------------------------------------------------------- runner + report
def test_local_run_executes_selected_units_in_parallel_and_records(tmp_path, monkeypatch):
    from tools.ci import cli

    real_suites = cli._suites_for

    def hermetic(repo, plan):     # same plan/fingerprints; the link check itself replaced by a deterministic script
        out = real_suites(repo, plan)
        out["docs-links"] = catalog.Suite(id="docs-links", kind="script", argv=["python3", "-c", "print('links ok')"],
                                          inputs=["**/*.md"], tier="gate")
        return out
    monkeypatch.setattr(cli, "_suites_for", hermetic)
    cache = ResultCache.open(str(tmp_path / "tc"))
    sel = _sel(["docs/guides/quick-start.md"])
    plan = build_plan(ROOT, sel, cache=cache)
    legs = [{"name": "x", "units": [u for lg in plan["legs"] for u in lg["units"] if u["suite"] == "docs-links"]}]
    doc = execute(ROOT, plan, legs, jobs=2, out_dir=tmp_path / "out", cache=cache, env_name="dev",
                  enable_env_suites=False, leg_name="x")
    assert [r["status"] for r in doc["results"]] == ["passed"]
    assert (tmp_path / "out" / "ci-results.json").exists()
    assert cache.hit(plan["suites"]["docs-links"]["fingerprint"])      # pass recorded locally
    rep = report.build(plan, [doc])
    assert rep["change_class"] == "docs-only" and rep["budget_minutes"] == 2 and rep["suites_run"] == 1
    assert "CI speed" in report.markdown(rep)
    other = ResultCache.open(str(tmp_path / "agg"))
    assert record_passes(plan, [doc], other) == 1                     # ci_report aggregates the legs' passes


def test_runner_failure_timeout_and_needs_env(tmp_path):
    from tools.ci.runner import run_units

    suites = {"ok": catalog.Suite(id="ok", kind="script", argv=["python3", "-c", "print(1)"], inputs=["x"]),
              "bad": catalog.Suite(id="bad", kind="script", argv=["python3", "-c", "import sys; sys.exit(3)"], inputs=["x"]),
              "e2e": catalog.Suite(id="e2e", kind="script", argv=["python3", "-c", "print(1)"], inputs=["x"],
                                   needs_env={"E2E_TEST_ONLY": "1"})}
    units = [balance.Unit(s, "python", "unit", 1.0) for s in suites]
    res = {r["suite"]: r for r in run_units(units, suites, ROOT, jobs=3, out_dir=tmp_path, echo=lambda *_: None)}
    assert res["ok"]["status"] == "passed" and res["bad"]["status"] == "failed" and res["bad"]["exit_code"] == 3
    assert res["e2e"]["status"] == "skipped"


def test_critical_path_from_timeline():
    tl = {"records": [
        {"type": "Stage", "name": "Select", "startTime": "2026-10-09T10:00:00Z", "finishTime": "2026-10-09T10:01:00Z"},
        {"type": "Stage", "name": "Validate", "startTime": "2026-10-09T10:01:05Z", "finishTime": "2026-10-09T10:07:00Z"},
        {"type": "Stage", "name": "Security", "startTime": "2026-10-09T10:01:05Z", "finishTime": "2026-10-09T10:04:00Z"}]}
    assert [s["stage"] for s in report.critical_path(tl)] == ["Select", "Validate"]


# ----------------------------------------------------------------------------------------- terraform mirror
def test_provider_mirror(tmp_path):
    root = tmp_path / "r"
    root.mkdir()
    (root / ".terraform.lock.hcl").write_text('provider "registry.terraform.io/hashicorp/azurerm" {\n  version     = "5.9.0"\n'
                                              '  constraints = "5.9.0"\n  hashes = []\n}\n')
    provs = tfmirror.lock_providers(tmp_path, ["r"])
    assert provs == {("registry.terraform.io/hashicorp/azurerm", "5.9.0")}
    calls = []

    def fake(cmd, **kw):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, "", "")
    mirror = tmp_path / "m"
    assert tfmirror.populate(mirror, provs, runner=fake) == ["registry.terraform.io/hashicorp/azurerm 5.9.0"]
    assert calls[0][2:4] == ["providers", "mirror"]
    (mirror / "registry.terraform.io/hashicorp/azurerm/5.9.0/linux_amd64").mkdir(parents=True)
    assert tfmirror.populate(mirror, provs, runner=fake) == []        # present: nothing downloaded
    cfg = tfmirror.cli_config(mirror, tmp_path / "rc").read_text()
    assert "filesystem_mirror" in cfg and "plugin_cache_dir" not in cfg
    assert len(tfmirror.lock_providers(ROOT)) >= 4                     # every committed lock file


# ----------------------------------------------------------------------------------------- scanners / gates
def test_scanners_scope_follows_the_change(tmp_path, monkeypatch):
    monkeypatch.setattr(scan.shutil, "which", lambda name: f"/usr/bin/{name}")
    sel = {"base": "abc", "changed_files": [{"path": "foundation/network/main.tf", "status": "M"},
                                            {"path": "applications/services/bff/Dockerfile", "status": "M"},
                                            {"path": "pipelines/scripts/tf-plan.sh", "status": "M"}]}
    cmds = dict(scan.plan(ROOT, tmp_path, sel, full=False, fail=True))
    assert "--log-opts=abc..HEAD" in cmds["gitleaks"]
    assert cmds["checkov"][cmds["checkov"].index("--directory") + 1] == "foundation/network"
    assert cmds["hadolint"][-1] == "applications/services/bff/Dockerfile"
    assert cmds["shellcheck"][-1] == "pipelines/scripts/tf-plan.sh"
    assert any(k.startswith("trivy:foundation/network") for k in cmds)
    full = dict(scan.plan(ROOT, tmp_path, sel, full=True, fail=False))
    assert "--soft-fail" in full["checkov"] and "dir" in full["gitleaks"] and "trivy:." in full


def test_failfast_cancels_only_inside_azure_devops(monkeypatch):
    from tools.ci.failfast import cancel_run

    for k in ("SYSTEM_COLLECTIONURI", "SYSTEM_ACCESSTOKEN"):
        monkeypatch.delenv(k, raising=False)
    assert cancel_run(http=lambda *a: (_ for _ in ()).throw(AssertionError("no call")))
    monkeypatch.setenv("SYSTEM_COLLECTIONURI", "https://dev.azure.com/o/")
    monkeypatch.setenv("SYSTEM_TEAMPROJECT", "p")
    monkeypatch.setenv("BUILD_BUILDID", "7")
    monkeypatch.setenv("SYSTEM_ACCESSTOKEN", "t")
    seen = []
    assert cancel_run(http=lambda m, u, b: seen.append((m, u, b)) or {"id": 7})
    assert seen[0][0] == "PATCH" and seen[0][2] == {"status": "cancelling"} and "/builds/7?" in seen[0][1]


def test_cli_plan_ado_outputs(tmp_path, capsys):
    sel = tmp_path / "sel.json"
    sel.write_text(json.dumps(_sel(["docs/guides/quick-start.md"], validate=["docs"])))
    assert ci_main(["plan", "--selection", str(sel), "--no-cache", "--out", str(tmp_path / "p.json"), "--ado"]) == 0
    out = capsys.readouterr().out
    line = next(x for x in out.splitlines() if "variable=matrix" in x)
    matrix = json.loads(line.split("]", 1)[1])
    assert "gates" in matrix and all(set(v) == {"CI_LEG", "CI_TOOLCHAIN"} for v in matrix.values())
    assert json.loads((tmp_path / "p.json").read_text())["estimate"]["legs"] == len(matrix)


def test_python_module_entrypoint():
    p = subprocess.run([sys.executable, "-m", "tools.ci", "check"], cwd=ROOT, capture_output=True, text=True)
    assert p.returncode == 0, p.stdout + p.stderr
