"""Static check: dsv_fetch.py imports only the Python standard library (keeps the image tiny and lets the Datadog Agent's
embedded Python run it as secret_backend_command)."""

from __future__ import annotations

import ast
import sys

from conftest import SCRIPT


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
