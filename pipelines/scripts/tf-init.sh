#!/usr/bin/env bash
# terraform init against the remote azurerm backend (Entra ID auth + OIDC, blob-lease locking).
# Usage: tf-init.sh <component-id> <root-path>   (env: LAB_ENV, STATE_STORAGE_ACCOUNT; source tf-env.sh first)
set -euo pipefail
component="$1"; root="$2"
: "${STATE_STORAGE_ACCOUNT:?}"
terraform -chdir="$root" init -input=false -no-color -lockfile=readonly \
  -backend-config="storage_account_name=${STATE_STORAGE_ACCOUNT}" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=${LAB_ENV}/${component}.tfstate" \
  -backend-config="use_azuread_auth=true" \
  -backend-config="use_oidc=true"
