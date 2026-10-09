#!/usr/bin/env bash
# Apply the hello-catalog-api manifests rendered by this root to the ARO cluster (pipeline step; Terraform only renders):
#
#   deploy-aro.sh --contract <deploy-specialized contract JSON> [--resource-group <aro rg> --cluster <name>]
#
# Login: `az aro list-credentials` is NOT used (kubeadmin); the pipeline logs in with an OpenShift token for a
# service account / Entra-integrated identity provided in OC_TOKEN. Rollout status is waited for (bounded).
set -euo pipefail
CONTRACT=""
while [[ $# -gt 0 ]]; do case "$1" in --contract) CONTRACT="$2"; shift 2 ;; *) shift ;; esac; done
[[ -f "$CONTRACT" ]] || { echo "usage: $0 --contract <file>" >&2; exit 2; }
get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d=d.get("data",d); d=d.get("value",d)
for k in sys.argv[2].split("."): d=(d or {}).get(k)
print("" if d is None else d)' "$CONTRACT" "$1"; }
API=$(get aro.api_server); NS=$(get aro.namespace)
[[ -n "$API" ]] || { echo "ARO disabled in contract - nothing to do"; exit 0; }
: "${OC_TOKEN:?OC_TOKEN (service account token) required}"
oc login --server "$API" --token "$OC_TOKEN" >/dev/null
oc get namespace "$NS" >/dev/null 2>&1 || oc create namespace "$NS"
get aro.manifests | oc apply -f -
oc -n "$NS" rollout status deployment/hello-catalog-api --timeout=300s
