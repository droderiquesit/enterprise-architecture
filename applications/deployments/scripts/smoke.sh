#!/usr/bin/env bash
# Per-root smoke test from a deployment contract (bounded polling; run from an agent inside the VNet):
#
#   smoke.sh --contract <contract json | envelope | root dir> [--attempts 30] [--interval 10] [--jobs]
#
# For every apps.<key> with a url: GET url+health_path, url+readiness_path and url+version_path (each optional)
# until HTTP 200. AKS in-cluster URLs (*.svc.cluster.local) are probed through
# `az aks command invoke` (no kubeconfig). --jobs also starts the manual `seed` Container Apps job and waits for
# Succeeded. Exit 1 when any probe fails. Writes a JSON summary to stdout.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LOGGER=smoke
# shellcheck source=lib.sh
source "$HERE/lib.sh"

SRC="" ; ATTEMPTS=30 ; INTERVAL=10 ; JOBS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) SRC="$2"; shift 2 ;;
    --attempts) ATTEMPTS="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --jobs) JOBS=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ -n "$SRC" ]] || die "--contract required"
C=$(contract_json "$SRC")
results=() ; failed=0

probe() {  # probe <app> <url>
  local url="$2" i
  if [[ "$url" == *".svc.cluster.local"* ]]; then
    local cluster rg
    cluster=$(jget "$C" 'd["cluster_id"].split("/")[-1]'); rg=$(jget "$C" 'd["cluster_id"].split("/")[4]')
    for ((i = 1; i <= ATTEMPTS; i++)); do
      if az aks command invoke -g "$rg" -n "$cluster" --command "curl -fsS --max-time 5 $url" -o none 2>/dev/null; then return 0; fi
      sleep "$INTERVAL"
    done
    return 1
  fi
  poll_http "$url" "$ATTEMPTS" "$INTERVAL"
}

for app in $(jget "$C" '" ".join(k for k, a in (d.get("apps") or {}).items() if a.get("url"))'); do
  base=$(jget "$C" "d['apps']['$app']['url']")
  for key in health_path readiness_path version_path; do
    path=$(jget "$C" "d['apps']['$app'].get('$key') or ''")
    [[ -n "$path" ]] || continue
    if probe "$app" "${base%/}$path"; then
      results+=("{\"app\":\"$app\",\"url\":\"${base%/}$path\",\"ok\":true}")
    else
      results+=("{\"app\":\"$app\",\"url\":\"${base%/}$path\",\"ok\":false}"); failed=1
      log ERROR "$app ${base%/}$path failed"
    fi
  done
done

if [[ $JOBS == 1 ]]; then
  seed=$(jget "$C" '(d.get("jobs") or {}).get("seed", {}).get("id", "")')
  if [[ -n "$seed" ]]; then
    exec_name=$(az containerapp job start --ids "$seed" --query name -o tsv)
    status=""
    for ((i = 1; i <= ATTEMPTS; i++)); do
      status=$(az containerapp job execution show --ids "$seed" --job-execution-name "$exec_name" --query properties.status -o tsv 2>/dev/null || true)
      [[ "$status" == "Succeeded" || "$status" == "Failed" ]] && break
      sleep "$INTERVAL"
    done
    ok=$([[ "$status" == "Succeeded" ]] && echo true || echo false)
    results+=("{\"app\":\"job-seed\",\"execution\":\"$exec_name\",\"status\":\"$status\",\"ok\":$ok}")
    [[ "$ok" == true ]] || failed=1
  fi
fi

printf '{"component":"%s","ok":%s,"probes":[%s]}\n' "$(jget "$C" 'd.get("component","")')" "$([[ $failed == 0 ]] && echo true || echo false)" "$(IFS=,; echo "${results[*]:-}")"
exit $failed
