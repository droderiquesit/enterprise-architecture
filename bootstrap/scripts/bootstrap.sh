#!/usr/bin/env bash
# Idempotent first run (and re-run) of the bootstrap component. Manual only: the universal pipeline never
# applies bootstrap (catalog/components.yaml: pipeline: manual).
#
#   bootstrap/scripts/bootstrap.sh --env dev [--plan-only] [--skip-providers]
#
# What it does (each step is safe to repeat):
#   1. checks tools + `az login` + that the active subscription is environment.subscription_id
#   2. registers the resource providers the lab needs (pipeline identities have no rights to do this)
#   3. renders bootstrap/terraform.tfvars.json (tools/config/render.py if present, else a built-in fallback)
#   4. if the state blob <env>/bootstrap.tfstate does not exist yet:
#        terraform init with a temporary LOCAL backend override -> apply -> migrate state into the new account
#      otherwise: terraform init against the azurerm backend -> plan -> (confirm) apply
#
# Requirements: az CLI >= 2.60, terraform >= 1.14, python3 + pyyaml, jq. Owner (or Contributor + RBAC Administrator
# + Resource Policy Contributor) on the subscription. Your public IP must be in components.bootstrap.operator_ip_ranges
# and your object ID (or a group you are in) in components.bootstrap.operator_principal_ids.
set -euo pipefail

ENV_NAME=""; PLAN_ONLY=false; SKIP_PROVIDERS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    --plan-only) PLAN_ONLY=true; shift ;;
    --skip-providers) SKIP_PROVIDERS=true; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$ENV_NAME" ]] || { echo "--env is required" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOT_DIR="$ROOT_DIR/bootstrap"
ENV_FILE="$ROOT_DIR/environments/$ENV_NAME/environment.yaml"
TFVARS="$BOOT_DIR/terraform.tfvars.json"
OVERRIDE="$BOOT_DIR/backend_override.tf"
log() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Resource providers used across the catalogue (bootstrap.sh is the only place that registers them).
# Microsoft.KeyVault: only the optional Azure ML workspace (platform-specialized-compute) and APIM need it; lab
# secrets live in Delinea DSV (ADR-0001 section 14).
PROVIDERS=(
  Microsoft.Storage Microsoft.Network Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.Authorization
  Microsoft.Insights Microsoft.OperationalInsights Microsoft.AlertsManagement Microsoft.Consumption Microsoft.CostManagement
  Microsoft.PolicyInsights Microsoft.ResourceGraph
  Microsoft.App Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.ContainerInstance
  Microsoft.Web Microsoft.Compute Microsoft.Batch Microsoft.ServiceFabric Microsoft.RedHatOpenShift
  Microsoft.DevOpsInfrastructure Microsoft.DevCenter
  Microsoft.Sql Microsoft.DBforPostgreSQL Microsoft.DBforMySQL Microsoft.DocumentDB Microsoft.Cache
  Microsoft.ConfidentialLedger Microsoft.Kusto Microsoft.Synapse Microsoft.Search
  Microsoft.ServiceBus Microsoft.EventHub Microsoft.EventGrid Microsoft.Logic Microsoft.ApiManagement Microsoft.Cdn
  Microsoft.Automation Microsoft.MachineLearningServices Microsoft.DurableTask
)

# ---------------------------------------------------------------- 1. preflight
log "preflight"
for t in az terraform python3 jq; do command -v "$t" >/dev/null || die "$t not found on PATH"; done
[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE"
az account show >/dev/null 2>&1 || die "not logged in: run 'az login --tenant <tenant-id>'"

read -r SUB_ID TENANT_ID LOCATION PREFIX < <(python3 - "$ENV_FILE" <<'PY'
import sys, yaml
e = yaml.safe_load(open(sys.argv[1]))["environment"]
print(e["subscription_id"], e["tenant_id"], e["location"], e.get("name_prefix", "eh"))
PY
)
[[ "$SUB_ID" =~ ^0{8}-0{4}-0{4}-0{4}-0{12}$ ]] && die "environment.subscription_id is still the placeholder in $ENV_FILE"
az account set --subscription "$SUB_ID"
ACTIVE_TENANT="$(az account show --query tenantId -o tsv)"
[[ "$ACTIVE_TENANT" == "$TENANT_ID" ]] || die "active tenant $ACTIVE_TENANT != environment.tenant_id $TENANT_ID"
ME_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
echo "subscription=$SUB_ID tenant=$TENANT_ID location=$LOCATION operator_object_id=${ME_OID:-<service principal>}"

# ---------------------------------------------------------------- 2. resource providers
if ! $SKIP_PROVIDERS; then
  log "registering resource providers (idempotent)"
  for ns in "${PROVIDERS[@]}"; do
    state="$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo NotFound)"
    if [[ "$state" != "Registered" ]]; then
      echo "register $ns ($state)"; az provider register --namespace "$ns" >/dev/null || echo "  WARN: could not register $ns"
    fi
  done
  for ns in "${PROVIDERS[@]}"; do
    for _ in $(seq 1 60); do
      state="$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo NotFound)"
      [[ "$state" == "Registered" || "$state" == "NotFound" ]] && break; sleep 5
    done
    [[ "$state" == "Registered" ]] || echo "  WARN: $ns is $state"
  done
fi

# ---------------------------------------------------------------- 3. render tfvars
log "rendering $TFVARS"
if [[ -x "$ROOT_DIR/tools/config/render.py" || -f "$ROOT_DIR/tools/config/render.py" ]]; then
  python3 "$ROOT_DIR/tools/config/render.py" --env "$ENV_NAME" --component bootstrap
else
  python3 - "$ENV_FILE" "$TFVARS" <<'PY'
import json, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
e = doc["environment"]
keys = ["name", "location", "subscription_id", "tenant_id", "name_prefix", "owner", "team", "cost_center", "expires_on", "tags"]
env = {k: e.get(k, {} if k == "tags" else "") for k in keys}
settings = (doc.get("components") or {}).get("bootstrap") or {}
json.dump({"environment": env, "settings": settings}, open(sys.argv[2], "w"), indent=2)
PY
fi

cd "$BOOT_DIR"
STATE_KEY="$ENV_NAME/bootstrap.tfstate"
# Discover an existing state account by its tags (component=bootstrap, env=<env>) instead of re-implementing the
# naming module here. Empty => first run.
read -r STATE_RG STATE_SA < <(az storage account list --subscription "$SUB_ID" \
  --query "[?tags.component=='bootstrap' && tags.env=='$ENV_NAME'] | [0].[resourceGroup, name]" -o tsv 2>/dev/null || true) || true
echo "state: rg=${STATE_RG:-<to be created>} account=${STATE_SA:-<to be created>} key=$STATE_KEY"

# Operator coverage checks (fail early instead of failing in the middle of a migration).
if [[ -n "$ME_OID" ]]; then
  python3 - "$TFVARS" "$ME_OID" <<'PY' || echo "  WARN: your object id is not in settings.operator_principal_ids (fine if a group you belong to is)."
import json, sys
s = json.load(open(sys.argv[1])).get("settings", {})
sys.exit(0 if sys.argv[2] in s.get("operator_principal_ids", []) else 1)
PY
fi
MY_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
if [[ -n "$MY_IP" ]]; then
  python3 - "$TFVARS" "$MY_IP" <<'PY' || die "your public IP $MY_IP is not in settings.operator_ip_ranges; add it (or run from a deploy-agent subnet) and re-run"
import ipaddress, json, sys
s = json.load(open(sys.argv[1])).get("settings", {})
if s.get("public_network_access", "Enabled") == "Disabled":
    sys.exit(0)  # phase 2: you must be on the private network anyway
ip = ipaddress.ip_address(sys.argv[2])
sys.exit(0 if any(ip in ipaddress.ip_network(r if "/" in r else r + "/32", strict=False) for r in s.get("operator_ip_ranges", [])) else 1)
PY
fi

backend_args() {
  BACKEND_ARGS=(
  -backend-config="resource_group_name=$STATE_RG"
  -backend-config="storage_account_name=$STATE_SA"
  -backend-config="container_name=tfstate"
  -backend-config="key=$STATE_KEY"
  -backend-config="use_azuread_auth=true"
  )
}

state_exists() {
  az storage blob exists --auth-mode login --account-name "$STATE_SA" --container-name tfstate --name "$STATE_KEY" \
    --query exists -o tsv 2>/dev/null | grep -qi true
}

apply_or_plan() {
  terraform plan -input=false -var-file="$TFVARS" -out=bootstrap.tfplan
  if $PLAN_ONLY; then rm -f bootstrap.tfplan; return; fi
  read -r -p "apply this plan? [y/N] " ok; [[ "$ok" == "y" ]] || { rm -f bootstrap.tfplan; die "aborted"; }
  terraform apply -input=false bootstrap.tfplan; rm -f bootstrap.tfplan
}

# ---------------------------------------------------------------- 4. local first run or remote re-run
if [[ -n "${STATE_SA:-}" ]] && state_exists; then
  log "state already migrated: using azurerm backend"
  rm -f "$OVERRIDE"; backend_args
  terraform init -input=false -reconfigure "${BACKEND_ARGS[@]}"
  apply_or_plan
  exit 0
fi

log "first run: local state"
cat > "$OVERRIDE" <<'HCL'
# TEMPORARY - written by scripts/bootstrap.sh for the first (local-state) apply; deleted before migration.
terraform {
  backend "local" {
    path = "bootstrap.local.tfstate"
  }
}
HCL
trap 'echo "NOTE: $OVERRIDE and bootstrap.local.tfstate are left in place for inspection" >&2' ERR
terraform init -input=false -reconfigure
apply_or_plan
$PLAN_ONLY && { rm -f "$OVERRIDE"; exit 0; }

STATE_RG="$(terraform output -json backend_config | jq -r .resource_group_name)"
STATE_SA="$(terraform output -json backend_config | jq -r .storage_account_name)"
backend_args

log "waiting for data-plane RBAC to propagate (operator -> tfstate)"
for i in $(seq 1 30); do
  az storage container show --auth-mode login --account-name "$STATE_SA" --name tfstate >/dev/null 2>&1 && break
  echo "  not yet ($i/30)"; sleep 20
done

log "migrating local state -> azurerm backend ($STATE_SA/tfstate/$STATE_KEY)"
rm -f "$OVERRIDE"
terraform init -input=false -migrate-state -force-copy "${BACKEND_ARGS[@]}"
state_exists || die "migration did not produce $STATE_KEY; local copy kept in bootstrap.local.tfstate"
mv bootstrap.local.tfstate "bootstrap.local.tfstate.migrated-$(date -u +%Y%m%dT%H%M%SZ)"
echo "migrated. Keep the .migrated-* file until you have verified 'terraform plan' shows no changes, then delete it (it contains state)."
terraform plan -input=false -var-file="$TFVARS" -detailed-exitcode && echo "no drift after migration"
