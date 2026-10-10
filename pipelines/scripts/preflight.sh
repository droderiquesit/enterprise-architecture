#!/usr/bin/env bash
# Agent pre-flight (self-hosted deploy agents): fail fast with a CLASSIFIED error instead of a confusing
# Terraform/az failure minutes later. Run at the start of every credentialed step (sourced by tf-env.sh).
#
#   preflight.sh [--no-az]
#
# Checks: free disk on the work and temp directories (PREFLIGHT_MIN_DISK_MB, default 4096); DNS of Entra ID,
# ARM, the Delinea DSV tenant (environments/<env>/environment.yaml secrets), the state storage account and the
# container registry (CONTAINER_REGISTRY, optional); `az account show` (the AzureCLI task's login).
# Failure lines: "PREFLIGHT_FAIL class=<disk|dns|auth> ..." + ##vso error; exit 1 (never retried: the agent is broken,
# not the cloud). PREFLIGHT=skip disables it (local runs).
set -uo pipefail
[[ "${PREFLIGHT:-}" == "skip" ]] && exit 0
check_az=1; [[ "${1:-}" == "--no-az" ]] && check_az=0
fail=0
report() { echo "PREFLIGHT_FAIL class=$1 $2"; echo "##vso[task.logissue type=error]pre-flight ($1): $2"; fail=1; }
min_mb="${PREFLIGHT_MIN_DISK_MB:-4096}"
for d in "${AGENT_WORKFOLDER:-$PWD}" "${AGENT_TEMPDIRECTORY:-${TMPDIR:-/tmp}}"; do
  [[ -d "$d" ]] || continue
  free_mb=$(df -Pk "$d" | awk 'NR==2 {print int($4/1024)}')
  if [[ -n "$free_mb" && "$free_mb" -lt "$min_mb" ]]; then report disk "$d has ${free_mb} MB free (< ${min_mb} MB)"; fi
done
hosts=(login.microsoftonline.com management.azure.com)
if [[ -n "${LAB_ENV:-}" && -f "environments/${LAB_ENV}/environment.yaml" ]]; then
  dsv="$(python3 - "environments/${LAB_ENV}/environment.yaml" <<'PY' 2>/dev/null
import sys, urllib.parse, yaml
s = (yaml.safe_load(open(sys.argv[1])) or {}).get("secrets") or {}
url = s.get("base_url") or (f"https://{s['tenant']}.secretsvaultcloud.{s.get('tld') or 'com'}/v1" if s.get("tenant") else "")
print(urllib.parse.urlparse(url).hostname or "")
PY
)"
  [[ -n "$dsv" ]] && hosts+=("$dsv")
fi
[[ -n "${STATE_STORAGE_ACCOUNT:-}" ]] && hosts+=("${STATE_STORAGE_ACCOUNT}.blob.core.windows.net")
[[ -n "${CONTAINER_REGISTRY:-}" ]] && hosts+=("${CONTAINER_REGISTRY%%/*}")
for h in "${hosts[@]}"; do
  getent hosts "$h" >/dev/null 2>&1 || report dns "cannot resolve $h (agent DNS / private DNS zone link)"
done
if [[ $check_az == 1 ]] && command -v az >/dev/null; then
  az account show --only-show-errors -o none 2>/dev/null || report auth "az account show failed (service connection / workload identity login)"
fi
if [[ $fail == 0 ]]; then echo "pre-flight ok (disk >= ${min_mb} MB, ${#hosts[@]} hosts resolved$([[ $check_az == 1 ]] && echo ', az logged in'))"; fi
exit $fail
