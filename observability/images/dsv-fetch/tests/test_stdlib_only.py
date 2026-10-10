"""Static check: dsv_fetch.py imports only the Python standard library (keeps the image tiny and lets the Datadog Agent's
embedded Python run it as secret_backend_command)."""

from __future__ import annotations

import ast
import re
import sys

import pytest
from conftest import IMAGE_DIR, IMPL, SCRIPT


@pytest.fixture(autouse=True)
def _only_matching_impl(impl, request):
    want = "go" if "go_" in request.node.name else "python"
    if impl.name != want:
        pytest.skip(f"static check of the {want} implementation")


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
    third_party = sorted(i for i in imports if "." in i.split("/")[0] and not i.startswith("github.com/lab/enterprise-architecture/observability/images/dsv-fetch/"))
    assert third_party == [], third_party


def _imports(tree: ast.AST) -> set[str]:
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(a.name.split(".")[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                raise AssertionError("relative imports are not allowed in a single-file tool")
            names.add((node.module or "").split(".")[0])
        elif isinstance(node, ast.Call) and getattr(node.func, "id", None) in ("__import__", "import_module"):
            raise AssertionError("dynamic imports are not allowed")
    return names


def test_imports_are_stdlib_only():
    tree = ast.parse(SCRIPT.read_text(), filename=str(SCRIPT))
    imported = _imports(tree)
    assert imported, "no imports found?"
    non_stdlib = sorted(m for m in imported if m not in sys.stdlib_module_names and m != "__future__")
    assert non_stdlib == [], f"non-stdlib imports: {non_stdlib}"


def test_no_print_of_values_to_stdout_outside_agent_backend():
    """Only cmd_agent_backend writes to stdout (the Agent protocol); every other print goes to stderr."""
    tree = ast.parse(SCRIPT.read_text())
    for fn in [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)]:
        for call in [c for c in ast.walk(fn) if isinstance(c, ast.Call) and getattr(c.func, "id", None) == "print"]:
            to_stderr = any(k.arg == "file" for k in call.keywords)
            assert to_stderr or fn.name == "main", f"print to stdout in {fn.name}"
