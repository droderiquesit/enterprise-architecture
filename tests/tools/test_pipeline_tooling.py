"""Template-contract lint (incl. negative fixtures), artifact promotion, release notes, Helm chart tooling."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess

import pytest
import yaml
from fixture_repo import REPO_ROOT

from tools.changeset.store import LocalStore
from tools.deploy import artifacts as art
from tools.deploy import charts
from tools.report import release_notes
from tools.validate import pipeline_templates as pt


# ------------------------------------------------------------ template lint
def test_template_lint_passes_on_repository():
    report = pt.run(REPO_ROOT)
    assert report.errors == [], "\n".join(map(str, report.errors))
    for entry in pt.ENTRY_FILES:
        m = report.metrics[entry]
        assert m["files"] <= pt.LIMITS["files"] and m["depth"] <= pt.LIMITS["depth"]
        assert m["expanded_bytes"] < pt.LIMITS["size_fail"]


@pytest.fixture()
def copy(tmp_path):
    for rel in ("azure-pipelines.yml", "azure-pipelines.applications.yml", "pipelines", "tools", "catalog",
                "versions.yaml", "environments"):
        src = REPO_ROOT / rel
        (shutil.copytree if src.is_dir() else shutil.copy)(src, tmp_path / rel)
    return tmp_path


def _rules(repo):
    return {f.rule for f in pt.run(repo).errors}


def _edit(path, fn):
    doc = yaml.safe_load(path.read_text())
    fn(doc)
    path.write_text(yaml.safe_dump(doc, sort_keys=False))


def test_template_lint_negative_missing_template_and_bad_parameters(copy):
    t = copy / "pipelines/templates/universal-stages.yml"

    def mutate(doc):
        jobs = doc["stages"][1]["jobs"]
        jobs[0]["parameters"]["bogus"] = 1                       # TC002 undeclared
        del jobs[0]["parameters"]["environment"]                 # TC003 required missing
        jobs.append({"template": "does-not-exist.yml"})          # TC001
        doc["stages"][2]["jobs"][0]["parameters"]["hostedImage"] = ["not", "a", "string"]   # TC004
    _edit(t, mutate)
    assert {"TC001", "TC002", "TC003", "TC004"} <= _rules(copy)


def test_template_lint_negative_undeclared_parameter_use_and_secret_echo(copy):
    p = copy / "pipelines/templates/smoke.yml"
    p.write_text(p.read_text().replace("python3 tools/smoke/smoke.py", "echo $(datadog-api-key); echo ${{ parameters.nope }}; python3 tools/smoke/smoke.py"))
    s = copy / "pipelines/scripts/tf-plan.sh"
    s.write_text(s.read_text().replace("set -euo pipefail", "set -euxo pipefail"))
    rules = _rules(copy)
    assert {"TC005", "TC009"} <= rules


def test_template_lint_negative_settings_key_and_stage_graph(copy):
    p = copy / "pipelines/templates/smoke.yml"
    p.write_text(p.read_text().replace("parameters.settings.stateStorageAccount", "parameters.settings.stateAccount"))
    g = copy / "pipelines/generated/platform-stages.yml"

    def mutate(doc):
        st = next(s for s in doc["stages"] if s.get("stage") == "P_foundation_identity")
        st["dependsOn"].append("P_does_not_exist")
        doc["stages"].append(dict(next(s for s in doc["stages"] if s.get("stage") == "Drift")))
    _edit(g, mutate)
    rules = _rules(copy)
    assert {"TC006", "TC007"} <= rules


def test_template_lint_negative_environments_and_entries(copy):
    (copy / "pipelines/variables/test.yml").unlink()                       # ENV001
    _edit(copy / "azure-pipelines.applications.yml",
          lambda d: d["parameters"][0]["values"].remove("prod"))           # ENV002
    _edit(copy / "pipelines/variables/prod.yml",
          lambda d: d["variables"].__setitem__("promoteFrom", "dev"))      # ENV003
    (copy / "pipelines/extra.yml").write_text("trigger: none\nextends:\n  template: templates/universal.yml\n")  # ENT001
    _edit(copy / "azure-pipelines.yml", lambda d: d["extends"]["parameters"].__setitem__("scope", "applications"))  # ENT002
    _edit(copy / "azure-pipelines.applications.yml", lambda d: d.pop("resources"))                              # ENT003
    rules = _rules(copy)
    assert {"ENV001", "ENV002", "ENV003", "ENT001", "ENT002", "ENT003"} <= rules


def test_template_lint_limits(copy, monkeypatch):
    monkeypatch.setitem(pt.LIMITS, "size_fail", 10_000)
    monkeypatch.setitem(pt.LIMITS, "files", 3)
    monkeypatch.setitem(pt.LIMITS, "jobs_per_stage", 5)
    assert {"LIM001", "LIM003", "LIM004"} <= _rules(copy)


def test_template_path_resolution_like_ado(tmp_path):
    inc = tmp_path / "pipelines/templates/a.yml"
    assert pt.resolve_ref(tmp_path, inc, "b.yml") == (tmp_path / "pipelines/templates/b.yml").resolve()
    assert pt.resolve_ref(tmp_path, inc, "../generated/x.yml") == (tmp_path / "pipelines/generated/x.yml").resolve()
    assert pt.resolve_ref(tmp_path, inc, "/pipelines/x.yml") == (tmp_path / "pipelines/x.yml").resolve()
    assert pt.resolve_ref(tmp_path, inc, "b.yml@self") == (tmp_path / "pipelines/templates/b.yml").resolve()
    assert pt.resolve_ref(tmp_path, inc, "b.yml@templates") is None


# --------------------------------------------------------------- promotion
def _selection(fp):
    return {"components": {"svc-bff": {"deploy_fp": fp}}}


def test_promote_copies_exact_digest_and_package(tmp_path, monkeypatch):
    fp = "a" * 64
    src_records, src_pkgs, dst_pkgs = (LocalStore(tmp_path / n) for n in ("rec", "srcpkg", "dstpkg"))
    data = b"zip-bytes"
    sha = hashlib.sha256(data).hexdigest()
    tag = "src-" + fp[:24]
    src_pkgs.put_bytes(f"hello-bff/{tag}.zip", data)
    src_records.put_json("dev/svc-bff.json", {"status": "succeeded", "deploy_fp": fp, "artifact_metadata": {
        "name": "hello-bff", "source_fp": fp, "tag": tag, "digest": "sha256:" + "d" * 64, "package_sha256": sha}})
    registry = {}

    def fake_digest(reg, ref):
        return registry.get((reg, ref), "")

    def fake_import(target, source, ref):
        assert source == "acrdev.azurecr.io/hello-bff@sha256:" + "d" * 64
        registry[(target, ref)] = source.split("@", 1)[1]

    monkeypatch.setattr(art, "_acr_digest", fake_digest)
    monkeypatch.setattr(art, "_acr_import", fake_import)
    meta = art.promote("svc-bff", _selection(fp), "test", "dev", src_records, src_pkgs, dst_pkgs,
                       "acrtest", "acrdev", "https://sttest.blob.core.windows.net/packages")
    assert meta["digest"] == "sha256:" + "d" * 64 and meta["image"].startswith("acrtest.azurecr.io/hello-bff@sha256:")
    assert meta["promoted_from"] == "dev" and meta["package_sha256"] == sha
    assert dst_pkgs.get_bytes(f"hello-bff/{tag}.zip") == data
    # second promotion is a no-op for the image (already present with the same digest)
    monkeypatch.setattr(art, "_acr_import", lambda *a: pytest.fail("re-imported"))
    art.promote("svc-bff", _selection(fp), "test", "dev", src_records, src_pkgs, dst_pkgs,
                "acrtest", "acrdev", "https://x/packages")


def test_promote_refuses_missing_or_different_source(tmp_path, monkeypatch):
    fp = "b" * 64
    rec = LocalStore(tmp_path / "rec")
    pk = LocalStore(tmp_path / "pk")
    args = ("svc-bff", _selection(fp), "test", "dev", rec, pk, pk, "acrtest", "acrdev", "u")
    with pytest.raises(art.PromotionError, match="no successful artifact record"):
        art.promote(*args)
    rec.put_json("dev/svc-bff.json", {"status": "succeeded", "deploy_fp": "c" * 64,
                                      "artifact_metadata": {"source_fp": "c" * 64, "package_sha256": "0"}})
    with pytest.raises(art.PromotionError, match="promote the same commit"):
        art.promote(*args)
    rec.put_json("dev/svc-bff.json", {"status": "succeeded", "deploy_fp": fp,
                                      "artifact_metadata": {"name": "hello-bff", "source_fp": fp, "package_sha256": "0"}})
    pk.put_bytes(f"hello-bff/src-{fp[:24]}.zip", b"tampered")
    with pytest.raises(art.PromotionError, match="sha256 differs"):
        art.promote(*args)


# ----------------------------------------------------------- release notes
def test_release_notes_and_tag_version(tmp_path):
    assert release_notes.tag_version("refs/tags/observability-v1.2.3") == "1.2.3"
    with pytest.raises(ValueError):
        release_notes.tag_version("refs/tags/v1.2.3")
    text = (REPO_ROOT / "observability/CHANGELOG.md").read_text()
    notes = release_notes.notes(text, "1.0.0")
    assert notes.startswith("## [1.0.0]") and "## [Unreleased]" not in notes
    with pytest.raises(ValueError):
        release_notes.notes(text, "9.9.9")
    v = (REPO_ROOT / "observability/VERSION").read_text().strip()
    assert release_notes.main(["--tag", f"refs/tags/observability-v{v}", "--version-file",
                               str(REPO_ROOT / "observability/VERSION")]) == 0
    assert release_notes.main(["--tag", "refs/tags/observability-v0.0.1", "--version-file",
                               str(REPO_ROOT / "observability/VERSION")]) == 1


# ------------------------------------------------------------------ charts
def test_chart_versions_are_content_addressed(tmp_path):
    c = tmp_path / "applications/charts/hello"
    (c / "templates").mkdir(parents=True)
    (c / "Chart.yaml").write_text("apiVersion: v2\nname: hello\nversion: 0.2.0\n")
    (c / "templates/cm.yaml").write_text("kind: ConfigMap\n")
    assert charts.charts(tmp_path) == [c]
    v1 = charts.package_version(c)
    assert v1.startswith("0.2.0+src") and len(v1.split("+src")[1]) == 12
    (c / "templates/cm.yaml").write_text("kind: ConfigMap # changed\n")
    assert charts.package_version(c) != v1


def test_chart_lint_and_package_with_helm(tmp_path):
    helm = shutil.which("helm")
    if not helm:
        pytest.skip("helm not installed (pipelines/scripts/install-tools.sh helm)")
    c = tmp_path / "applications/charts/hello"
    (c / "templates").mkdir(parents=True)
    (c / "Chart.yaml").write_text("apiVersion: v2\nname: hello\nversion: 0.1.0\ndescription: test\nicon: https://example.com/i.png\n")
    (c / "values.yaml").write_text("name: hello\n")
    (c / "templates/cm.yaml").write_text("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {{ .Values.name }}\ndata: {}\n")
    assert charts.main(["--repo", str(tmp_path), "lint"]) == 0
    out = tmp_path / "out"
    assert charts.main(["--repo", str(tmp_path), "package", "--out", str(out)]) == 0
    index = json.loads((out / "charts.json").read_text())
    assert index[0]["version"].startswith("0.1.0+src") and list(out.glob("hello-0.1.0+src*.tgz"))


# ------------------------------------------------------------ DSV secret rules
def test_template_lint_negative_secret_rules(copy):
    t = copy / "pipelines/templates/telemetry-verify.yml"
    text = t.read_text()
    text = text.replace("    variables:\n", "    variables:\n      - group: lab-dev-datadog\n", 1)
    text = text.replace("      - template: steps-setup.yml\n", "      - template: steps-setup.yml\n"
                        "      - task: AzureKeyVault@2\n        inputs: {azureSubscription: x, KeyVaultName: kv}\n"
                        "      - script: echo \"$TF_VAR_admin_password\" && printenv\n        displayName: leak\n", 1)
    t.write_text(text)
    v = copy / "pipelines/templates/validate.yml"
    v.write_text(v.read_text().replace("steps:\n", "steps:\n      - script: python3 tools/secrets/fetch.py ado --env dev --map X=fault-token\n", 1))
    (copy / "pipelines/variables/dev.yml").write_text((copy / "pipelines/variables/dev.yml").read_text()
                                                     .replace("dsvTenant: example-lab", "dsvTenant: other-tenant"))
    rules = _rules(copy)
    assert {"SEC001", "SEC002", "TC009", "ENV004"} <= rules


def test_pipeline_lint_forbids_key_vault_and_groups(copy):
    from tools.validate import pipeline_lint

    t = copy / "pipelines/templates/smoke.yml"
    t.write_text(t.read_text().replace("    variables:\n      LAB_ENV:", "    variables:\n      LAB_ENV:", 1)
                 .replace("      - template: steps-setup.yml\n", "      - template: steps-setup.yml\n"
                          "      - task: AzureKeyVault@2\n        inputs: {azureSubscription: x, KeyVaultName: kv}\n"
                          "      - script: echo $(DD_API_KEY)\n        displayName: leak\n", 1))
    errors = "\n".join(pipeline_lint.lint(copy, check_generated=False))
    assert "PL015" in errors and "PL009" in errors


def test_artifact_tfvars_reads_cross_scope_artifact_from_record(tmp_path):
    from tools.deploy.artifacts import RecordError, recorded_metadata

    store = LocalStore(tmp_path / "records")
    sel = {"components": {"img-dsv-fetch": {"deploy_fp": "a" * 64}}}
    with pytest.raises(RecordError):
        recorded_metadata("img-dsv-fetch", store, "dev", sel)
    store.put_json("dev/img-dsv-fetch.json", {"status": "succeeded", "artifact_metadata": {
        "name": "dsv-fetch", "digest": "sha256:" + "1" * 64, "image": "acr.azurecr.io/dsv-fetch@sha256:" + "1" * 64,
        "source_fp": "b" * 64, "tag": "src-" + "b" * 24}})
    with pytest.raises(RecordError, match="recorded source fingerprint"):
        recorded_metadata("img-dsv-fetch", store, "dev", sel)
    sel["components"]["img-dsv-fetch"]["deploy_fp"] = "b" * 64
    assert recorded_metadata("img-dsv-fetch", store, "dev", sel)["digest"].startswith("sha256:")
