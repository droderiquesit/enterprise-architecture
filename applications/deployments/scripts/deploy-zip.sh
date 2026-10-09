#!/usr/bin/env bash
# Run the code-deployment steps a deployment root publishes in contract.deploy_steps (after terraform apply):
#
#   deploy-zip.sh --contract <contract json | envelope | root dir> [--root <terraform root dir>] [--no-swap] [--only <app>]
#
# kinds:
#   webapp-zip            az webapp deploy --type zip (to the staging slot when present) -> probe slot -> slot swap
#   functionapp-flex      Flex Consumption one deploy: az functionapp deployment config show (deployment storage check)
#                         + az functionapp deployment source config-zip (package lands in the app's deployment container)
#   logicapp-zip          az logicapp deployment source config-zip (Logic Apps Standard workflows)
#   swa                   delegated to deploy-swa.sh
#   vmss-update-instances az vmss update-instances '*' (Uniform, Manual upgrade policy: apply the new extension model)
#   vmss-flex-rollout     existing Flexible instances: az vm run-command invoke with the root's vmss_rollout_script output
#   batch-job             delegated to jobs/scripts/submit-batch-job.sh
# Packages are downloaded with Entra auth (`az storage blob download --auth-mode login`) and sha256-verified.
# Rollback: webapps -> `az webapp deployment slot swap --slot staging` again; others -> re-run with the previous artifacts.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LOGGER=deploy-zip
# shellcheck source=lib.sh
source "$HERE/lib.sh"

SRC="" ; ROOT="" ; SWAP=1 ; ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) SRC="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    --no-swap) SWAP=0; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ -n "$SRC" ]] || die "--contract required"
C=$(contract_json "$SRC")
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

n=$(jget "$C" 'len(d.get("deploy_steps") or [])')
[[ "$n" -gt 0 ]] || { log INFO "no deploy steps in contract"; exit 0; }

for ((i = 0; i < n; i++)); do
  step=$(jget "$C" "d['deploy_steps'][$i]")
  kind=$(jget "$step" 'd["kind"]'); app=$(jget "$step" 'd["app"]')
  [[ -z "$ONLY" || "$ONLY" == "$app" ]] || continue
  name=$(jget "$step" 'd.get("name") or ""'); rg=$(jget "$step" 'd.get("resource_group") or ""')
  url=$(jget "$step" 'd.get("package_uri") or ""'); sha=$(jget "$step" 'd.get("package_sha256") or ""')
  slot=$(jget "$step" 'd.get("slot") or ""')
  log INFO "step $kind $app ($name)"
  pkg="$WORK/$app.zip"
  case "$kind" in
    webapp-zip)
      fetch_package "$url" "$sha" "$pkg"
      args=(--resource-group "$rg" --name "$name" --src-path "$pkg" --type zip --async false --only-show-errors)
      [[ -n "$slot" ]] && args+=(--slot "$slot")
      az webapp deploy "${args[@]}" >/dev/null
      if [[ -n "$slot" ]]; then
        host=$(az webapp show -g "$rg" -n "$name" --slot "$slot" --query defaultHostName -o tsv)
        if poll_http "https://$host/healthz" 18 10; then
          log INFO "staging slot healthy"
        else
          log WARNING "staging slot not reachable from this agent (private endpoint?) - relying on App Service health check"
        fi
        if [[ $SWAP == 1 ]]; then
          az webapp deployment slot swap -g "$rg" -n "$name" --slot "$slot" --target-slot production --only-show-errors
          log INFO "swapped $slot -> production (rollback: run the same swap again)"
        fi
      fi
      ;;
    functionapp-flex)
      fetch_package "$url" "$sha" "$pkg"
      az functionapp deployment config show -g "$rg" -n "$name" --query "storage.value" -o tsv >/dev/null \
        || die "Flex deployment storage not configured on $name"
      az functionapp deployment source config-zip -g "$rg" -n "$name" --src "$pkg" --only-show-errors >/dev/null
      ;;
    logicapp-zip)
      fetch_package "$url" "$sha" "$pkg"
      az logicapp deployment source config-zip -g "$rg" -n "$name" --src "$pkg" --only-show-errors >/dev/null
      ;;
    swa)
      "$HERE/deploy-swa.sh" --contract "$SRC"
      ;;
    vmss-update-instances)
      az vmss update-instances -g "$rg" -n "$name" --instance-ids '*' --only-show-errors
      ;;
    vmss-flex-rollout)
      [[ -n "$ROOT" ]] || die "vmss-flex-rollout needs --root <terraform root> for the vmss_rollout_script output"
      terraform -chdir="$ROOT" output -raw vmss_rollout_script > "$WORK/rollout.sh"
      for vm in $(az vmss list-instances -g "$rg" -n "$name" --query "[].name" -o tsv); do
        log INFO "run-command on $vm"
        az vm run-command invoke -g "$rg" -n "$vm" --command-id RunShellScript --scripts @"$WORK/rollout.sh" \
          --query "value[0].message" -o tsv | tail -5
      done
      ;;
    batch-job)
      "$HERE/../jobs/scripts/submit-batch-job.sh" --contract <(echo "$C")
      ;;
    *) die "unknown deploy step kind $kind" ;;
  esac
  log INFO "step $kind $app done"
done
