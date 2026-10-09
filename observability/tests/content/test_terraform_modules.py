"""Runs `terraform fmt -check`, `init -backend=false`, `validate` and `terraform test` (mock providers) for every
package module and lab root owned by the content builder. Skipped when terraform is not installed."""
import shutil
import subprocess
from pathlib import Path

import pytest

PKG = Path(__file__).resolve().parents[2]
ROOTS = [PKG / "modules" / m for m in ("rum", "service-catalog", "monitors", "dashboards", "slos", "synthetics",
                                       "deployment-markers", "notification-routing", "onboarding")]
ROOTS += [PKG / "lab" / "prereqs", PKG / "lab" / "monitoring"]

pytestmark = pytest.mark.skipif(shutil.which("terraform") is None, reason="terraform not installed")


def tf(root, *args):
    return subprocess.run(["terraform", *args], cwd=root, capture_output=True, text=True, timeout=600)


@pytest.mark.parametrize("root", ROOTS, ids=lambda p: str(p.relative_to(PKG)))
def test_terraform_root(root):
    r = tf(root, "fmt", "-check", "-recursive")
    assert r.returncode == 0, r.stdout + r.stderr
    r = tf(root, "init", "-backend=false", "-input=false", "-no-color")
    assert r.returncode == 0, r.stdout + r.stderr
    r = tf(root, "validate", "-no-color")
    assert r.returncode == 0, r.stdout + r.stderr
    if (root / "tests").exists():
        r = tf(root, "test", "-no-color")
        assert r.returncode == 0, r.stdout + r.stderr
    assert (root / ".terraform.lock.hcl").exists() or not list(root.glob("*.tf")) or root.name == "deployment-markers"
