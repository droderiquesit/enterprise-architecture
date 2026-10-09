#!/usr/bin/env bash
# Upload hello-frontend to Azure Static Web Apps (deploy-frontend contract):
#
#   deploy-swa.sh --contract <deploy-frontend contract | envelope | root dir> [--bundle <dir>]
#
# 1. bundle: --bundle <dist dir>, else the svc-frontend package from the contract (Entra download + sha256 check)
# 2. writes the runtime files rendered by Terraform (config.json, staticwebapp.config.json, version.json,
#    healthz.json) into the bundle - config.json carries apiBaseUrl + RUM settings (browser-safe client token)
# 3. fetches the deployment token at deploy time (`az staticwebapp secrets list`), never stored or echoed
# 4. uploads with the SWA CLI (`npx @azure/static-web-apps-cli@2.0.7 deploy --env production`)
# Rollback: re-run with the previous svc-frontend package.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LOGGER=deploy-swa
# shellcheck source=lib.sh
source "$HERE/lib.sh"

SRC="" ; BUNDLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) SRC="$2"; shift 2 ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ -n "$SRC" ]] || die "--contract required"
C=$(contract_json "$SRC")
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

name=$(jget "$C" 'd["static_web_app"]["name"]'); rg=$(jget "$C" 'd["resource_group_name"]')
if [[ -z "$BUNDLE" ]]; then
  url=$(jget "$C" 'd["deploy_steps"][0]["package_uri"] or ""'); sha=$(jget "$C" 'd["deploy_steps"][0]["package_sha256"] or ""')
  [[ -n "$url" ]] || die "no svc-frontend package in contract and no --bundle"
  fetch_package "$url" "$sha" "$WORK/bundle.zip"
  mkdir -p "$WORK/dist" && python3 -m zipfile -e "$WORK/bundle.zip" "$WORK/dist"
  BUNDLE="$WORK/dist"
  [[ -f "$BUNDLE/index.html" ]] || { [[ -d "$BUNDLE/dist" ]] && BUNDLE="$BUNDLE/dist"; }
else
  cp -r "$BUNDLE" "$WORK/dist" && BUNDLE="$WORK/dist"
fi
[[ -f "$BUNDLE/index.html" ]] || die "bundle has no index.html"

python3 - "$BUNDLE" "$C" <<'PY'
import json, os, sys
bundle, contract = sys.argv[1], json.loads(sys.argv[2])
for name, content in contract["runtime_files"].items():
    with open(os.path.join(bundle, name), "w") as f:
        f.write(json.dumps(json.loads(content), indent=2) + "\n")
PY
log INFO "runtime files written (apiBaseUrl=$(jget "$C" 'json.loads(d["runtime_files"]["config.json"])["apiBaseUrl"]'))"

TOKEN=$(az staticwebapp secrets list --name "$name" --resource-group "$rg" --query "properties.apiKey" -o tsv)
[[ -n "$TOKEN" ]] || die "could not obtain the SWA deployment token"
SWA_CLI_DEPLOYMENT_TOKEN="$TOKEN" npx --yes @azure/static-web-apps-cli@2.0.7 deploy "$BUNDLE" --env production --no-use-keychain >/dev/null
unset TOKEN
log INFO "deployed $name"
