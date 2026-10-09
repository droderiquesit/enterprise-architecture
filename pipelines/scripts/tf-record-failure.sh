#!/usr/bin/env bash
# Record a non-succeeded deployment so the next run re-selects the component (resumability).
# Usage: tf-record-failure.sh <component-id> <agent job status>
# Env: LAB_ENV, STATE_STORAGE_ACCOUNT (paths/URLs derived by pipeline-env.sh)
set -euo pipefail
source pipelines/scripts/pipeline-env.sh
component="$1"; job_status="${2:-Failed}"
status=failed
if [[ "$job_status" == "Canceled" ]]; then status=canceled; fi
if [[ -f "${APPLIED_MARKER:-/nonexistent}" ]]; then status=partial; fi
python3 tools/deploy/record.py write --env "$LAB_ENV" --component "$component" --status "$status" \
  --selection "$SELECTION_FILE" --store "$RECORDS_URL" --note "Agent.JobStatus=${job_status}"
