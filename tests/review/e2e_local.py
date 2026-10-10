#!/usr/bin/env python3
"""Local end-to-end run of the automated PR review (no Azure, no Azure DevOps).

    python3 tests/review/e2e_local.py [--out docs/evidence/local/pr-review]

1. clones this repository (git clone --local) into a temp dir; the clone's main = current HEAD + the working-tree copy
   of the trusted review inputs (.review/policy.yaml, catalog/), so the trusted side is what is in this checkout;
2. creates two real branches with sample changes: `docs-only` (a guide edit) and `rbac` (a role assignment in
   foundation/identity);
3. starts the fake Azure DevOps server (tests/review/fake_ado.py) backed by the clone, opens one PR per branch and
   runs the reviewer in-process exactly as the Function's queue worker does (tools.review.service.process);
4. writes evidence JSON (decision, vote, status, threads, calls) to --out. Status vocabulary: locally-verified.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path[:0] = [str(ROOT), str(HERE)]

from fake_ado import BOT_ID, ORG, PROJECT, PROJECT_ID, REPO_ID, FakeAdo

from tools.review.ado import AdoClient
from tools.review.service import process

ENV = ["-c", "user.name=e2e", "-c", "user.email=e2e@example.com"]
TRUSTED = [
    ".review/policy.yaml",
    "catalog/components.yaml",
    "catalog/schemas/component.schema.json",
    "tools/review/policy.schema.json",
    "observability/schemas/onboarding-manifest.v1.schema.json",
]


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", *ENV, "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "docs/evidence/local/pr-review"))
    a = ap.parse_args(argv)
    tmp = Path(tempfile.mkdtemp(prefix="eh-pr-review-e2e-"))
    clone = tmp / "repo"
    subprocess.run(["git", "clone", "-q", "--local", "--no-hardlinks", str(ROOT), str(clone)], check=True)
    git(clone, "checkout", "-q", "-B", "main")
    for rel in TRUSTED:
        (clone / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / rel, clone / rel)
    git(clone, "add", "-A")
    git(clone, "commit", "-q", "--allow-empty", "-m", "trusted review inputs from the working tree")

    git(clone, "checkout", "-q", "-b", "docs-only", "main")
    guide = clone / "docs/guides/quick-start.md"
    guide.write_text(guide.read_text() + "\n> Tip: run `python3 -m tools.review --base origin/main --head HEAD` before opening a PR.\n")
    git(clone, "commit", "-q", "-am", "docs: quick-start tip")

    git(clone, "checkout", "-q", "-b", "rbac", "main")
    tf = clone / "foundation/identity/main.tf"
    tf.write_text(
        tf.read_text() + '\nresource "azurerm_role_assignment" "e2e_reader" {\n  scope                = azurerm_resource_group.this.id\n'
        '  role_definition_name = "Reader"\n  principal_id         = "00000000-0000-0000-0000-000000000001"\n}\n'
    )
    git(clone, "commit", "-q", "-am", "identity: extra role assignment")

    ado = FakeAdo(clone).start()
    results = []
    try:
        client = AdoClient(ado.url, ORG, PROJECT, lambda: "local-e2e-token", max_attempts=1)
        for pr_id, branch, expect in ((101, "docs-only", "approve"), (102, "rbac", "human-required")):
            ado.add_pr(pr_id, "main", branch)
            # GitHub Copilot code review (simulated thread): resolved comment on the docs PR, open one on the RBAC PR
            ado.add_copilot_thread(
                pr_id,
                "docs/guides/quick-start.md" if branch == "docs-only" else "foundation/identity/main.tf",
                status="fixed" if branch == "docs-only" else "active",
            )
            out = process(client, PROJECT_ID, REPO_ID, pr_id, BOT_ID, keep_result=True)
            pr = ado.prs[pr_id]
            res = out.result
            results.append(
                {
                    "pull_request": pr_id,
                    "branch": branch,
                    "expected": expect,
                    "decision": out.decision,
                    "vote": out.vote,
                    "status": out.status,
                    "human_required": res["decision"]["human_required"],
                    "auto_approvable": res["decision"]["auto_approvable"],
                    "reasons": res["decision"]["reasons"],
                    "classes": res["classes"],
                    "components": [c["id"] for c in res["components"]],
                    "consumers_affected": len(res["consumers"]),
                    "copilot": {k: res["copilot"].get(k) for k in ("threads", "active_threads", "reviewed_current", "stale")},
                    "findings": [{k: f[k] for k in ("rule", "severity", "kind", "file", "line", "message")} for f in res["findings"]],
                    "ado_state": {
                        "bot_vote": ado.bot_vote(pr_id),
                        "status": ado.latest_status(pr_id),
                        "threads": [
                            {
                                "status": t["status"],
                                "file": (t.get("threadContext") or {}).get("filePath"),
                                "first_line": t["comments"][0]["content"].splitlines()[0],
                            }
                            for t in pr["threads"]
                        ],
                    },
                    "actions": list(out.actions),
                }
            )
            # second run: idempotent
            again = process(client, PROJECT_ID, REPO_ID, pr_id, BOT_ID)
            results[-1]["rerun_actions"] = list(again.actions)
        calls = list(ado.calls)
    finally:
        ado.stop()
        shutil.rmtree(tmp, ignore_errors=True)

    ok = (
        results[0]["decision"] == "approve"
        and results[0]["vote"] == 10
        and results[0]["status"] == "succeeded"
        and results[1]["human_required"]
        and results[1]["vote"] == 0
        and results[1]["status"] == "pending"
        and not results[0]["rerun_actions"]
        and not results[1]["rerun_actions"]
    )
    evidence = {
        "kind": "pr-review-e2e",
        "status": "locally-verified" if ok else "failed",
        "generated_at": dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repository_commit": git(ROOT, "rev-parse", "HEAD").strip(),
        "environment": "local: fake Azure DevOps REST server (tests/review/fake_ado.py) + real git branches; no Azure, no Azure DevOps",
        "write_methods": sorted({c.split(" ")[0] for c in calls}),
        "results": results,
        "not_verified": [
            "real Azure DevOps service hooks / REST",
            "managed identity as an Azure DevOps user",
            "vote permission",
            "thread anchoring in the Azure DevOps UI",
            "AzureDevOps service tag coverage",
            "Claude API call (fake client in tests)",
        ],
    }
    out_dir = Path(a.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "e2e-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps({"status": evidence["status"], "results": [{k: r[k] for k in ("branch", "decision", "vote", "status")} for r in results]}, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
