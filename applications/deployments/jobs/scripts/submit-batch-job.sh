#!/usr/bin/env bash
# Submit the hello-jobs daily-aggregate task to the platform-batch pool (runtime step, not Terraform).
#
#   submit-batch-job.sh --contract <deploy-jobs contract JSON file> [--date YYYY-MM-DD] [--wait-seconds 900]
#
# The contract (terraform output -json contract, or the published envelope's .data) provides batch.account_name,
# account_host, pool_id, job_id, package_uri/package_sha256 and the pool identity (identity_id). The package zip is
# fetched by the Batch node with that user-assigned identity (resourceFiles.identityReference) - no SAS.
# Auth: Microsoft Entra (`az batch account login` with the pipeline identity; needs Batch data-plane rights).
# Idempotent per date: task id = daily-aggregate-<date>; an existing task is reported, not duplicated.
set -euo pipefail

CONTRACT="" ; DATE=$(date -u -d yesterday +%F 2>/dev/null || date -u +%F) ; WAIT=900
while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) CONTRACT="$2"; shift 2 ;;
    --date) DATE="$2"; shift 2 ;;
    --wait-seconds) WAIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -f "$CONTRACT" ]] || { echo "--contract <file> required" >&2; exit 2; }
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "invalid --date" >&2; exit 2; }

jqr() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d=d.get("data",d); d=d.get("value",d)
for k in sys.argv[2].split("."): d=(d or {}).get(k)
print("" if d is None else d)' "$CONTRACT" "$1"; }

ACCOUNT=$(jqr batch.account_name)
[[ -n "$ACCOUNT" ]] || { echo "contract has no batch section (platform-batch not enabled) - nothing to do"; exit 0; }
HOST=$(jqr batch.account_host); POOL=$(jqr batch.pool_id); JOB=$(jqr batch.job_id)
PKG=$(jqr batch.package_uri); SHA=$(jqr batch.package_sha256); IDENTITY=$(jqr batch.identity_id)
[[ -n "$PKG" && -n "$SHA" ]] || { echo "svc-jobs package missing in contract" >&2; exit 1; }

export AZURE_BATCH_ACCOUNT="$ACCOUNT" AZURE_BATCH_ENDPOINT="https://$HOST"
az batch account login --name "$ACCOUNT" --resource-group "$(az batch account list --query "[?name=='$ACCOUNT'].resourceGroup | [0]" -o tsv)" >/dev/null

if ! az batch job show --job-id "$JOB" >/dev/null 2>&1; then
  az batch job create --id "$JOB" --pool-id "$POOL" >/dev/null
  echo "created job $JOB on pool $POOL"
fi

TASK="daily-aggregate-$DATE"
if az batch task show --job-id "$JOB" --task-id "$TASK" >/dev/null 2>&1; then
  echo "task $TASK already exists (idempotent re-run): $(az batch task show --job-id "$JOB" --task-id "$TASK" --query state -o tsv)"
  exit 0
fi

SPEC=$(mktemp); trap 'rm -f "$SPEC"' EXIT
python3 - "$SPEC" "$TASK" "$PKG" "$SHA" "$IDENTITY" "$DATE" <<'PY'
import json, sys
spec, task, pkg, sha, identity, date = sys.argv[1:7]
cmd = ("/bin/bash -c 'set -euo pipefail; echo \"%s  pkg.zip\" | sha256sum -c --status && "
       "python3 -m zipfile -e pkg.zip app && chmod +x app/deploy/batch/run.sh 2>/dev/null || true; "
       "bash app/run.sh daily-aggregate 2>/dev/null || bash app/deploy/batch/run.sh daily-aggregate'") % sha
json.dump({
    "id": task,
    "commandLine": cmd,
    "resourceFiles": [{"httpUrl": pkg, "filePath": "pkg.zip", "identityReference": {"resourceId": identity}}],
    "environmentSettings": [{"name": "AGGREGATE_DATE", "value": date}],
    "constraints": {"maxWallClockTime": "PT30M", "maxTaskRetryCount": 1, "retentionTime": "P7D"},
    "userIdentity": {"autoUser": {"scope": "pool", "elevationLevel": "nonadmin"}},
}, open(spec, "w"))
PY
az batch task create --job-id "$JOB" --json-file "$SPEC" >/dev/null
echo "submitted $TASK"

deadline=$(( $(date +%s) + WAIT ))
while (( $(date +%s) < deadline )); do
  state=$(az batch task show --job-id "$JOB" --task-id "$TASK" --query state -o tsv)
  if [[ "$state" == "completed" ]]; then
    code=$(az batch task show --job-id "$JOB" --task-id "$TASK" --query executionInfo.exitCode -o tsv)
    echo "task $TASK completed exit=$code"; [[ "$code" == "0" ]]; exit $?
  fi
  sleep 15
done
echo "task $TASK not completed within ${WAIT}s" >&2; exit 1
