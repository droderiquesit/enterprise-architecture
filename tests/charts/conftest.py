"""Fixtures for the hello-service Helm chart tests (helpers live in chartlib.py)."""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from chartlib import CHART, HELM


@pytest.fixture(scope="session")
def helm_bin() -> str:
    if not HELM:
        pytest.skip("helm not installed (install the pinned Helm CLI, see chart README)")
    return HELM


@pytest.fixture(scope="session")
def schema() -> dict:
    return json.loads((CHART / "values.schema.json").read_text())


@pytest.fixture(scope="session")
def kubeconform_cache(tmp_path_factory) -> Path:
    p = Path(os.environ.get("KUBECONFORM_CACHE") or (Path.home() / ".cache" / "kubeconform"))
    try:
        p.mkdir(parents=True, exist_ok=True)
    except OSError:
        p = tmp_path_factory.mktemp("kubeconform-cache")
    return p
