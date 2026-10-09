# Runbook: Terraform state-lock recovery

The azurerm backend locks `tfstate/<env>/<component>.tfstate` with a blob lease. A run that dies mid-plan/apply
(agent lost, job timeout, cancel during apply) leaves the lease behind and every later run fails with
`Error acquiring the state lock`. The pipelines recover from this themselves when it is provably safe.

## What the pipeline does (`tools/deploy/lock_doctor.py`)

1. Every plan/apply job writes a holder claim `deployments/<env>/_locks/<component>/<build>-<job>-<attempt>.json`
   (build id, job, attempt, stage, start time) and deletes it when the script ends.
2. On a lock error (`tools/deploy/retry_rules.yaml` rule `state-lock`) the doctor reads the lock info (ID, created)
   and the claims of other jobs, and asks Azure DevOps for each holder build's status
   (`GET _apis/build/builds/<id>?api-version=7.1`, System.AccessToken).
3. Decision:
   * holder `notStarted / inProgress / cancelling / postponed` -> **wait** (30 s doubling to 5 min, at most
     `LOCK_MAX_WAIT_MINUTES`, default 30). A lock of a running build is **never** broken.
   * another job of the same run -> wait.
   * holder completed (succeeded / failed / canceled) or an earlier attempt of this same job, and lock older than
     10 min -> **break**.
   * no claim at all (e.g. a local break-glass run) -> break only when older than 400 min (longer than any job
     timeout); unknown holder status -> wait until then.
4. Break: `terraform force-unlock -force <ID>`, falling back to
   `az storage blob lease break --container-name tfstate --blob-name <env>/<component>.tfstate --auth-mode login`;
   audit record `deployments/<env>/_audit/lock-recovery-<component>-<ts>.json` (who, why, holder) and a
   `lock-broken` health event (`pipeline.heal.lock_recoveries`). Terraform then retries.

## Manual procedure (when the pipeline waited and gave up)

1. Find the holder: `python3 tools/deploy/lock_doctor.py inspect --env <env> --component <id> --store
   https://<state account>.blob.core.windows.net/deployments` and the `Who`/`Created` lines of the error.
2. Open the holder build. If it is running, **wait or cancel it** - never break its lock.
3. If it is finished: `terraform -chdir=<root> force-unlock <ID>` from a break-glass session (bootstrap role), or
   `az storage blob lease break --account-name <acct> --container-name tfstate --blob-name <env>/<id>.tfstate --auth-mode login`.
4. Re-run the component (`mode: manual`); the apply re-plans against the current state. Note the action in the change log.

## Alert

A Datadog monitor on `pipeline.heal.lock_recoveries` (more than 3 per day) points at dying agents or timeouts that
are too short - check `foundation-deploy-agents` health and the component `timeout_minutes`.
