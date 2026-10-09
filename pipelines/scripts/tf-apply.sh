#!/usr/bin/env bash
# Apply a previously reviewed plan after verifying its binding manifest, then publish the contract
# and write the deployment record. Deployment roots also run their code-deploy steps and smoke test.
# Usage: tf-apply.sh <component-id> <root-path>
# Env: LAB_ENV, BINDING_FILE, MANIFEST_FILE, PLANS_URL, CONTRACTS_URL, RECORDS_URL, SELECTION_FILE, APPLIED_MARKER,
#      TF_SECRET_ENV (see tf-secrets.sh), ROLLBACK_MARKER (default $AGENT_TEMPDIRECTORY/rolled-back)
# Self-healing (pipelines/README.md "Self-healing"):
#   * terraform apply runs through tools/deploy/retry.py tf-apply: after a TRANSIENT failure it re-plans and applies
#     the remaining diff only when it stays inside the reviewed plan (new changes / destroys are refused);
#     a state lock goes to tools/deploy/lock_doctor.py (never breaks the lock of a running build);
#   * application roots (applications/deployments/*): when code deploy or smoke fails, rollback.sh restores the
#     previous release (traffic shift / slot swap back / helm rollback / previous package) and re-runs smoke; the
#     record becomes `rolled_back` and the stage still fails. Infrastructure is never rolled back automatically.
set -euo pipefail
component="$1"; root="$2"
source pipelines/scripts/tf-secrets.sh
mkdir -p "$OUT_DIR/health"
export ROLLBACK_MARKER="${ROLLBACK_MARKER:-${AGENT_TEMPDIRECTORY:-/tmp}/rolled-back}"
export DEPLOY_PROGRESS_FILE="${DEPLOY_PROGRESS_FILE:-$OUT_DIR/health/deploy-progress.txt}"
work="$(mktemp -d)"
python3 tools/deploy/lock_doctor.py claim --env "$LAB_ENV" --component "$component" \
  || echo "##vso[task.logissue type=warning]could not write the lock-holder claim for $component"
trap 'python3 tools/deploy/lock_doctor.py release --env "$LAB_ENV" --component "$component" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
key="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['plan_key'])" "$MANIFEST_FILE")"
python3 tools/deploy/storecp.py get --store "$PLANS_URL" --key "$key" --file "$work/tfplan"
# refuses with "stale plan; re-run" when commit/config/contracts/artifacts/tool versions differ
python3 tools/deploy/plan_manifest.py verify --manifest "$MANIFEST_FILE" --component "$component" --env "$LAB_ENV" \
  --root "$root" --plan "$work/tfplan" --binding "$BINDING_FILE"
tf_secret python3 tools/deploy/retry.py tf-apply --component "$component" --root "$root" --plan "$work/tfplan" \
  --lock-key "${LAB_ENV}/${component}.tfstate"
touch "$APPLIED_MARKER"   # infrastructure applied: a later failure records `partial`
# Secret hooks: dsv_apply.py apply (registry dsv_state_output) and publish.py (secret_outputs -> DSV).
python3 tools/secrets/hooks.py post-apply --env "$LAB_ENV" --component "$component" --root "$root"
# Application deployment roots: code deployment (zip/one-deploy/slot swap/SWA/VMSS rollout) declared by the root in
# contract.deploy_steps, then the root's own smoke test.
if [[ "$root" == applications/deployments/* ]]; then
  : > "$DEPLOY_PROGRESS_FILE"
  # deploy-zip.sh retries its idempotent az calls itself (lib.sh with_retry); slot swaps are never repeated blindly
  if ! bash applications/deployments/scripts/deploy-zip.sh --contract "$root" --root "$root" \
     || ! bash applications/deployments/scripts/smoke.sh --contract "$root" --attempts "${SMOKE_ATTEMPTS:-30}" \
        --interval "${SMOKE_INTERVAL:-10}" > "$OUT_DIR/health/smoke.json"; then
    echo "##vso[task.logissue type=error]$component: code deploy or smoke test failed"
    auto_rollback="$(python3 -c "import yaml,sys;d=yaml.safe_load(open(sys.argv[1])) or {};print(str((d.get('self_healing') or {}).get('auto_rollback', True)).lower())" "environments/${LAB_ENV}/environment.yaml")"
    if [[ "$auto_rollback" == "true" ]]; then
      if bash applications/deployments/scripts/rollback.sh --component "$component" --root "$root" --env "$LAB_ENV" \
           --progress "$DEPLOY_PROGRESS_FILE" --out "$OUT_DIR/health/rollback.json"; then
        echo "rolled back to the previous release" > "$ROLLBACK_MARKER"
      else
        bash pipelines/scripts/alert.sh "$component" rollback-failed "automatic rollback failed; see docs/runbooks/rollback.md"
      fi
    fi
    exit 1
  fi
fi
python3 tools/contracts/publish.py publish --component "$component" --env "$LAB_ENV" --root "$root" --store "$CONTRACTS_URL"
python3 tools/deploy/record.py write --env "$LAB_ENV" --component "$component" --status succeeded \
  --selection "$SELECTION_FILE" --store "$RECORDS_URL" --manifest "$MANIFEST_FILE"
