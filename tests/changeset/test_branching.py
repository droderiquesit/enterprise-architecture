"""Trunk-based branching model: branch policy enforcement, hotfix promotion from release/*, CI supersession."""

from __future__ import annotations

from pathlib import Path

import pytest
from fixture_repo import commit_all, git, make_synthetic_repo, record_successful_deployment, write
from test_scopes_promotion import _deploy_records, _promotion_fixture

from tools.changeset.select import SelectionError, select_deploy, select_promote
from tools.changeset.store import LocalStore
from tools.config import branching

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("ref,expected", [
    ("refs/heads/main", "trunk"), ("refs/heads/release/2026.10", "release"), ("refs/heads/feature/x", "short-lived"),
    ("refs/heads/fix/y", "short-lived"), ("refs/heads/spike", "other"), ("refs/tags/observability-v1.2.0", "tag"),
    ("refs/pull/12/merge", "pr"),
])
def test_branch_kinds(ref, expected):
    assert branching.kind(branching.load(ROOT), ref) == expected


def _check(ref, mode="auto", env="dev", dry=False, reason="Manual"):
    return branching.check(ROOT, ref, reason, env, mode, dry)


def test_trunk_may_run_everything_promotion_allows():
    assert _check("refs/heads/main") == []
    assert _check("refs/heads/main", "promote", "test") == []
    assert _check("refs/heads/main", "auto", "dev", reason="Schedule") == []


def test_feature_branches_never_apply():
    errs = _check("refs/heads/feature/new-thing")
    assert any("can never apply" in e for e in errs)
    assert _check("refs/heads/feature/new-thing", dry=True) == []                       # plan-only in dev is fine
    assert any("may only plan against" in e for e in _check("refs/heads/feature/x", "promote", "prod", dry=True))
    assert _check("refs/heads/feature/x", reason="PullRequest") == []                     # PR validation
    assert any("scheduled runs only" in e for e in _check("refs/heads/fix/x", reason="Schedule", dry=True))


def test_release_branches_only_promote_or_hotfix_to_test_prod():
    assert _check("refs/heads/release/2026.10", "hotfix", "prod") == []
    assert _check("refs/heads/release/2026.10", "promote", "test") == []
    assert any("only deploy to" in e for e in _check("refs/heads/release/2026.10", "hotfix", "dev"))
    assert any("only run modes" in e for e in _check("refs/heads/release/2026.10", "auto", "test"))
    assert any("must match" in e for e in _check("refs/heads/release/oops", "hotfix", "test"))
    assert any("only runs from" in e for e in _check("refs/heads/main", "hotfix", "test"))


def test_tags_only_release_the_package():
    assert _check("refs/tags/observability-v1.0.0") == []
    assert _check("refs/tags/random") != []


def test_cli_exit_codes(capsys):
    assert branching.main(["check", "--ref", "refs/heads/feature/a", "--env", "dev", "--mode", "auto"]) == 1
    assert "can never apply" in capsys.readouterr().out
    assert branching.main(["check", "--ref", "refs/heads/main", "--env", "dev", "--mode", "auto"]) == 0


def test_universal_compiles_non_trunk_runs_as_dry_runs():
    text = (ROOT / "pipelines/templates/universal.yml").read_text()
    guard = ("not(or(eq(variables['Build.SourceBranch'], 'refs/heads/main'), "
             "startsWith(variables['Build.SourceBranch'], 'refs/heads/release/')))")
    assert text.count(guard) == 2                         # DRY_RUN variable and the dryRun passed to the stages
    assert "tools/config/branching.py check" in (ROOT / "pipelines/templates/universal-stages.yml").read_text()


# --------------------------------------------------------------------- hotfix
@pytest.fixture()
def chain(tmp_path):
    repo = make_synthetic_repo(tmp_path)
    _promotion_fixture(repo)
    dev, test = LocalStore(tmp_path / "dev-records"), LocalStore(tmp_path / "test-records")
    record_successful_deployment(repo, tmp_path / "dev-records")
    # test is promoted at this commit
    _deploy_records(repo, test, select_promote(repo, "test", test, "auto", dev, scope="platform"), env="test")
    _deploy_records(repo, test, select_promote(repo, "test", test, "auto", dev, scope="applications"), env="test")
    return repo, dev, test


def test_hotfix_from_release_branch(chain):
    repo, dev, test = chain
    promoted = git(repo, "rev-parse", "HEAD")
    # main moves on: an unrelated feature (not promoted) ...
    write(repo, "platform/data/cosmos/main.tf", "# cosmos v2 (feature, not promoted)\n")
    commit_all(repo, "feature")
    # ... and the fix lands on main first and is deployed to dev
    write(repo, "platform/data/sql/main.tf", "# sql fix\nlocals {\n  component = \"platform-db-sql\"\n}\n")
    fix = commit_all(repo, "fix sql")
    _deploy_records(repo, dev, select_deploy(repo, "dev", dev))
    # release branch cut from the promoted commit + cherry-pick of the fix only
    git(repo, "checkout", "-q", "-b", "release/2026.10", promoted)
    git(repo, "cherry-pick", fix)
    doc = select_promote(repo, "test", test, "auto", dev, scope="platform", hotfix=True)
    assert doc["mode"] == "hotfix" and doc["promotion"]["hotfix"] is True
    assert doc["summary"]["plan"] == ["platform-db-sql"]          # only the fix; cosmos v2 never reaches test
    # plain promote of the release branch is refused (dev runs other cosmos code than the branch)
    with pytest.raises(SelectionError):
        select_promote(repo, "test", test, "auto", dev, scope="platform")
    # a change made only on the release branch (never on main/dev) is refused
    write(repo, "platform/shared/main.tf", "# release-only change\n")
    commit_all(repo, "release only")
    with pytest.raises(SelectionError) as exc:
        select_promote(repo, "test", test, "auto", dev, scope="platform", hotfix=True)
    assert "platform-shared" in str(exc.value) and "land the fix on main" in str(exc.value)


# -------------------------------------------------------------- supersession
def test_latest_run_is_a_superset_of_superseded_runs(tmp_path):
    """runLatest on dev cancels queued older runs: the newest run must select everything they would have,
    because selection compares fingerprints with RECORDS (what really ran), not with the previous commit."""
    repo = make_synthetic_repo(tmp_path)
    records = LocalStore(tmp_path / "records")
    record_successful_deployment(repo, tmp_path / "records")
    write(repo, "platform/data/sql/main.tf", "# c1\n")
    c1 = commit_all(repo, "c1")
    write(repo, "platform/data/cosmos/main.tf", "# c2\n")
    c2 = commit_all(repo, "c2")
    run1 = select_deploy(repo, "dev", records, head=c1)            # queued, then canceled before applying
    run2 = select_deploy(repo, "dev", records, head=c2)            # the run that acquires the lock
    assert set(run1["summary"]["plan"]) <= set(run2["summary"]["plan"])
    assert {"platform-db-sql", "platform-db-cosmos"} <= set(run2["summary"]["plan"])
    # a superseded run that applied part of its work: records reflect it, nothing is lost or repeated
    partial = {k: v for k, v in run1["components"].items() if k == "platform-db-sql"}
    _deploy_records(repo, records, {"components": partial})
    run2b = select_deploy(repo, "dev", records, head=c2)
    assert "platform-db-cosmos" in run2b["summary"]["plan"]
    assert not run2b["components"]["platform-db-sql"]["plan"]      # applied by the superseded run: not repeated
    # c3 reverts c2 before anything applied it: the latest run selects only what differs from what really runs
    write(repo, "platform/data/cosmos/main.tf", git(repo, "show", f"{c1}:platform/data/cosmos/main.tf") + "\n")
    c3 = commit_all(repo, "revert c2")
    run3 = select_deploy(repo, "dev", records, head=c3)
    assert "platform-db-cosmos" not in run3["summary"]["plan"]
