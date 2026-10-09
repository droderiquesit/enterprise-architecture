#!/usr/bin/env bash
# terraform init against the remote azurerm backend (Entra ID auth + OIDC, blob-lease locking).
# Idempotent and network-bound: transient failures (tools/deploy/retry_rules.yaml) are retried with bounded
# exponential backoff by tools/deploy/retry.py (registry `retry` / RETRY_ATTEMPTS); permanent ones fail fast.
# The committed lock file is enforced (-lockfile=readonly).
# Usage: tf-init.sh <component-id> <root-path>   (env: LAB_ENV, STATE_STORAGE_ACCOUNT; source tf-env.sh first)
set -euo pipefail
component="$1"; root="$2"
: "${STATE_STORAGE_ACCOUNT:?}" "${LAB_ENV:?}"
if [[ -n "${TF_INIT_ATTEMPTS:-}" ]]; then export RETRY_ATTEMPTS="$TF_INIT_ATTEMPTS"; fi
python3 tools/deploy/retry.py run --component "$component" --label "terraform init" -- \
  terraform -chdir="$root" init -input=false -no-color -lockfile=readonly \
    -backend-config="storage_account_name=${STATE_STORAGE_ACCOUNT}" \
    -backend-config="container_name=tfstate" \
    -backend-config="key=${LAB_ENV}/${component}.tfstate" \
    -backend-config="use_azuread_auth=true" \
    -backend-config="use_oidc=true" \
  || { echo "##vso[task.logissue type=error]terraform init failed for $component"; exit 1; }
