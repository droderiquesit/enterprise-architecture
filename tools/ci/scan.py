"""Security scanners in parallel (open source), on the changed scope for PRs and everything on full runs.

    python3 -m tools.ci scan --out DIR [--selection sel.json] [--full] [--soft-fail]

  gitleaks   secrets: PR = commits of the PR range (git log base..head); full = working tree
  trivy      fs scan (vulnerable lock-file dependencies, Dockerfile/IaC misconfiguration, secrets): PR = the changed
             top-level component directories (more than MAX_TRIVY_TARGETS => the whole repository); full = repository
  checkov    Terraform static analysis: PR = changed Terraform directories; full = repository (.checkov.yaml when present)
  hadolint   Dockerfiles (error threshold): PR = changed Dockerfiles; full = all
  shellcheck shell scripts (errors): PR = changed *.sh; full = pipeline + deployment scripts
Each scanner is an independent background process (SARIF/JSON into DIR); exit codes are aggregated, a missing tool
is reported as skipped. SBOM (syft) and image CVE scans (trivy image / grype) run where the images are built
(container-image.yml), not here.
"""

from __future__ import annotations

import json
import posixpath
import shutil
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import List, Optional, Tuple

SKIP = ("node_modules", ".terraform", ".artifacts", ".ci-cache", ".git")
MAX_TRIVY_TARGETS = 20   # one trivy process per target; a wider change scans the repository once instead


def _changed(selection: Optional[dict]) -> Optional[List[str]]:
    if not selection or "changed_files" not in selection:
        return None
    return sorted({c["path"] for c in selection["changed_files"] if c.get("status") != "D"})


def plan(repo: Path, out: Path, selection: Optional[dict], full: bool, fail: bool) -> List[Tuple[str, Optional[List[str]]]]:
    changed = None if full else _changed(selection)
    ex = "1" if fail else "0"
    cmds: List[Tuple[str, Optional[List[str]]]] = []
    if shutil.which("gitleaks"):
        if changed is not None and selection.get("base"):
            cmds.append(("gitleaks", ["gitleaks", "git", ".", "--redact", "--no-banner", f"--log-opts={selection['base']}..HEAD",
                                      "--report-format", "sarif", "--report-path", str(out / "gitleaks.sarif")]))
        else:
            cmds.append(("gitleaks", ["gitleaks", "dir", ".", "--redact", "--no-banner", "--report-format", "sarif",
                                      "--report-path", str(out / "gitleaks.sarif")]))
    else:
        cmds.append(("gitleaks", None))
    if changed is None:
        targets = ["."]
    else:
        targets = sorted({"/".join(p.split("/")[:3]) if p.count("/") >= 2 else p for p in changed
                          if (repo / p).exists() and not any(s in p.split("/") for s in SKIP)})
        if len(targets) > MAX_TRIVY_TARGETS:
            targets = ["."]
    trivy_base = ["trivy", "fs", "--quiet", "--scanners", "vuln,misconfig,secret", "--severity", "HIGH,CRITICAL",
                  "--ignore-unfixed", "--skip-dirs", "**/node_modules", "--skip-dirs", "**/.terraform", "--exit-code", ex]
    if not shutil.which("trivy"):
        cmds.append(("trivy", None))
    elif targets:
        for i, t in enumerate(targets):
            cmds.append((f"trivy:{t}", trivy_base + ["--format", "sarif", "--output", str(out / f"trivy-{i}.sarif"), t]))
    tf_dirs = None if changed is None else sorted({posixpath.dirname(p) or "." for p in changed if p.endswith(".tf")})
    if not shutil.which("checkov"):
        cmds.append(("checkov", None))
    elif tf_dirs is None or tf_dirs:
        args = ["checkov", "--framework", "terraform", "--quiet", "--compact", "--output", "cli", "--output", "sarif",
                "--output-file-path", str(out / "checkov")]
        args += ["--directory", "."] if tf_dirs is None else [x for d in tf_dirs for x in ("--directory", d)]
        if (repo / ".checkov.yaml").exists():
            args += ["--config-file", ".checkov.yaml"]
        if not fail:
            args.append("--soft-fail")
        cmds.append(("checkov", args))
    dockerfiles = [p.relative_to(repo).as_posix() for p in repo.glob("**/Dockerfile")
                   if not any(s in p.parts for s in SKIP)] if changed is None else \
        [p for p in changed if posixpath.basename(p) == "Dockerfile"]
    if dockerfiles:
        cmds.append(("hadolint", ["hadolint", "--failure-threshold", "error", "--format", "sarif", *sorted(dockerfiles)]
                     if shutil.which("hadolint") else None))
    scripts = sorted(str(p.relative_to(repo)) for d in ("pipelines/scripts", "applications/deployments/scripts")
                     for p in (repo / d).glob("*.sh")) if changed is None else [p for p in changed if p.endswith(".sh")]
    if scripts:
        cmds.append(("shellcheck", ["shellcheck", "-S", "error", "-f", "json", *scripts] if shutil.which("shellcheck") else None))
    return cmds


def run(repo: Path, out: Path, selection: Optional[dict] = None, full: bool = False, fail: bool = True,
        jobs: int = 6, echo=print) -> int:
    out.mkdir(parents=True, exist_ok=True)

    def one(item):
        name, cmd = item
        if cmd is None:
            return {"scanner": name, "status": "skipped", "seconds": 0.0}
        t = time.monotonic()
        p = subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
        if name in ("hadolint", "shellcheck"):
            (out / f"{name}.{'sarif' if name == 'hadolint' else 'json'}").write_text(p.stdout)
        return {"scanner": name, "status": "passed" if p.returncode == 0 else "failed", "exit_code": p.returncode,
                "seconds": round(time.monotonic() - t, 1), "tail": (p.stderr or p.stdout)[-1500:] if p.returncode else ""}

    items = plan(repo, out, selection, full, fail)
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        results = list(pool.map(one, items))
    for r in results:
        echo(f"[{r['status'].upper():7}] {r['scanner']} ({r['seconds']}s)")
        if r["status"] == "failed":
            echo(r["tail"])
            echo(f"##vso[task.logissue type=error]security scanner {r['scanner']} reported findings / failed")
    (out / "scan-summary.json").write_text(json.dumps({"full": full, "results": results}, indent=2) + "\n")
    return 1 if any(r["status"] == "failed" for r in results) else 0
