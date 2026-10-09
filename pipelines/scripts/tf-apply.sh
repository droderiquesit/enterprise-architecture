#!/usr/bin/env bash
# Apply a previously reviewed plan after verifying its binding manifest, then publish the contract
# and write the deployment record.
# Usage: tf-apply.sh <component-id> <root-path>
# Env: LAB_ENV, BINDING_FILE, MANIFEST_FILE, PLANS_URL, CONTRACTS_URL, RECORDS_URL, SELECTION_FILE, APPLIED_MARKER
set -euo pipefail
component="$1"; root="$2"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
key="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['plan_key'])" "$MANIFEST_FILE")"
python3 tools/deploy/storecp.py get --store "$PLANS_URL" --key "$key" --file "$work/tfplan"
# refuses with "stale plan; re-run" when commit/config/contracts/artifacts/tool versions differ
python3 tools/deploy/plan_manifest.py verify --manifest "$MANIFEST_FILE" --component "$component" --env "$LAB_ENV" \
  --root "$root" --plan "$work/tfplan" --binding "$BINDING_FILE"
terraform -chdir="$root" apply -input=false -no-color -lock-timeout=10m "$work/tfplan"
touch "$APPLIED_MARKER"
python3 tools/contracts/publish.py publish --component "$component" --env "$LAB_ENV" --root "$root" --store "$CONTRACTS_URL"
python3 tools/deploy/record.py write --env "$LAB_ENV" --component "$component" --status succeeded \
  --selection "$SELECTION_FILE" --store "$RECORDS_URL" --manifest "$MANIFEST_FILE"
