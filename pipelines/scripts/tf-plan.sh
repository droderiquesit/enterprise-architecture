#!/usr/bin/env bash
# Plan one root, run the plan policy, write the binding manifest, upload the plan file to the
# protected `plans` container and set output variables has_changes / plan_exit.
# Usage: tf-plan.sh <component-id> <root-path>
# Env: LAB_ENV, BINDING_FILE, OUT_DIR (published summary dir), PLANS_URL, RECORDS_URL, CONTRACTS_URL,
#      APPLY_CANDIDATE ('true'/'false'), DRY_RUN ('True'/'False'), BUILD_BUILDID, SYSTEM_JOBATTEMPT, BUILD_SOURCEVERSION
set -euo pipefail
component="$1"; root="$2"
mkdir -p "$OUT_DIR"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
set +e
terraform -chdir="$root" plan -input=false -no-color -lock-timeout=10m -detailed-exitcode -out="$work/tfplan" | tee "$OUT_DIR/plan.log"
rc=${PIPESTATUS[0]}
set -e
if [[ $rc -eq 1 ]]; then echo "##vso[task.logissue type=error]terraform plan failed for $component"; exit 1; fi
terraform -chdir="$root" show -json "$work/tfplan" > "$work/plan.json"   # sensitive: never published
python3 tools/validate/plan_policy.py --plan "$work/plan.json" --component "$component" --env "$LAB_ENV" \
  --summary-md "$OUT_DIR/summary.md" --summary-json "$OUT_DIR/summary.json"
key="${LAB_ENV}/${component}/${BUILD_BUILDID}-${SYSTEM_JOBATTEMPT}.tfplan"
python3 tools/deploy/plan_manifest.py create --component "$component" --env "$LAB_ENV" --root "$root" \
  --plan "$work/tfplan" --binding "$BINDING_FILE" --plan-key "$key" --exit-code "$rc" --out "$OUT_DIR/manifest.json"
python3 tools/deploy/storecp.py put --store "$PLANS_URL" --key "$key" --file "$work/tfplan"
has_changes=false
if [[ $rc -eq 2 ]]; then
  has_changes=true
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
echo "##vso[task.setvariable variable=has_changes;isOutput=true]$has_changes"
echo "##vso[task.setvariable variable=plan_exit;isOutput=true]$rc"
echo "##vso[task.setvariable variable=artifact;isOutput=true]plan-${component}-${SYSTEM_JOBATTEMPT}"
echo "plan exit=$rc has_changes=$has_changes"
