#!/usr/bin/env bash
# Plan one root, run the plan policy, write the binding manifest, upload the plan file to the
# protected `plans` container and set output variables has_changes / plan_exit.
# Usage: tf-plan.sh <component-id> <root-path>
# Env: LAB_ENV, BINDING_FILE, OUT_DIR (published summary dir), PLANS_URL, RECORDS_URL, CONTRACTS_URL,
#      APPLY_CANDIDATE ('true'/'false'), DRY_RUN ('True'/'False'), BUILD_BUILDID, SYSTEM_JOBATTEMPT, BUILD_SOURCEVERSION,
#      TF_SECRET_ENV ('true': terraform runs through tools/secrets/fetch.py exec with the registry secret_env)
# Self-healing: transient plan failures are retried by tools/deploy/retry.py; a state lock is handed to
# tools/deploy/lock_doctor.py (wait for a live holder, break only a provably stale lock). Drift runs re-apply only
# additive drift of components the selection marked `remediate: additive-only` (tools/deploy/remediate.py).
set -euo pipefail
component="$1"; root="$2"
source pipelines/scripts/tf-secrets.sh
mkdir -p "$OUT_DIR/health"
work="$(mktemp -d)"
python3 tools/deploy/lock_doctor.py claim --env "$LAB_ENV" --component "$component" \
  || echo "##vso[task.logissue type=warning]could not write the lock-holder claim for $component"
trap 'python3 tools/deploy/lock_doctor.py release --env "$LAB_ENV" --component "$component" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
set +e
tf_secret python3 tools/deploy/retry.py run --component "$component" --label "terraform plan" --ok-codes 0,2 \
  --lock-key "${LAB_ENV}/${component}.tfstate" -- \
  terraform -chdir="$root" plan -input=false -no-color -lock-timeout=5m -detailed-exitcode -out="$work/tfplan" \
  | tee "$OUT_DIR/plan.log"
rc=${PIPESTATUS[0]}
set -e
if [[ $rc -ne 0 && $rc -ne 2 ]]; then echo "##vso[task.logissue type=error]terraform plan failed for $component"; exit 1; fi
terraform -chdir="$root" show -json "$work/tfplan" > "$work/plan.json"   # sensitive: never published
python3 tools/validate/plan_policy.py --plan "$work/plan.json" --component "$component" --env "$LAB_ENV" \
  --summary-md "$OUT_DIR/summary.md" --summary-json "$OUT_DIR/summary.json"
key="${LAB_ENV}/${component}/${BUILD_BUILDID}-${SYSTEM_JOBATTEMPT}.tfplan"
python3 tools/deploy/plan_manifest.py create --component "$component" --env "$LAB_ENV" --root "$root" \
  --plan "$work/tfplan" --binding "$BINDING_FILE" --plan-key "$key" --exit-code "$rc" --out "$OUT_DIR/manifest.json"
python3 tools/deploy/storecp.py put --store "$PLANS_URL" --key "$key" --file "$work/tfplan"
mode="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('mode',''))" "$SELECTION_FILE" 2>/dev/null || echo "")"
has_changes=false
if [[ "$mode" == "drift" ]]; then
  # drift runs: never DSV convergence / contract republish; only additive Terraform drift where allowed
  remediate="$(python3 tools/deploy/remediate.py check --selection "$SELECTION_FILE" --component "$component" \
    --plan-json "$work/plan.json" --out "$OUT_DIR/health/remediation.json" | tail -1)"
  if [[ $rc -eq 2 && "$remediate" == "remediate=true" ]]; then
    echo "additive-only drift: the apply stage re-applies the desired state"; has_changes=true
  elif [[ "$remediate" == "remediate=refused" ]]; then
    bash pipelines/scripts/alert.sh "$component" drift-refused \
      "drift plan deletes/replaces resources; not auto-remediated (summary: plan-$component artifact)"
  fi
else
  # Secret hooks (registry dsv_state_output): DSV desired-state diff in the summary; a DSV diff forces the apply stage.
  python3 tools/secrets/hooks.py post-plan --env "$LAB_ENV" --component "$component" --root "$root" \
    --plan-json "$work/plan.json" --summary-md "$OUT_DIR/summary.md" | tee "$work/hooks.out"
  dsv_changes="$(tail -1 "$work/hooks.out")"
  if [[ $rc -eq 2 ]]; then
    has_changes=true
  elif [[ "$dsv_changes" == "dsv_changes=true" ]]; then
    echo "DSV configuration differs from the desired state: forcing the Apply job"; has_changes=true
  elif ! python3 tools/contracts/publish.py check --component "$component" --env "$LAB_ENV" --store "$CONTRACTS_URL"; then
    echo "contract envelope missing: forcing the Apply job to publish it"; has_changes=true
  elif [[ "${APPLY_CANDIDATE}" == "true" && "${DRY_RUN,,}" != "true" ]]; then
    # no changes: record the new fingerprint so the component is not re-selected next run
    # needs Storage Blob Data Contributor on `deployments` for the plan identity; without it the
    # component is simply re-planned (no apply) on the next run
    python3 tools/deploy/record.py write --env "$LAB_ENV" --component "$component" --status succeeded \
      --selection "$SELECTION_FILE" --store "$RECORDS_URL" --note "plan had no changes" --manifest "$OUT_DIR/manifest.json" \
      || echo "##vso[task.logissue type=warning]could not write the no-change record for $component (plan identity lacks write on deployments?)"
  fi
fi
echo "##vso[task.setvariable variable=has_changes;isOutput=true]$has_changes"
echo "##vso[task.setvariable variable=plan_exit;isOutput=true]$rc"
echo "##vso[task.setvariable variable=artifact;isOutput=true]plan-${component}-${SYSTEM_JOBATTEMPT}"
echo "plan exit=$rc has_changes=$has_changes"
