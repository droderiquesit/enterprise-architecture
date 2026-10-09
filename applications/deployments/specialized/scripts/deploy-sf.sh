#!/usr/bin/env bash
# Deploy hello-inventory-api as a Service Fabric guest executable to the platform-servicefabric managed cluster.
# azurerm has no Service Fabric application resources, so this is a pipeline step (sfctl):
#
#   deploy-sf.sh --contract <deploy-specialized contract JSON> --cert-pem <client cert PEM file>
#
# The client certificate (admin client of the managed cluster) is downloaded from Key Vault by the pipeline at
# deploy time (`az keyvault secret download ... --encoding base64` -> PEM) and deleted afterwards; it is never stored
# in Terraform state or contracts. Upgrade is monitored with automatic rollback (FailureAction=Rollback).
set -euo pipefail
CONTRACT="" ; CERT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) CONTRACT="$2"; shift 2 ;;
    --cert-pem) CERT="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -f "$CONTRACT" && -f "$CERT" ]] || { echo "usage: $0 --contract <file> --cert-pem <pem>" >&2; exit 2; }
get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d=d.get("data",d); d=d.get("value",d)
for k in sys.argv[2].split("."): d=(d or {}).get(k)
print("" if d is None else d)' "$CONTRACT" "$1"; }

HOST=$(get service_fabric.management_host)
[[ -n "$HOST" ]] || { echo "service fabric disabled in contract - nothing to do"; exit 0; }
TYPE=$(get service_fabric.application_type); VER=$(get service_fabric.application_version)
NAME=$(get service_fabric.application_name); PKG=$(get service_fabric.package_uri); SHA=$(get service_fabric.package_sha256)

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
APPDIR="$WORK/HelloInventoryApp"; mkdir -p "$APPDIR/InventoryApiPkg/Code"
get service_fabric.application_manifest > "$APPDIR/ApplicationManifest.xml"
get service_fabric.service_manifest > "$APPDIR/InventoryApiPkg/ServiceManifest.xml"
ACCOUNT=$(sed -E 's#https://([^.]+)\..*#\1#' <<<"$PKG"); CONTAINER=$(cut -d/ -f4 <<<"$PKG"); BLOB=$(cut -d/ -f5- <<<"$PKG")
az storage blob download --auth-mode login --account-name "$ACCOUNT" --container-name "$CONTAINER" --name "$BLOB" --file "$WORK/pkg.zip" --only-show-errors >/dev/null
echo "$SHA  $WORK/pkg.zip" | sha256sum -c --status
python3 -m zipfile -e "$WORK/pkg.zip" "$APPDIR/InventoryApiPkg/Code"

sfctl cluster select --endpoint "https://$HOST" --pem "$CERT" --no-verify
sfctl application upload --path "$APPDIR" --show-progress
sfctl application provision --application-type-build-path HelloInventoryApp
if sfctl application info --application-id "${NAME#fabric:/}" >/dev/null 2>&1; then
  sfctl application upgrade --app-id "${NAME#fabric:/}" --app-version "$VER" --parameters "{}" --mode Monitored --failure-action Rollback
else
  sfctl application create --app-name "$NAME" --app-type "$TYPE" --app-version "$VER"
fi
echo "deployed $TYPE $VER to $HOST"
