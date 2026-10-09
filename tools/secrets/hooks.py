#!/usr/bin/env python3
"""Secret hooks of the component plan/apply scripts (pipelines/scripts/tf-plan.sh, tf-apply.sh).

    python3 tools/secrets/hooks.py post-plan  --env dev --component foundation-secrets --root foundation/secrets \
        --plan-json plan.json --summary-md summary.md      # prints `dsv_changes=true|false` (last line)
    python3 tools/secrets/hooks.py post-apply --env dev --component obs-telemetry-transport --root <root>

Registry fields (catalog/components.yaml):
  dsv_state_output  post-plan: tools/secrets/dsv_apply.py plan on the PLANNED output (diff shown in the plan summary;
                    a DSV diff forces the apply stage even when Terraform has no changes); post-apply: dsv_apply apply,
                    then tools/secrets/check.py (warning only: operators may seed values after the permissions exist).
  secret_outputs    post-apply: tools/secrets/publish.py writes the sensitive output's values to DSV.
Components without these fields: no-op.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("hook", choices=("post-plan", "post-apply"))
    ap.add_argument("--env", required=True)
    ap.add_argument("--component", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--plan-json")
    ap.add_argument("--summary-md")
    ap.add_argument("--repo", default=".")
    args = ap.parse_args(argv)
    comp = load_registry(WorkTree(Path(args.repo).resolve())).get(args.component)
    from tools.secrets import dsv_apply, publish

    if args.hook == "post-plan":
        changes = False
        if comp.dsv_state_output:
            cmd = ["plan", "--root", args.root, "--output", comp.dsv_state_output]
            if args.plan_json:
                cmd += ["--plan-json", args.plan_json]
            if args.summary_md:
                cmd += ["--summary-md", args.summary_md]
            rc = dsv_apply.main(cmd)
            if rc == 1:
                return 1
            changes = rc == 2
        print(f"dsv_changes={'true' if changes else 'false'}")
        return 0
    if comp.dsv_state_output:
        rc = dsv_apply.main(["apply", "--root", args.root, "--output", comp.dsv_state_output])
        if rc != 0:
            return rc
        from tools.secrets import check

        if check.main(["--env", args.env, "--repo", args.repo]) != 0:
            print("##vso[task.logissue type=warning]DSV: required secret paths are missing (check.py above); seed them "
                  "before applying their consumers (bootstrap/README.md, Delinea DSV prerequisites)")
    if comp.secret_outputs:
        rc = publish.main(["--env", args.env, "--component", comp.id, "--root", args.root, "--output", comp.secret_outputs,
                           "--repo", args.repo])
        if rc != 0:
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
