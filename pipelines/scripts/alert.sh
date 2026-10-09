#!/usr/bin/env bash
# alert.sh <component> <kind> <reason>: self-healing alert (tools/report/ci_metrics.py alert) - Azure Boards work item
# and/or Datadog event per environments/<env>/environment.yaml self_healing.notify. The Datadog key is fetched from
# Delinea DSV into the alert process only (optional: without DSV access the work item / log line still happen).
# Alerts never fail the calling step. Env: LAB_ENV, DD_SITE (optional), SYSTEM_ACCESSTOKEN (work items).
set -uo pipefail
component="$1"; kind="$2"; reason="$3"
args=(alert --env "$LAB_ENV" --component "$component" --kind "$kind" --reason "$reason" --site "${DD_SITE:-}")
python3 tools/secrets/fetch.py exec --env "$LAB_ENV" --map 'DD_API_KEY=datadog-api-key?' -- python3 tools/report/ci_metrics.py "${args[@]}" \
  || python3 tools/report/ci_metrics.py "${args[@]}" \
  || echo "##vso[task.logissue type=warning]alert for $component ($kind) could not be sent"
exit 0
