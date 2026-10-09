#!/usr/bin/env bash
# Install/upgrade hello-catalog-api on ARO with the shared Helm chart (applications/charts/hello-service) and the
# values this root renders into its contract (aro.helm.values). Terraform only renders; this pipeline step deploys.
#
#   deploy-aro.sh --contract <deploy-specialized contract JSON> [--chart <path|oci://...>] [--chart-version <semver>]
#                 [--timeout 10m] [--dry-run]
#
# Prerequisites
#   - helm >= 3.17 (Helm 4 preferred; the pinned CLI is reported in versions.yaml by the pipeline) and oc on PATH.
#   - OpenShift login: `az aro list-credentials` (kubeadmin) is NOT used. The pipeline provides OC_TOKEN, a token of
#     a deployer service account (or an Entra-integrated identity) with edit rights on the namespace; this script runs
#     `oc login --server <api> --token $OC_TOKEN`, which writes the kubeconfig helm uses. With --dry-run and no
#     OC_TOKEN the chart is only rendered locally (helm template) - no cluster access.
#   - Secrets referenced by settings.aro_secret_env (e.g. hello-catalog-api-db / password) exist in the namespace.
#   - OCI chart (--chart oci://<acr>/helm/hello-service): `helm registry login` done by the pipeline beforehand.
#
# Rollback: the upgrade rolls back automatically on failure (--rollback-on-failure / --atomic). Manual:
#   helm -n <ns> history hello-catalog-api ; helm -n <ns> rollback hello-catalog-api <revision> --wait
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT="" CHART="$HERE/../../../charts/hello-service" CHART_VERSION="" TIMEOUT="10m" DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) CONTRACT="$2"; shift 2 ;;
    --chart) CHART="$2"; shift 2 ;;
    --chart-version) CHART_VERSION="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -f "$CONTRACT" ]] || { echo "usage: $0 --contract <file> [--chart <path|oci://...>] [--chart-version <v>] [--dry-run]" >&2; exit 2; }
get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d=d.get("data",d); d=d.get("value",d)
for k in sys.argv[2].split("."): d=(d or {}).get(k)
print("" if d is None else d)' "$CONTRACT" "$1"; }

API=$(get aro.api_server); NS=$(get aro.namespace); RELEASE=$(get aro.helm.release)
[[ -n "$API" ]] || { echo "ARO disabled in contract - nothing to do"; exit 0; }
STATUS=$(get status.aro)
[[ "$STATUS" == "implemented" ]] || { echo "ARO not deployable: $STATUS" >&2; exit 1; }
RELEASE=${RELEASE:-hello-catalog-api}

VALUES=$(mktemp); trap 'rm -f "$VALUES"' EXIT
get aro.helm.values > "$VALUES"
VERSION_ARGS=(); [[ -n "$CHART_VERSION" ]] && VERSION_ARGS=(--version "$CHART_VERSION")

if [[ "$DRY_RUN" == 1 && -z "${OC_TOKEN:-}" ]]; then
  helm template "$RELEASE" "$CHART" "${VERSION_ARGS[@]}" -n "$NS" -f "$VALUES" >/dev/null
  echo "dry-run: chart rendered for $RELEASE in namespace $NS (no cluster access)"; exit 0
fi

: "${OC_TOKEN:?OC_TOKEN (deployer service account token) required}"
oc login --server "$API" --token "$OC_TOKEN" >/dev/null
oc get namespace "$NS" >/dev/null 2>&1 || oc new-project "$NS" >/dev/null

# Helm 4 renamed --atomic to --rollback-on-failure (the old flag is deprecated).
case "$(helm version --template '{{.Version}}')" in
  v3.*) SAFE=(--atomic --cleanup-on-fail) ;;
  *)    SAFE=(--rollback-on-failure --cleanup-on-fail) ;;
esac
DRY=(); [[ "$DRY_RUN" == 1 ]] && DRY=(--dry-run=server)

helm upgrade --install "$RELEASE" "$CHART" "${VERSION_ARGS[@]}" \
  --namespace "$NS" -f "$VALUES" \
  "${SAFE[@]}" --wait --timeout "$TIMEOUT" --history-max 10 "${DRY[@]}"
[[ "$DRY_RUN" == 1 ]] || helm -n "$NS" status "$RELEASE"
