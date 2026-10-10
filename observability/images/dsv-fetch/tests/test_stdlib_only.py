"""Static checks: the Go module uses the standard library only (static binary, no third-party code); the 1.x Python
implementation stays retired."""

from __future__ import annotations

import re

import pytest
from conftest import IMAGE_DIR


@pytest.fixture(autouse=True)
def _once(impl):
    """static checks: run once (the autouse `impl` fixture parametrises every test)."""


def test_go_module_is_stdlib_only():
    """go.mod has no require/replace directives: the binary is built from the Go standard library only."""
    mod = (IMAGE_DIR / "go.mod").read_text()
    assert not re.search(r"(?m)^\s*(require|replace)\b", mod), mod
    assert not (IMAGE_DIR / "go.sum").exists()
    imports = set()
    for f in IMAGE_DIR.rglob("*.go"):
        for block in re.findall(r"(?s)^import \((.*?)\)|^import (\"[^\"]+\")", f.read_text(), re.M):
            for imp in re.findall(r'"([^"]+)"', " ".join(block)):
                imports.add(imp)
    third_party = sorted(i for i in imports if "." in i.split("/")[0] and not i.startswith("enterprise-hello/dsv-fetch/"))
    assert third_party == [], third_party


def test_python_implementation_retired():
    """Package 4.0.0 retired the 1.x Python dsv_fetch.py: nothing may embed or run it again."""
    assert not (IMAGE_DIR / "dsv_fetch.py").exists()
