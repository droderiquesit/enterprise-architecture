#!/usr/bin/env bash
# Find lab resources/resource groups whose `expires_on` tag is in the past.
#
# Scope is deliberately narrow: ONLY resources tagged application=enterprise-hello AND
# repository=azure-enterprise-observability-lab are ever listed. This script never deletes anything;
# it prints candidates (and optionally the `az group delete` commands to review).
#
# Usage: find-expired.sh [--subscription <id>] [--env <env>] [--as-of YYYY-MM-DD] [--print-delete-commands]
# Requires: az CLI + resource-graph extension (`az extension add --name resource-graph`), Reader on the subscription.
set -euo pipefail

SUB=""; ENV_FILTER=""; AS_OF="$(date -u +%Y-%m-%d)"; PRINT_DELETE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUB="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --env) ENV_FILTER="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --as-of) AS_OF="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --print-delete-commands) PRINT_DELETE=true; shift ;;
    *) sed -n '2,10p' "$0"; exit 2 ;;
  esac
done

# Values below are interpolated into Resource Graph (KQL) queries: accept only their expected shapes.
[[ -z "$SUB" || "$SUB" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "invalid --subscription '$SUB' (expected a subscription id)" >&2; exit 2; }
[[ -z "$ENV_FILTER" || "$ENV_FILTER" =~ ^[a-z0-9-]{1,32}$ ]] || { echo "invalid --env '$ENV_FILTER'" >&2; exit 2; }
[[ "$AS_OF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "invalid --as-of '$AS_OF' (expected YYYY-MM-DD)" >&2; exit 2; }

env_clause=""
[[ -n "$ENV_FILTER" ]] && env_clause="| where tostring(tags['env']) == '${ENV_FILTER}'"
sub_args=()
[[ -n "$SUB" ]] && sub_args=(--subscriptions "$SUB")

# Resource groups (the teardown unit) ...
read -r -d '' RG_QUERY <<KQL || true
resourcecontainers
| where type =~ 'microsoft.resources/subscriptions/resourcegroups'
| where tostring(tags['application']) == 'enterprise-hello'
| where tostring(tags['repository']) == 'azure-enterprise-observability-lab'
${env_clause}
| extend expires_on = todatetime(tostring(tags['expires_on']))
| where isnotnull(expires_on) and expires_on < todatetime('${AS_OF}')
| project subscriptionId, resourceGroup = name, env = tostring(tags['env']), component = tostring(tags['component']),
          owner = tostring(tags['owner']), expires_on
| order by expires_on asc
KQL

# ... and individual resources (catches resources created outside the lab RGs).
read -r -d '' RES_QUERY <<KQL || true
resources
| where tostring(tags['application']) == 'enterprise-hello'
| where tostring(tags['repository']) == 'azure-enterprise-observability-lab'
${env_clause}
| extend expires_on = todatetime(tostring(tags['expires_on']))
| where isnotnull(expires_on) and expires_on < todatetime('${AS_OF}')
| summarize resources = count() by subscriptionId, resourceGroup, env = tostring(tags['env']), expires_on
| order by expires_on asc
KQL

echo "== expired lab resource groups (as of ${AS_OF})"
az graph query -q "$RG_QUERY" "${sub_args[@]}" --first 1000 -o table
echo "== expired lab resources by resource group"
az graph query -q "$RES_QUERY" "${sub_args[@]}" --first 1000 -o table

if $PRINT_DELETE; then
  echo "== review before running (state storage / bootstrap RG is lock-protected and must be removed manually):"
  az graph query -q "$RG_QUERY" "${sub_args[@]}" --first 1000 --query "data[].[subscriptionId, resourceGroup]" -o tsv |
    while read -r sub rg; do echo "az group delete --subscription $sub --name $rg --yes --no-wait"; done
fi
