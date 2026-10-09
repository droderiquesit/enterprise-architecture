#!/usr/bin/env bash
# terraform init against the remote azurerm backend (Entra ID auth + OIDC, blob-lease locking).
# Idempotent and network-bound, so it is retried here (bounded, with backoff) instead of retrying the
# whole pipeline step. The committed lock file is enforced (-lockfile=readonly).
# Usage: tf-init.sh <component-id> <root-path>   (env: LAB_ENV, STATE_STORAGE_ACCOUNT; source tf-env.sh first)
set -euo pipefail
component="$1"; root="$2"
: "${STATE_STORAGE_ACCOUNT:?}" "${LAB_ENV:?}"
attempts="${TF_INIT_ATTEMPTS:-3}"
for ((i = 1; i <= attempts; i++)); do
  if terraform -chdir="$root" init -input=false -no-color -lockfile=readonly \
      -backend-config="storage_account_name=${STATE_STORAGE_ACCOUNT}" \
      -backend-config="container_name=tfstate" \
      -backend-config="key=${LAB_ENV}/${component}.tfstate" \
      -backend-config="use_azuread_auth=true" \
      -backend-config="use_oidc=true"; then
    exit 0
  fi
  if ((i < attempts)); then echo "terraform init failed (attempt $i/$attempts); retrying in $((i * 15))s"; sleep $((i * 15)); fi
done
echo "##vso[task.logissue type=error]terraform init failed after $attempts attempts for $component"
exit 1
