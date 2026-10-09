# Runbook: quarantined component (pipeline circuit breaker)

A component is **quarantined** when it failed `self_healing.max_consecutive_failures` runs in a row (dev/test 3,
prod 2; failed, partial, canceled and rolled_back all count). `tools/deploy/record.py` then writes
`status: quarantined` with `quarantine.reason`, `last_status` and the last 10 results under `history`, and the
pipeline alerts (Azure Boards work item and/or Datadog event per `self_healing.notify`).

## Effect

* heal runs, deploy runs (for the same deploy fingerprint), reconcile and drift remediation skip it - the selection
  shows `held: quarantined` in its reason; consumers are not re-planned because of it;
* everything else keeps deploying; the run summary and `pipeline.heal.quarantined` show it until it is cleared.

## Triage

1. Read the record: `python3 tools/deploy/record.py show --env <env> --component <id> --store
   https://<state account>.blob.core.windows.net/deployments` (`quarantine.reason`, `history[].note`).
2. Open the failing runs (`history[].run_id`), plan summaries and `health-*` artifacts (`retries.jsonl` shows whether
   the failures were permanent - authorization, quota, policy - or transient ones that exhausted their budget).
3. Fix the cause: code/config change, RBAC, quota, policy exemption, or Azure incident over.

## Clear it

* **Push a fix** that changes the component (any deploy-fingerprint change): the next deploy run selects it again.
* Or queue **`mode: manual`, `components: <id>`** (no code change needed, e.g. after a quota increase). A succeeded
  run resets `consecutive_failures` to 0 and removes the quarantine; a failed one re-quarantines immediately (the
  counter is not reset by the manual run itself).
* Close the work item with a link to the fixing run.

Never edit the record by hand to clear a quarantine; the record is the audit trail.
