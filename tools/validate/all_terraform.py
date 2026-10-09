#!/usr/bin/env python3
"""Run tools/validate/terraform.sh for every Terraform component in the registry and every shared
module directory (<layer>/modules/<name>, observability/modules/<name>), in parallel with bounded workers.

    python3 tools/validate/all_terraform.py [--workers 4] [--only foundation-network,...] [--strict] [--clean]

Roots listed in the registry but not yet present on disk are reported as MISSING (a failure only with
--strict). Exit code 1 when any check fails. Note: Terraform does not guarantee concurrency safety of a
shared plugin cache; keep --workers modest (default 4) when TF_PLUGIN_CACHE_DIR is set.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402

SCRIPT = Path(__file__).with_name("terraform.sh")


def module_dirs(repo: Path) -> list[str]:
    out = set()
    for tf in repo.glob("**/modules/*/*.tf"):
        rel = tf.parent.relative_to(repo).as_posix()
        if "/.terraform/" in f"/{rel}/" or "/tests/" in f"/{rel}/":
            continue
        out.add(rel)
    return sorted(out)


def targets(repo: Path, only: set[str] | None) -> list[tuple[str, str]]:
    reg = load_registry(WorkTree(repo))
    items = [(c.id, c.path) for c in reg if c.is_terraform and (not only or c.id in only)]
    if not only:
        items += [(f"module:{d}", d) for d in module_dirs(repo)]
    return items


def run_one(repo: Path, name: str, path: str, clean: bool) -> dict:
    d = repo / path
    if not d.is_dir() or not any(d.glob("*.tf")):
        return {"name": name, "path": path, "status": "MISSING", "seconds": 0.0, "output": "no .tf files"}
    start = time.monotonic()
    cmd = ["bash", str(SCRIPT), path] + (["--clean"] if clean else [])
    proc = subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
    status = "OK" if proc.returncode == 0 else "FAIL"
    return {"name": name, "path": path, "status": status, "seconds": time.monotonic() - start,
            "output": (proc.stdout + proc.stderr)[-4000:]}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--only", help="comma separated component ids")
    ap.add_argument("--strict", action="store_true", help="MISSING roots fail")
    ap.add_argument("--clean", action="store_true", help="remove .terraform after each check")
    args = ap.parse_args(argv)
    repo = Path(args.repo).resolve()
    only = {x for x in (args.only or "").split(",") if x} or None
    items = targets(repo, only)
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        results = list(pool.map(lambda t: run_one(repo, t[0], t[1], args.clean), items))
    width = max((len(r["name"]) for r in results), default=10)
    print(f"{'target'.ljust(width)}  status   seconds  path")
    for r in sorted(results, key=lambda r: (r["status"] != "FAIL", r["name"])):
        print(f"{r['name'].ljust(width)}  {r['status'].ljust(7)}  {r['seconds']:7.1f}  {r['path']}")
    failed = [r for r in results if r["status"] == "FAIL" or (args.strict and r["status"] == "MISSING")]
    for r in failed:
        print(f"\n---- {r['name']} ({r['status']}) ----\n{r['output']}")
    counts = {s: sum(1 for r in results if r["status"] == s) for s in ("OK", "FAIL", "MISSING")}
    print(f"\nsummary: {counts['OK']} ok, {counts['FAIL']} failed, {counts['MISSING']} missing")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
