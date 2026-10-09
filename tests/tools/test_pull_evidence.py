"""tools/report/pull_evidence.py against a local directory store (offline)."""

from __future__ import annotations

import json

from fixture_repo import REPO_ROOT  # noqa: F401  (sets sys.path)

from tools.changeset.store import LocalStore
from tools.report import pull_evidence


def _seed(root, env="dev", run="42", **overrides):
    store = LocalStore(root)
    ev = {"schema_version": 1, "environment": env, "run_id": run, "commit": "abc",
          "components": {"foundation-network": {"status": "deployed"}, "deploy-core-aca": {"status": "verified"}}}
    ev.update(overrides)
    store.put_json(f"{env}/runs/{run}/evidence.json", ev)
    store.put_bytes(f"{env}/runs/{run}/deployment-report.md", b"# report\n", "text/markdown")
    store.put_json(f"{env}/runs/other/evidence.json", {"environment": env, "run_id": "other"})
    return store


def test_pull_copies_run_and_writes_source(tmp_path):
    _seed(tmp_path / "store")
    dest = tmp_path / "docs-evidence"
    rc = pull_evidence.main(["--store", str(tmp_path / "store"), "--env", "dev", "--run-id", "42", "--dest", str(dest)])
    assert rc == 0
    out = dest / "dev" / "42"
    assert sorted(p.name for p in out.iterdir()) == ["SOURCE.json", "deployment-report.md", "evidence.json"]
    src = json.loads((out / "SOURCE.json").read_text())
    assert src["prefix"] == "dev/runs/42/" and set(src["files"]) == {"evidence.json", "deployment-report.md"}
    # refuses to overwrite without --force, succeeds with it
    assert pull_evidence.main(["--store", str(tmp_path / "store"), "--env", "dev", "--run-id", "42", "--dest", str(dest)]) == 1
    assert pull_evidence.main(["--store", f"file://{tmp_path / 'store'}", "--env", "dev", "--run-id", "42",
                               "--dest", str(dest), "--force"]) == 0


def test_pull_rejects_missing_mismatched_and_secret_like(tmp_path, capsys):
    dest = tmp_path / "d"
    assert pull_evidence.main(["--store", str(tmp_path / "empty"), "--env", "dev", "--run-id", "1", "--dest", str(dest)]) == 1
    _seed(tmp_path / "s1", run="7", run_id="8")
    assert pull_evidence.main(["--store", str(tmp_path / "s1"), "--env", "dev", "--run-id", "7", "--dest", str(dest)]) == 1
    assert "expected 'dev'/'7'" in capsys.readouterr().err
    _seed(tmp_path / "s2", run="9", extra={"api_key": "abc123"})
    assert pull_evidence.main(["--store", str(tmp_path / "s2"), "--env", "dev", "--run-id", "9", "--dest", str(dest)]) == 1
    assert "secret-looking" in capsys.readouterr().err
    assert not (dest / "dev" / "9").exists()
    assert pull_evidence.main(["--store", str(tmp_path / "s2"), "--env", "dev", "--run-id", "../x", "--dest", str(dest)]) == 1
