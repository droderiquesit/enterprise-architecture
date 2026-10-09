#!/usr/bin/env bash
# Out-of-band secret management for the lab Key Vault (foundation-identity).
#
# Terraform creates the vault, identities and RBAC but NEVER secret values (they would land in state).
# This script sets or rotates values. It must run from a host that can reach the vault's private endpoint
# (deploy agent, Bastion-connected VM, or a peered network) because public network access is disabled.
# The caller needs "Key Vault Secrets Officer" on the vault (settings.secret_officer_principal_ids).
#
# Usage:
#   set-secrets.sh <vault-name> list                      # show which secrets exist (names + updated time only)
#   set-secrets.sh <vault-name> set <secret-name>         # prompt for value (hidden), create new version
#   set-secrets.sh <vault-name> set <secret-name> --from-env VAR   # read value from environment variable VAR
#   set-secrets.sh <vault-name> generate fault-token      # random 48-byte token (rotation of lab-owned secrets)
#   set-secrets.sh <vault-name> rotate <secret-name>      # set a new version, then disable older versions
#
# Rotation model: consumers use *versionless* secret IDs (contract secret_ids), so a new version is picked up on
# the next refresh (ACA secret refresh ~30 min, App Service Key Vault references ~24 h or on restart, CSI driver
# rotation poll interval). Old versions are disabled (not deleted) so a rollback is `az keyvault secret set-attributes
# --enabled true --version <old>`.
#
# Secret catalogue (see foundation/identity/README.md):
#   datadog-api-key       Datadog API key (agents, Fluent Bit, OTel gateway)          source: Datadog org settings
#   datadog-app-key       Datadog application key (pipeline only, Terraform provider) source: Datadog org settings
#   datadog-client-token  Browser RUM client token                                    source: Datadog RUM application
#   fault-token           X-Fault-Token for POST /admin/faults                         source: generate
#   fluentbit-shared-key  Fluent Bit forward shared key (aggregator / forward sidecars) source: generate
#   dbm-mysql-password    datadog user password on MySQL Flexible (SQL auth only)      source: generate, then ALTER USER
#   dbm-sqlvm-password    datadog login password on SQL Server VM (SQL auth only)      source: generate, then ALTER LOGIN
set -euo pipefail

usage() { sed -n '2,20p' "$0"; exit 2; }
[[ $# -ge 2 ]] || usage
VAULT="$1"; CMD="$2"; NAME="${3:-}"

command -v az >/dev/null || { echo "az CLI required" >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "run 'az login' first" >&2; exit 1; }

set_value() {
  local name="$1" value="$2" tmp version
  # The value goes through a 0600 temp file, never argv, so it stays out of the process list and shell history.
  tmp="$(mktemp)"; chmod 600 "$tmp"; trap 'rm -f "$tmp"' RETURN
  printf '%s' "$value" > "$tmp"
  version="$(az keyvault secret set --vault-name "$VAULT" --name "$name" --file "$tmp" --encoding utf-8 \
    --tags managed_by=set-secrets.sh rotated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --query id -o tsv)"
  echo "set $name -> version ${version##*/}"
}

disable_old_versions() {
  local name="$1" current
  current="$(az keyvault secret show --vault-name "$VAULT" --name "$name" --query id -o tsv)"
  az keyvault secret list-versions --vault-name "$VAULT" --name "$name" --query "[?attributes.enabled].id" -o tsv |
    while read -r id; do
      [[ "$id" == "$current" ]] && continue
      az keyvault secret set-attributes --id "$id" --enabled false >/dev/null && echo "disabled ${id##*/}"
    done
}

read_value() {
  if [[ "${4:-}" == "--from-env" && -n "${5:-}" ]]; then
    printf '%s' "${!5:?environment variable $5 is empty}"
  else
    local v; read -r -s -p "value for $NAME: " v; echo >&2; printf '%s' "$v"
  fi
}

case "$CMD" in
  list)
    az keyvault secret list --vault-name "$VAULT" --query "[].{name:name, enabled:attributes.enabled, updated:attributes.updated}" -o table ;;
  set)
    [[ -n "$NAME" ]] || usage
    set_value "$NAME" "$(read_value "$@")" ;;
  generate)
    [[ -n "$NAME" ]] || usage
    set_value "$NAME" "$(openssl rand -base64 48 | tr -d '\n')" ;;
  rotate)
    [[ -n "$NAME" ]] || usage
    if [[ "$NAME" == "fault-token" || "$NAME" == "fluentbit-shared-key" || "$NAME" == dbm-*-password ]]; then
      set_value "$NAME" "$(openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-48)"
      [[ "$NAME" == dbm-*-password ]] && echo "NOW update the database user password to the new value (ALTER USER/LOGIN) before agents restart."
    else
      set_value "$NAME" "$(read_value "$@")"
    fi
    disable_old_versions "$NAME" ;;
  *) usage ;;
esac
