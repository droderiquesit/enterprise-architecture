#!/usr/bin/env bash
# Source (do not execute) inside an AzureCLI@2 task that has addSpnToEnvironment: true.
# Configures the azurerm/azapi providers AND the azurerm backend for Azure DevOps workload identity
# federation (OIDC). Per the azurerm provider docs, ARM_ADO_PIPELINE_SERVICE_CONNECTION_ID plus
# SYSTEM_ACCESSTOKEN (ARM_OIDC_REQUEST_TOKEN fallback) and SYSTEM_OIDCREQUESTURI (ARM_OIDC_REQUEST_URL
# fallback) let Terraform request fresh ID tokens itself, so long applies do not outlive a token.
# Required env (mapped by the template): LAB_ENV, ARM_ADO_PIPELINE_SERVICE_CONNECTION_ID,
# SYSTEM_ACCESSTOKEN, SYSTEM_OIDCREQUESTURI. Never `set -x` while these are present.
set +x
: "${servicePrincipalId:?addSpnToEnvironment must be true}"
: "${tenantId:?addSpnToEnvironment must be true}"
: "${ARM_ADO_PIPELINE_SERVICE_CONNECTION_ID:?service connection id not mapped}"
: "${SYSTEM_ACCESSTOKEN:?map SYSTEM_ACCESSTOKEN: \$(System.AccessToken)}"
: "${LAB_ENV:?LAB_ENV not set}"
source pipelines/scripts/pipeline-env.sh
export ARM_CLIENT_ID="$servicePrincipalId"
export ARM_TENANT_ID="$tenantId"
export ARM_USE_OIDC=true
export ARM_USE_AZUREAD=true
export ARM_USE_CLI=false
export ARM_OIDC_AZURE_SERVICE_CONNECTION_ID="$ARM_ADO_PIPELINE_SERVICE_CONNECTION_ID"
ARM_SUBSCRIPTION_ID="$(python3 -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['environment']['subscription_id'])" "environments/${LAB_ENV}/environment.yaml")"
export ARM_SUBSCRIPTION_ID
export TF_IN_AUTOMATION=true TF_INPUT=0
mkdir -p "$OUT_DIR/health"
export RETRY_LOG="${RETRY_LOG:-$OUT_DIR/health/retries.jsonl}"
bash pipelines/scripts/preflight.sh || { echo "##vso[task.logissue type=error]agent pre-flight failed (see PREFLIGHT_FAIL lines)"; exit 1; }
unset idToken servicePrincipalKey 2>/dev/null || true
