#!/usr/bin/env bash
# Record a non-succeeded deployment so the next run re-selects the component (resumability), and run the circuit
# breaker: tools/deploy/record.py quarantines a component after self_healing.max_consecutive_failures failures in a
# row (default 3) and this script alerts (Boards work item / Datadog event, pipelines/scripts/alert.sh).
# Usage: tf-record-failure.sh <component-id> <agent job status> [plan|apply]
# Env: LAB_ENV, STATE_STORAGE_ACCOUNT (paths/URLs derived by pipeline-env.sh), ROLLBACK_MARKER
set -euo pipefail
source pipelines/scripts/pipeline-env.sh
component="$1"; job_status="${2:-Failed}"; phase="${3:-apply}"
if [[ "$phase" == "plan" && ( "${APPLY_CANDIDATE:-false}" != "true" || "${DRY_RUN,,}" == "true" ) ]]; then
  echo "plan failure of a non-apply candidate / dry run: not recorded"; exit 0
fi
rollback_marker="${ROLLBACK_MARKER:-${AGENT_TEMPDIRECTORY:-/tmp}/rolled-back}"
status=failed; note="Agent.JobStatus=${job_status} (${phase})"
if [[ "$job_status" == "Canceled" ]]; then status=canceled; fi
if [[ -f "${APPLIED_MARKER:-/nonexistent}" ]]; then status=partial; fi
if [[ -f "$rollback_marker" ]]; then status=rolled_back; note="code deploy/smoke failed; $(cat "$rollback_marker")"; fi
out="$(python3 tools/deploy/record.py write --env "$LAB_ENV" --component "$component" --status "$status" \
  --selection "$SELECTION_FILE" --store "$RECORDS_URL" --note "$note")"
echo "$out"
if grep -q '^QUARANTINED$' <<<"$out"; then
  bash pipelines/scripts/alert.sh "$component" quarantine \
    "$(grep -m1 'QUARANTINED:' <<<"$out" | sed 's/.*QUARANTINED: //') - heal runs stop selecting it; see docs/runbooks/quarantine.md"
elif [[ "$status" == "rolled_back" ]]; then
  bash pipelines/scripts/alert.sh "$component" rolled-back "$note"
fi
