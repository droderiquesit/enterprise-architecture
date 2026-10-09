"""pytest wrapper for tests/integration/run_e2e.py: one test per check of a single shared e2e run.

Opt-in (it builds images and starts ~25 containers): E2E=1 pytest -v tests/integration/test_e2e.py
E2E_KEEP=1 keeps the stack running afterwards; E2E_REBUILD=1 rebuilds the app images from source first.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_e2e  # noqa: E402

pytestmark = pytest.mark.skipif(os.environ.get("E2E") != "1", reason="local docker e2e run is opt-in: set E2E=1")


@pytest.fixture(scope="session")
def e2e():
    return run_e2e.run(keep=os.environ.get("E2E_KEEP") == "1", rebuild=os.environ.get("E2E_REBUILD") == "1")


def test_run_completed(e2e):
    assert not e2e["meta"].get("error"), e2e["meta"].get("error")


@pytest.mark.parametrize("check_id", [c for c, _ in run_e2e.CHECKS])
def test_check(e2e, check_id):
    r = e2e["results"].get(check_id)
    assert r is not None, f"check {check_id} did not run (see {e2e['evidence_dir']}/summary.json)"
    if r["result"] == "skip":
        pytest.skip(str(r["detail"]))
    assert r["result"] == "pass", f"{r['check']}: {r['detail']}"
