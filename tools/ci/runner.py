"""Parallel execution of planned units (one CI leg, or everything locally) with CPU-token scheduling.

Every unit takes CPU tokens from a pool of `jobs` (default: CPU count): a pytest unit runs with pytest-xdist
`-n <tokens> --dist loadfile` and holds that many tokens (integration / e2e suites are I/O bound: one token, one
worker per file); Terraform roots / modules / scripts hold one token each
(Terraform itself is mostly single-threaded per root). Units start longest-first (LPT) to shorten the makespan.
Passes are written to the test result cache; per-file pytest durations (JUnit XML) feed the next balancing.
"""

from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Dict, List, Optional

from .balance import Unit
from .cache import ResultCache

PY = sys.executable or "python3"
DOTNET_DIR = "applications/dotnet"   # global.json: SDK pin + Microsoft.Testing.Platform runner


def have_xdist() -> bool:
    return importlib.util.find_spec("xdist") is not None


class Tokens:
    def __init__(self, n: int):
        self.free = n
        self.total = n
        self.cv = threading.Condition()

    def acquire(self, k: int) -> int:
        k = max(1, min(k, self.total))
        with self.cv:
            while self.free < k:
                self.cv.wait()
            self.free -= k
        return k

    def release(self, k: int) -> None:
        with self.cv:
            self.free += k
            self.cv.notify_all()


def command(unit: Unit, suite, repo: Path, env_name: str, workers: int, junit: Path) -> List[str]:
    if suite.kind == "pytest":
        cmd = [PY, "-m", "pytest", "-q", "-p", "no:cacheprovider", f"--junitxml={junit}", "-o", "junit_family=xunit1"]
        if workers > 1 and have_xdist():
            cmd += ["-n", str(workers), "--dist", "loadfile"]
        return cmd + list(unit.files or suite.paths)
    if suite.kind == "component":
        return [PY, "tools/validate/component.py", "--component", suite.component, "--env", env_name]
    if suite.kind == "module":
        return ["bash", "tools/validate/terraform.sh", suite.id.split(":", 1)[1]]
    if suite.kind == "dotnet":
        # Microsoft.Testing.Platform (applications/dotnet/global.json; run from that directory): test modules in
        # parallel (--max-parallel-test-modules)
        # (an MSBuild -maxcpucount switch is passed on to the MTP test host and makes it run zero tests; the dotnet
        # CLI builds with parallel nodes by default anyway)
        cmd = ["dotnet", "test", "-c", "Release", "--max-parallel-test-modules", str(max(1, workers))]
        for p in suite.projects:
            cmd += ["--project", os.path.relpath(repo / p, repo / DOTNET_DIR)]
        return cmd
    argv = list(suite.argv)
    return [PY if argv[0] in ("python", "python3") else argv[0], *argv[1:]]


def junit_file_times(junit: Path, files: List[str]) -> Dict[str, float]:
    """Sum testcase times per test file (xunit1 `file` attribute, else classname -> module path)."""
    if not junit.exists():
        return {}
    try:
        root = ET.parse(junit).getroot()
    except ET.ParseError:
        return {}
    by_mod = {f[:-3].replace("/", "."): f for f in files}
    out: Dict[str, float] = {}
    for tc in root.iter("testcase"):
        f = tc.get("file")
        if not f:
            cls = tc.get("classname") or ""
            f = next((v for k, v in by_mod.items() if cls == k or cls.startswith(k + ".")), None)
        if f:
            out[f] = out.get(f, 0.0) + float(tc.get("time") or 0)
    return {k: round(v, 2) for k, v in sorted(out.items())}


def _safe(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", name)[:120]


def run_units(units: List[Unit], suites: dict, repo: Path, *, jobs: int, out_dir: Path, env_name: str = "dev",
              cache: Optional[ResultCache] = None, fingerprints: Optional[Dict[str, str]] = None,
              enable_env_suites: bool = False, echo=print) -> List[dict]:
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "logs").mkdir(exist_ok=True)
    tokens = Tokens(max(1, jobs))
    results: List[dict] = []
    lock = threading.Lock()
    fingerprints = fingerprints or {}

    def one(u: Unit) -> dict:
        s = suites[u.suite]
        if s.needs_env and not enable_env_suites and not all(os.environ.get(k) == v for k, v in s.needs_env.items()):
            return {"unit": u.name, "suite": u.suite, "status": "skipped",
                    "reason": f"needs {' '.join(f'{k}={v}' for k, v in s.needs_env.items())}", "seconds": 0.0}
        workers = None
        if s.kind == "pytest" and s.tier in ("integration", "e2e"):
            # I/O bound (containers, polling): one CPU token, but still one xdist worker per file
            want, workers = 1, min(tokens.total, len(u.files or _files_of(repo, s)) or 1)
        elif s.kind == "pytest":
            want = len(u.files or _files_of(repo, s)) or 1     # loadfile: more workers than files is idle CPU
        elif s.kind == "dotnet" or (s.kind == "component" and s.toolchain == "dotnet"):
            want = tokens.total
        elif s.kind == "component" and s.toolchain in ("python", "node"):
            want = 2
        else:
            want = 1
        got = tokens.acquire(want)
        log = out_dir / "logs" / f"{_safe(u.name)}.log"
        junit = out_dir / "logs" / f"{_safe(u.name)}.junit.xml"
        env = dict(os.environ, **({k: v for k, v in s.needs_env.items()} if enable_env_suites else {}))
        env.setdefault("PYTHONDONTWRITEBYTECODE", "1")
        env["CI_CPUS"] = str(got)            # tools/validate/component.py sizes xdist / dotnet parallelism by it
        cmd = command(u, s, repo, env_name, workers or got, junit)
        start = time.monotonic()
        try:
            with log.open("w") as fh:
                fh.write("+ " + " ".join(cmd) + "\n")
                fh.flush()
                try:
                    rc = subprocess.run(cmd, cwd=repo / DOTNET_DIR if s.kind == "dotnet" else repo, stdout=fh, stderr=subprocess.STDOUT, env=env,
                                        timeout=s.timeout_minutes * 60).returncode
                except subprocess.TimeoutExpired:
                    fh.write(f"\nTIMEOUT after {s.timeout_minutes} min\n")
                    rc = 124
                except FileNotFoundError as exc:
                    fh.write(f"\n{exc}\n")
                    rc = 127
        finally:
            tokens.release(got)
        secs = round(time.monotonic() - start, 2)
        res = {"unit": u.name, "suite": u.suite, "shard": u.shard, "status": "passed" if rc == 0 else "failed",
               "exit_code": rc, "seconds": secs, "estimate": u.seconds, "workers": got, "log": str(log.relative_to(out_dir)),
               "toolchain": u.toolchain, "tier": u.tier}
        if s.kind == "pytest":
            res["file_seconds"] = junit_file_times(junit, u.files or _files_of(repo, s))
        if rc == 0 and cache is not None and s.cache:
            cache.record(u.suite, fingerprints.get(u.suite, ""), secs, u.files if u.shard else None)
        with lock:
            echo(f"[{res['status'].upper():6}] {u.name} {secs:.1f}s" + ("" if rc == 0 else f" (exit {rc}; {res['log']})"))
        return res

    ordered = sorted(units, key=lambda u: (-u.seconds, u.name))
    with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        for r in pool.map(one, ordered):
            results.append(r)
    return sorted(results, key=lambda r: r["unit"])


def _files_of(repo: Path, suite) -> List[str]:
    from .catalog import pytest_files

    return pytest_files(repo, suite)
