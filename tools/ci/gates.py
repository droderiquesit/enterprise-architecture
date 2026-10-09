"""Cheap gates (~1 min): static checks that run first, in parallel threads, with aggregated exit codes.

Registry graph, generated stages up to date, pipeline lint + template limits, ownership, provider pins, CODEOWNERS,
catalog, the CI suite catalog itself, repository-wide `terraform fmt -check`, ruff (syntax errors / undefined
names, open-source, fast), shellcheck (errors) on pipeline scripts. Tools that are not installed are reported
as skipped (local runs); the pipeline installs them (pipelines/scripts/install-tools.sh).
"""

from __future__ import annotations

import glob
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import List, Optional, Tuple

PY = sys.executable or "python3"


def checks(repo: Path, env: str = "dev") -> List[Tuple[str, Optional[List[str]]]]:
    shell = sorted(glob.glob(str(repo / "pipelines/scripts/*.sh")) + glob.glob(str(repo / "applications/deployments/scripts/*.sh"))
                   + [str(repo / "tools/validate/terraform.sh")])
    return [
        ("registry-graph", [PY, "-m", "tools.changeset", "graph"]),
        ("environment", [PY, "tools/config/resolve.py", "--env", env]),
        ("generated-stages", [PY, "tools/pipeline/generate.py", "--check"]),
        ("pipeline-lint", [PY, "tools/validate/pipeline_lint.py"]),
        ("pipeline-templates", [PY, "tools/validate/pipeline_templates.py"]),
        ("ownership", [PY, "tools/validate/ownership.py"]),
        ("provider-pins", [PY, "tools/validate/versions.py"]),
        ("codeowners", [PY, "tools/ado/codeowners.py", "--check"]),
        ("catalog", [PY, "tools/catalog/validate.py"]),
        ("ci-suites", [PY, "-m", "tools.ci", "check"]),
        ("terraform-fmt", ["terraform", "fmt", "-check", "-recursive", "-no-color", "."] if shutil.which("terraform") else None),
        ("ruff", ["ruff", "check", "--isolated", "--select", "E9,F63,F7,F82", "--output-format", "concise",
                  "tools", "tests", "applications", "observability"] if shutil.which("ruff") else None),
        ("shellcheck", ["shellcheck", "-S", "error", *shell] if shutil.which("shellcheck") else None),
    ]


def run(repo: Path, env: str = "dev", jobs: int = 8, echo=print) -> int:
    def one(item):
        name, cmd = item
        if cmd is None:
            return name, "skipped", 0.0, "tool not installed"
        t = time.monotonic()
        p = subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
        return name, "passed" if p.returncode == 0 else "failed", time.monotonic() - t, (p.stdout + p.stderr)[-3000:]

    failed = 0
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        for name, status, secs, out in pool.map(one, checks(repo, env)):
            echo(f"[{status.upper():7}] gate {name} ({secs:.1f}s)")
            if status == "failed":
                failed += 1
                echo(out)
                echo(f"##vso[task.logissue type=error]gate {name} failed")
    return 1 if failed else 0
