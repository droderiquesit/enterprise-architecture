"""Change detection for the universal Azure DevOps pipeline.

Usage (from the repository root)::

    python3 -m tools.changeset graph --check
    python3 -m tools.changeset select --mode auto --env dev --ado

The package only depends on the Python standard library, PyYAML and jsonschema.
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def ensure_repo_on_path() -> None:
    """Allow `python3 tools/<x>/<script>.py` invocations to import `tools.*`."""
    root = str(REPO_ROOT)
    if root not in sys.path:
        sys.path.insert(0, root)
