#!/usr/bin/env python3
"""Destroy components whose retirement is scheduled in the selection document (Retire stage).

    python3 tools/deploy/retire.py --selection selection.json --env dev \
        --records-url <deployments store> --contracts-url <contracts store> [--dry-run]

For each `retire-scheduled` entry, in `order` (consumers before producers):
  1. check out the commit recorded in its deployment record into a temporary git worktree
     (the code may already be deleted from the branch),
  2. render config + materialize contracts there, `terraform init` against <env>/<id>.tfstate,
  3. `terraform plan -destroy -out` then `terraform apply` of that plan (components with a registry `secret_env`,
     e.g. Datadog provider keys, run Terraform through tools/secrets/fetch.py exec like tf-plan.sh / tf-apply.sh),
  4. delete its published contract envelopes and write status `retired`.
Never touches anything not explicitly scheduled; stops at the first failure (later producers keep
their consumers' guarantees).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.store import open_store  # noqa: E402

REPO = Path(__file__).resolve().parents[2]


def run(cmd, cwd=None, env=None) -> None:
    print("+ " + " ".join(cmd), flush=True)
    proc = subprocess.run(cmd, cwd=cwd, env=env)
    if proc.returncode != 0:
        raise SystemExit(f"ERROR: command failed ({proc.returncode}): {' '.join(cmd)}")


def scheduled(selection: dict) -> list[dict]:
    items = [r for r in selection.get("retirements", []) if r.get("status") == "retire-scheduled"]
    return sorted(items, key=lambda r: r["order"])


def _secret_wrapper(wt: Path, env: str, cid: str) -> list[str]:
    """fetch.py exec prefix when the component (registry at the recorded commit) declares secret_env, else []."""
    from tools.changeset.registry import load_registry
    from tools.changeset.trees import WorkTree

    if not load_registry(WorkTree(wt)).get(cid).secret_env:
        return []
    return [sys.executable, str(REPO / "tools/secrets/fetch.py"), "exec", "--env", env, "--component", cid,
            "--repo", str(wt), "--"]


def retire_one(entry: dict, env: str, records, contracts_url: str, terraform: str, dry_run: bool) -> None:
    cid = entry["component"]
    rec = records.get_json(f"{env}/{cid}.json") or {}
    commit = rec.get("commit") or entry.get("record_commit")
    path = rec.get("path") or entry.get("path")
    if not commit or not path:
        raise SystemExit(f"ERROR: record of {cid} lacks commit/path; cannot retire safely")
    print(f"== retiring {cid} (path {path} at {commit[:12]})")
    if dry_run:
        print("dry run: nothing destroyed")
        return
    with tempfile.TemporaryDirectory() as td:
        wt = Path(td) / "wt"
        run(["git", "-C", str(REPO), "worktree", "add", "--detach", str(wt), commit])
        try:
            py = sys.executable
            run([py, str(REPO / "tools/config/render.py"), "--repo", str(wt), "--env", env, "--component", cid])
            run([py, str(REPO / "tools/contracts/materialize.py"), "--repo", str(wt), "--env", env,
                 "--component", cid, "--source", contracts_url])
            root = wt / path
            run(["bash", str(REPO / "pipelines/scripts/tf-init.sh"), cid, str(root)], cwd=str(wt))
            wrap = _secret_wrapper(wt, env, cid)
            run([*wrap, terraform, f"-chdir={root}", "plan", "-destroy", "-input=false", "-lock-timeout=10m",
                 "-out=destroy.tfplan"])
            run([*wrap, terraform, f"-chdir={root}", "apply", "-input=false", "-lock-timeout=10m", "destroy.tfplan"])
        finally:
            subprocess.run(["git", "-C", str(REPO), "worktree", "remove", "--force", str(wt)])
    contracts = open_store(contracts_url)
    for contract in rec.get("produces", []):
        for key in contracts.list(f"{env}/{contract}/"):
            contracts.delete(key)
    rec.update({"status": "retired", "run_id": os.environ.get("BUILD_BUILDID", "local"),
                "note": f"retired; approval: {json.dumps(entry.get('approval'))}"})
    records.put_json(f"{env}/{cid}.json", rec)
    print(f"retired {cid}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--selection", required=True)
    ap.add_argument("--env", required=True)
    ap.add_argument("--records-url", required=True)
    ap.add_argument("--contracts-url", required=True)
    ap.add_argument("--terraform", default="terraform")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    selection = json.loads(Path(args.selection).read_text())
    records = open_store(args.records_url)
    items = scheduled(selection)
    if not items:
        print("no scheduled retirements")
        return 0
    for entry in items:
        retire_one(entry, args.env, records, args.contracts_url, args.terraform, args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
