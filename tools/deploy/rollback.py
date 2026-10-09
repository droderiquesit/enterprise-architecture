#!/usr/bin/env python3
"""Automatic rollback of an APPLICATION deployment root whose code deploy or smoke test failed.

    python3 tools/deploy/rollback.py plan --env dev --component deploy-core-aca --root applications/deployments/core-aca
    python3 tools/deploy/rollback.py run  --env dev --component deploy-core-aca --root applications/deployments/core-aca \
        [--progress <deploy-zip progress file>] [--out rollback.json]

Driven by data, not by guesses:
  * the NEW contract (terraform output of the root that was just applied) names the hosting resources;
  * the PREVIOUS contract envelope is still the one in the contracts store (tf-apply.sh publishes a contract only
    after code deploy + smoke succeeded), and the deployment record's `last_succeeded.artifacts` holds the
    previous image digests / package URLs + sha256;
  * contract `rollback.method` and `deploy_steps[].kind` select the action:
      traffic-shift (ACA)            az containerapp revision activate + ingress traffic set <app>--<prev suffix>=100
      slot-swap / webapp-zip slot    az webapp deployment slot swap back (only when deploy-zip reported the swap)
      redeploy-previous-*            deploy-zip.sh / deploy-swa.sh with the PREVIOUS envelope (previous package, sha256)
      functionapp-flex / logicapp    same: previous package through deploy-zip.sh (Flex has no slots)
      redeploy-previous-digest (AKS) helm rollback <release> 0 -n <ns> --wait through `az aks command invoke`
      reinstall-previous (VM/VMSS)   contract `rollback.commands` [{kind: vm-run-command, resource_group, vm, script}]
                                     (installer re-activates the previous release); without it: operator runbook
  * afterwards smoke.sh runs against the previous contract; the record becomes `rolled_back` (never `succeeded`:
    Terraform state still describes the new release) so neither deploy nor heal retries the same fingerprint;
    a new commit or a manual run does. The apply stage always ends failed.
Infrastructure roots are never rolled back automatically (a Terraform "rollback" is a new reviewed change).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, List, Optional, Sequence

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

SCRIPTS = "applications/deployments/scripts"
# kinds whose previous package can be re-deployed from the previous envelope alone. vmss-update-instances /
# vmss-flex-rollout apply the CURRENT Terraform model / rollout script, so they cannot restore the previous package:
# those roots declare `rollback.commands` (below) or need a reviewed re-apply of the previous commit.
REDEPLOY_KINDS = {"functionapp-flex", "logicapp-zip", "swa", "webapp-zip"}


def _data(doc: Optional[dict]) -> dict:
    if not isinstance(doc, dict):
        return {}
    if "data" in doc and isinstance(doc["data"], dict):
        return doc["data"]
    if "value" in doc and "sensitive" in doc:
        return doc["value"] or {}
    return doc


def read_progress(path: Optional[str]) -> List[str]:
    if not path or not Path(path).exists():
        return []
    return [line.strip() for line in Path(path).read_text().splitlines() if line.strip()]


def plan_actions(new: dict, previous: Optional[dict], progress: Sequence[str] = ()) -> List[dict]:
    """Rollback actions for one root. `progress` lines come from deploy-zip.sh ("swapped <app>", "deployed <app>")."""
    new, prev = _data(new), _data(previous)
    if not prev:
        return [{"kind": "none", "reason": "no previous successful contract: nothing to roll back to (first deployment)"}]
    method = ((new.get("rollback") or {}).get("method") or "").lower()
    actions: List[dict] = []
    swapped = {p.split(" ", 1)[1] for p in progress if p.startswith("swapped ")}
    deployed = {p.split(" ", 1)[1] for p in progress if p.startswith("deployed ")}
    # ---- Container Apps: traffic back to the previous revision
    if method == "traffic-shift" or new.get("architecture", "").startswith("container-apps"):
        rg = new.get("resource_group_name")
        for key, app in sorted((new.get("apps") or {}).items()):
            before = (prev.get("apps") or {}).get(key) or {}
            suffix, name = before.get("revision_suffix"), app.get("name")
            if not (suffix and name and rg) or suffix == app.get("revision_suffix"):
                continue
            revision = f"{name}--{suffix}"
            actions.append({"kind": "aca-activate", "app": key, "idempotent": True,
                            "cmd": ["az", "containerapp", "revision", "activate", "-g", rg, "-n", name,
                                    "--revision", revision, "--only-show-errors"]})
            actions.append({"kind": "aca-traffic", "app": key, "idempotent": True,
                            "cmd": ["az", "containerapp", "ingress", "traffic", "set", "-g", rg, "-n", name,
                                    "--revision-weight", f"{revision}=100", "--only-show-errors"]})
    # ---- AKS (Helm): previous release revision
    helm = new.get("helm") or {}
    if method == "redeploy-previous-digest" and helm.get("releases") and new.get("cluster_id"):
        cluster = new["cluster_id"].rstrip("/").split("/")
        rg, name = cluster[cluster.index("resourceGroups") + 1], cluster[-1]
        for key, rel in sorted(helm["releases"].items()):
            before = ((prev.get("apps") or {}).get(key) or {}).get("image")
            now = ((new.get("apps") or {}).get(key) or {}).get("image")
            if before and before == now:
                continue
            actions.append({"kind": "helm-rollback", "app": key, "idempotent": False,
                            "cmd": ["az", "aks", "command", "invoke", "-g", rg, "-n", name, "--command",
                                    f"helm rollback {rel['name']} 0 -n {rel['namespace']} --wait --timeout 10m"]})
    # ---- code deploy steps (App Service, Functions Flex, Logic Apps, SWA, VM/VMSS)
    prev_steps = {s.get("app"): s for s in prev.get("deploy_steps") or []}
    for step in new.get("deploy_steps") or []:
        app, kind = step.get("app"), step.get("kind")
        before = prev_steps.get(app)
        if kind == "webapp-zip" and step.get("slot"):
            if app in swapped:
                actions.append({"kind": "slot-swap-back", "app": app, "idempotent": False,
                                "cmd": ["az", "webapp", "deployment", "slot", "swap", "-g", step["resource_group"],
                                        "-n", step["name"], "--slot", step["slot"], "--target-slot", "production",
                                        "--only-show-errors"]})
            continue  # not swapped: production still runs the previous build
        if kind not in REDEPLOY_KINDS or not before:
            continue
        if before.get("package_sha256") and before.get("package_sha256") == step.get("package_sha256"):
            continue
        if progress and app not in deployed and app not in swapped:
            continue  # deploy-zip never reached this app
        actions.append({"kind": "redeploy-previous", "app": app, "step": kind, "idempotent": True,
                        "cmd": ["bash", f"{SCRIPTS}/deploy-zip.sh", "--contract", "{previous}", "--only", app]})
    # ---- generic: commands the root declares for itself (e.g. VM installers that keep previous releases)
    for i, c in enumerate((new.get("rollback") or {}).get("commands") or []):
        if c.get("kind") == "vm-run-command" and c.get("resource_group") and c.get("vm") and c.get("script"):
            actions.append({"kind": "vm-run-command", "app": c.get("app") or c["vm"], "idempotent": True,
                            "cmd": ["az", "vm", "run-command", "invoke", "-g", c["resource_group"], "-n", c["vm"],
                                    "--command-id", "RunShellScript", "--scripts", c["script"], "--only-show-errors"]})
    if not actions:
        actions.append({"kind": "none", "reason": f"rollback method '{method or 'unknown'}': nothing differs from the "
                                                  "previous release or no automatic action exists (see contract.rollback.how)"})
    return actions


Runner = Callable[[Sequence[str]], int]


def _run(cmd: Sequence[str]) -> int:
    return subprocess.run(list(cmd)).returncode


def execute(actions: List[dict], previous_file: str, runner: Runner = _run, retry: bool = True) -> List[dict]:
    from tools.deploy.retry import run_with_retry

    results = []
    for a in actions:
        if a["kind"] == "none":
            results.append(dict(a, result="skipped"))
            continue
        cmd = [previous_file if c == "{previous}" else c for c in a["cmd"]]
        if retry and a.get("idempotent"):
            code, _out, _ev = run_with_retry(cmd, label=f"rollback {a['kind']} {a.get('app')}",
                                             runner=lambda c: (runner(c), ""))
        else:
            code = runner(cmd)  # swaps / helm rollback are not repeated blindly
        results.append({k: v for k, v in a.items() if k != "cmd"} | {"result": "ok" if code == 0 else f"failed({code})"})
    return results


def previous_envelope(env: str, component: str) -> Optional[dict]:
    from tools.changeset.registry import load_registry
    from tools.changeset.store import open_store
    from tools.changeset.trees import WorkTree
    from tools.contracts.lib import envelope_key, expected_major

    store = open_store(os.environ.get("CONTRACTS_URL"))
    if store is None:
        return None
    tree = WorkTree(REPO)
    comp = load_registry(tree).get(component)
    for contract in comp.produces:
        doc = store.get_json(envelope_key(env, contract, expected_major(tree, contract)))
        if doc:
            return doc
    return None


def terraform_contract(root: str) -> dict:
    p = subprocess.run(["terraform", f"-chdir={root}", "output", "-json", "contract"], capture_output=True, text=True)
    return json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip() else {}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=("plan", "run"))
    ap.add_argument("--env", required=True)
    ap.add_argument("--component", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--new-contract", help="contract JSON (default: terraform output of --root)")
    ap.add_argument("--previous-contract", help="previous envelope JSON (default: contracts store)")
    ap.add_argument("--progress", default=os.environ.get("DEPLOY_PROGRESS_FILE"))
    ap.add_argument("--out")
    args = ap.parse_args(argv)
    if not args.root.startswith("applications/deployments/"):
        print(f"##vso[task.logissue type=warning]{args.component}: infrastructure is never rolled back automatically")
        return 0
    new = json.loads(Path(args.new_contract).read_text()) if args.new_contract else terraform_contract(args.root)
    prev = json.loads(Path(args.previous_contract).read_text()) if args.previous_contract else previous_envelope(args.env, args.component)
    actions = plan_actions(new, prev, read_progress(args.progress))
    if args.op == "plan":
        print(json.dumps([{k: v for k, v in a.items()} for a in actions], indent=2))
        return 0
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(prev or {}, f)
        prev_file = f.name
    results = execute(actions, prev_file)
    smoke = 0
    if prev and any(r["result"] == "ok" for r in results):
        smoke = _run(["bash", f"{SCRIPTS}/smoke.sh", "--contract", prev_file,
                      "--attempts", os.environ.get("SMOKE_ATTEMPTS", "18"), "--interval", os.environ.get("SMOKE_INTERVAL", "10")])
    ok = all(r["result"] in ("ok", "skipped") for r in results) and smoke == 0
    summary = {"component": args.component, "env": args.env, "actions": results,
               "smoke": "passed" if smoke == 0 else "failed", "result": "rolled_back" if ok else "rollback_failed"}
    from tools.deploy.retry import log_event

    log_event({"component": args.component, "label": "rollback", "result": summary["result"],
               "actions": [f"{r['kind']}:{r.get('app')}={r['result']}" for r in results]})
    if args.out:
        Path(args.out).write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    level = "warning" if ok else "error"
    print(f"##vso[task.logissue type={level}]{args.component}: automatic rollback {summary['result']}")
    os.unlink(prev_file)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
