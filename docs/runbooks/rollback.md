# Runbook: rollback

Two kinds of rollback, handled differently:

* **Application rollback** - redeploy a previous immutable artifact (image digest or package sha256) or switch traffic
  back to a previous revision/slot. Fast, no data change.
* **Infrastructure rollback** - a **reviewed change**: revert the commit (or settings) and let the pipeline plan and
  apply it with approvals. Never run a blind `terraform destroy`/re-create and **never reverse a database migration
  automatically**: schema migrations in this repo are forward-only and idempotent (orders `0001_orders_schema.sql`,
  durable `0001_fulfillment_schema.sql`, catalog `catalog.schema_migrations`); previous application versions must be
  compatible with the current schema, and a data fix is a new, reviewed forward migration.

None of these procedures has been run against Azure.

## Find the previous version

* Deployment record `deployments/<env>/<component>.json` (state account) holds the commit and artifact digests of the
  last successful apply; `evidence/<env>/runs/<build id>/evidence.json` lists per-run component status.
* Images are pushed **by digest**; packages are stored by sha256 in the `packages` container. Deployment roots reject
  image tags (`<registry>/<repo>@sha256:<64 hex>` validation).

## Pipeline path (preferred)

1. `git revert <bad commit>` (or restore the previous `environments/<env>/environment.yaml` values) -> PR -> main.
2. The deploy-mode run selects the affected components (fingerprints differ from records), plans, and applies after the
   `lab-<env>` approval. Protected resource deletions/replacements are blocked by `tools/validate/plan_policy.py` unless
   `environments/<env>/approvals.yaml` has an unexpired `allow_destroy` entry.
3. For an artifact-only rollback without a code revert, run **manual** mode for the deployment root with the previous
   artifact (the root redeploys whatever digest `tools/deploy/artifacts.py` resolves for the commit being built).

## Per architecture (from `catalog/architecture-matrix.yaml` and the deployment READMEs)

| Architecture | Root | Rollback |
|---|---|---|
| AKS | `deploy-core-aks` | re-apply previous image digests (RollingUpdate, `maxUnavailable 0`, readiness-gated). Break-glass: `kubectl rollout undo deployment/<svc> -n hello` (then reconcile via the pipeline, otherwise the next apply rolls forward) |
| Container Apps | `deploy-core-aca` | multiple revision mode: `components.deploy-core-aca.traffic.<svc> = {latest_weight = 0, previous_revision_suffix = "<last good>"}` and apply (canary 90/10 possible); or re-apply the previous digest. `deploy-dbadapters` ACA apps: single revision -> previous digest |
| Container Apps jobs | `deploy-jobs` | previous image digest |
| Container Instances | `deploy-partner-sim` | re-apply with the previous digest (group recreated, single instance -> brief outage) |
| App Service (Windows code, inventory-api) | `deploy-appservice` | `az webapp deployment slot swap --slot staging` again - the previous build sits in `staging` after a swap |
| App Service (Linux code, mysql adapter) | `deploy-dbadapters` | staging slot swap back (Standard+ SKUs) else redeploy the previous zip |
| App Service containers | `deploy-appservice` | slot swap / previous digest |
| Functions Flex (hello-durable) | `deploy-durable` | **no slots on Flex**: redeploy the previous package (`deploy-zip.sh`). In-flight orchestrations replay with the new code - keep orchestrator changes replay-compatible |
| Functions Windows Consumption (Reconciliation) | `deploy-durable` | re-apply with the previous artifact (`WEBSITE_RUN_FROM_PACKAGE` URL) |
| Functions Premium / Dedicated | `deploy-functions` | re-apply with the previous svc-functions package URL |
| Functions on Container Apps | `deploy-functions` | previous digest |
| Static Web Apps | `deploy-frontend` | re-run `deploy-swa.sh` with the previous svc-frontend package |
| Logic Apps Consumption | `deploy-logicapps` | re-apply the previous commit (definition is Terraform-managed) |
| Logic Apps Standard | `deploy-logicapps` | redeploy the previous zip |
| Linux VM (hello-worker) | `deploy-vm-workloads` | run command installs the previous package; on the host `install.sh --rollback` (3 releases kept; failed health checks roll back automatically) |
| Windows VM (inventory service) | `deploy-vm-workloads` | re-apply with the previous package |
| VMSS Flexible | `deploy-vm-workloads` | re-run `deploy-zip.sh` (`vmss-flex-rollout`) with the previous package |
| VMSS Uniform (sqlvm adapter) | `deploy-dbadapters` | previous package version -> model update + `az vmss update-instances` (Manual upgrade policy) |
| Azure Batch | `deploy-jobs` | `submit-batch-job.sh` with the previous package |
| Service Fabric | `deploy-specialized` | `sfctl application upgrade` to the previous type version (monitored upgrade, `FailureAction=Rollback`) |
| ARO | `deploy-specialized` | `oc rollout undo` or re-apply the previous digest |
| Automation runbook | `deploy-specialized` | re-apply the previous commit |
| Observability content | `obs-monitoring` / package | re-vendor previous package version or `git revert` the rendered onboarding commit, plan, apply (monitor IDs stable when keys unchanged) |

## Infrastructure specifics

* **Plans are bound** to commit, config, contracts and artifacts (`manifest.json`); an apply refuses a stale plan -
  re-run the stage to re-plan.
* **Contracts**: a breaking contract change publishes `v2` next to `v1`; rolling back a producer that already published
  `v2` leaves `v2` in the store - consumers pinned to `v1` are unaffected.
* **State**: a corrupted or wrong state file is restored from blob versioning ([break-glass](break-glass.md)).
* **Secrets (Delinea DSV)**: `dsv secret rollback --path <prefix>/<env>/<name> --version <n>`, then restart consumers ([secret rotation](secret-rotation.md)).
* **Databases**: restore = point-in-time restore into a **new** database/server (SQL PITR 7 days, PostgreSQL 7-day
  backups), validate, then switch the connection settings in a reviewed change. Do not let Terraform replace a database
  to "roll back".
