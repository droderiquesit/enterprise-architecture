#!/usr/bin/env bash
# Render configuration, materialize upstream contracts and artifact digests for one root, and write
# the binding inputs ($BINDING_FILE) used by the plan manifest.
# Usage: tf-prepare.sh <component-id> <root-path>
# Env: LAB_ENV, CONTRACTS_URL, ARTIFACT_METADATA_DIR (optional), BINDING_FILE
set -euo pipefail
component="$1"; root="$2"
config_sha="$(python3 tools/config/render.py --env "$LAB_ENV" --component "$component")"
contracts_sha="$(python3 tools/contracts/materialize.py --env "$LAB_ENV" --component "$component" --source "$CONTRACTS_URL")"
artifacts_sha="$(python3 tools/deploy/artifacts.py tfvars --component "$component" --metadata-dir "${ARTIFACT_METADATA_DIR:-/nonexistent}")"
python3 - "$BINDING_FILE" "$config_sha" "$contracts_sha" "$artifacts_sha" <<'PY'
import json, sys
json.dump({"config_sha": sys.argv[2], "contracts_sha": sys.argv[3], "artifacts_sha": sys.argv[4]}, open(sys.argv[1], "w"), indent=2)
PY
echo "config_sha=$config_sha contracts_sha=$contracts_sha artifacts_sha=$artifacts_sha"
