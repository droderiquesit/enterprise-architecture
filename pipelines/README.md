# Universal Azure DevOps pipeline

`azure-pipelines.yml` deploys **only the components that changed, plus what they need**, for one lab
environment. The component registry (`catalog/components.yaml`) is the single source of truth for
change detection, dependency order, state boundaries and the generated stages.

Status of this pipeline (ADR-0001 §11 vocabulary): **implemented** — YAML, templates and tools pass
the repository's static checks and unit tests (`tests/changeset`, `tests/pipeline`, `tests/tools`).
It has **not** been run in an Azure DevOps organisation from this repository; nothing has been
deployed by it. First-run setup is described below.

## How it works

```
Select ──> Validate ──┐
       └─> Security ──┴─> Build ─> C_<component> stages (generated) ─> Retire ─> Verify / Drift ─> Evidence
```

| Stage | Agent | Credentials | What it does |
|---|---|---|---|
| Select | hosted (PR) / `deployPool` | none (PR) / plan identity (read records) | validates registry + graph + environment config, runs `python3 -m tools.changeset select`, publishes `selection.json`, sets output variables |
| Validate | Microsoft-hosted | **none** | matrix over selected components (`tools/validate/component.py`: Terraform fmt/init -backend=false/validate/test, unit tests), tooling tests, pipeline lint, ownership + version checks, generated-file check |
| Security | Microsoft-hosted | **none** | gitleaks, trivy (fs), checkov, installed in-job at pinned versions with checksum verification |
| Build | `deployPool` | build identity | one job per artifact: reuse the image/package tagged with the artifact's source fingerprint, else build + push **by digest** (BuildKit provenance + SBOM, syft SPDX file, build metadata JSON) |
| C_&lt;id&gt; | `deployPool` | plan identity, then apply identity | **Plan** job (render config, materialize contracts, artifact digests, `terraform plan -detailed-exitcode`, plan policy, binding manifest, plan file to the protected `plans` container) → **Apply** deployment job (environment `lab-<env>`, approvals; only when the plan has changes; verifies the binding manifest; applies; publishes the contract; writes the deployment record) |
| Retire | `deployPool` | apply identity | destroys approved retirements, consumers first (environment `lab-<env>-retire`) |
| Verify | `deployPool` | plan identity + Datadog keys | HTTP smoke (`tools/smoke`) + telemetry verification (`observability/tools/verify/telemetry_verify.py`) |
| Drift | `deployPool` | none | drift report (drift mode) |
| Evidence | `deployPool` | plan identity + Datadog key | deployment report, `evidence.json`, Datadog DORA deployment events |

### Change detection (`tools/changeset`)

Each component has two fingerprints (sha256):

* `validation_fp` – files under its path, the shared Terraform modules it uses (discovered from
  `source = "../..."`, recursively), its `inputs` globs, tests and docs.
* `deploy_fp` – the same **without** tests/docs/README/`*.md`, plus: its rendered configuration
  (`tools/config`; only its own settings and the globals it declares), the relevant
  `versions.yaml` section, the major versions of the contracts it consumes, its registry entry and –
  for deployment roots – the source fingerprints of its artifacts.

| Mode | Trigger | Selection |
|---|---|---|
| `pr` | branch-policy build (`Build.Reason == PullRequest`) | `git diff -M merge-base(origin/<target>, HEAD)..HEAD` (+ base/head fingerprint comparison); validate changed components and the transitive consumers of infrastructure changes. No plans, no credentials. |
| `deploy` | CI on `main`, manual `auto` | every enabled component whose `deploy_fp` differs from its record `deployments/<env>/<id>.json`, has no record, or whose record status is not `succeeded`; consumers of infrastructure changes are planned; **apply only when the plan has changes** (exit code 2) |
| `manual` | parameter | listed components (+ their upstream planned without apply; `withConsumers` adds consumers with apply) |
| `reconcile` | parameter | every enabled component planned, applied where the plan has changes |
| `drift` | nightly schedule (`always: true`) | every enabled component planned, nothing applied, drift report |
| `retire` | parameter | only scheduled retirements |

An artifact-only change (new image of an app) re-deploys the roots that ship that artifact but does
not re-plan their consumers: artifacts never change Terraform contracts. A documentation-only change
selects nothing for deployment.

### Stage conditions

Generated for `C_x` (see `tools/pipeline/generate.py`):

```
and(not(canceled()),
    in(dependencies.Select.result,   'Succeeded', 'SucceededWithIssues'),
    in(dependencies.Validate.result, 'Succeeded', 'SucceededWithIssues'),
    in(dependencies.Security.result, 'Succeeded', 'SucceededWithIssues'),
    eq(dependencies.Select.outputs['select.detect.sel_x'], 'true'),
    eq(dependencies.Build.outputs['B_<artifact>.ready.ready'], 'true'),          # per artifact of x
    or(in(dependencies.C_u.result, 'Succeeded', 'SucceededWithIssues'),
       and(eq(dependencies.C_u.result, 'Skipped'),
           ne(dependencies.Select.outputs['select.detect.sel_u'], 'true'))))     # per transitive upstream u
```

* `dependencies.<stage>.outputs['<job>.<step>.<variable>']` is the documented stage-level syntax
  (Learn: *Expressions → Dependencies*). A custom stage condition replaces the default
  `succeeded()`, so results are checked explicitly; `always()` and `succeededOrFailed()` are never
  used on deploy stages (lint rule PL001).
* An **unselected** upstream (Skipped) does not block; a **failed / canceled** upstream, or a
  **selected** upstream that was skipped because *its* upstream failed, blocks. `dependsOn` lists the
  transitive upstream, so this holds across unselected intermediate stages.
* An unrelated artifact failing in `Build` does not block a root whose own artifacts are ready.
* `tests/pipeline/test_pipeline.py` evaluates these expressions with `tools/pipeline/conditions.py`
  for Succeeded / SucceededWithIssues / Skipped / Failed / Canceled upstreams and simulates whole runs.

### Plans are bound to their inputs

The Plan job writes `manifest.json` {commit, component, env, config_sha, contracts_sha, artifacts_sha,
terraform version + lock-file sha, plan_sha256}. The plan file itself goes to the `plans` blob
container (it can contain secrets) – only the summary and manifest are pipeline artifacts. The Apply
job re-renders everything and refuses to apply on any difference; a contracts difference reports
**"stale plan; re-run"** (re-running the stage re-plans after the upstream).
`tools/validate/plan_policy.py` fails a plan that deletes/replaces a protected resource type
(databases, storage, Key Vault, VNets, registries, clusters, identities…) unless
`environments/<env>/approvals.yaml` has an unexpired `allow_destroy` entry for that component and
address; cost-relevant changes are flagged as warnings.

## Adding a component

1. Add the entry to `catalog/components.yaml` (id, layer, kind, path, `consumes`/`optional_consumes`,
   `produces`, `artifacts`, `inputs`, optional `timeout_minutes`).
2. Enable it in a profile (`environments/profiles/<p>.yaml`) or `custom_components`.
3. Regenerate the stages and commit the result:
   ```
   python3 tools/pipeline/generate.py
   python3 tools/validate/pipeline_lint.py
   python3 -m tools.changeset graph
   ```
   The Validate stage fails while `pipelines/generated/component-stages.yml` is stale.

Interfaces a Terraform root gets from the pipeline:

| File (written next to the root, git-ignored) | Variables |
|---|---|
| `terraform.tfvars.json` (`tools/config/render.py`) | `environment`, `settings` (profile `component_settings.<id>` deep-merged under `environment.yaml components.<id>`), and `network`/`datadog`/`budget`/`features`/`profile_name` **only if the root declares them** |
| `contracts.auto.tfvars.json` (`tools/contracts/materialize.py`) | one variable per consumed contract (`foundation-network` → `foundation_network`) = envelope `data`; `discovered_contracts` for `discovers_resources` roots that declare it |
| `artifacts.auto.tfvars.json` (`tools/deploy/artifacts.py tfvars`) | `artifacts = {<artifact component id> = {name, image, digest, package_url, package_sha256, source_fp, tag}}` when the root declares `variable "artifacts"` |

Roots publish `output "contract"` (one produced contract) or `output "contract_<name>"` (several).
Deployment roots should put their HTTP base URLs under `endpoints = {name = url}` in the contract
so the smoke runner finds them.

## Azure DevOps setup (not expressible in YAML)

1. **Service connections** (Azure Resource Manager → *Workload identity federation*), one per identity
   created by `bootstrap` (issuer `https://login.microsoftonline.com/<tenant>/v2.0`, subject copied
   from the connection – ADR §13):
   `sc-lab-<env>-plan` (Reader + state lease + read contracts/records + write plans),
   `sc-lab-<env>-apply` (Contributor + constrained RBAC admin + write all containers),
   `sc-lab-<env>-build` (AcrPush + write `packages`). Put the names **and ids** in
   `pipelines/variables/<env>.yml` (service connection names must be known at compile time; the ids
   feed `ARM_ADO_PIPELINE_SERVICE_CONNECTION_ID`). Terraform authenticates with
   `ARM_USE_OIDC=true`, `ARM_ADO_PIPELINE_SERVICE_CONNECTION_ID`/`ARM_OIDC_AZURE_SERVICE_CONNECTION_ID`,
   `SYSTEM_ACCESSTOKEN` and `SYSTEM_OIDCREQUESTURI` (azurerm provider and azurerm backend docs), so
   tokens are refreshed during long applies (`pipelines/scripts/tf-env.sh`). Grant each connection to
   this pipeline only.
2. **Environments**: `lab-<env>` (Approvals + **Exclusive lock** check) and `lab-<env>-retire`
   (Approvals by a different group + Exclusive lock). Pipelines → Environments → *lab-dev* → ⋮ →
   *Approvals and checks* → **+** → *Exclusive lock*.
3. **Concurrency.** `lockBehavior: sequential` is set for the whole pipeline (queued runs wait for
   the exclusive lock instead of the default `runLatest` cancelling older runs), and every generated
   component stage sets `lockBehavior: sequential`, which creates a stage-level lock across runs, so
   one component is never planned/applied by two runs at once. Within a run, independent component
   stages run in parallel, bounded by the agent pool size. Note: an exclusive lock check on
   `lab-<env>` serialises every stage that targets it (one Apply at a time); omit the check if
   parallel applies matter more than strict serialisation – the stage locks still prevent the same
   component from running twice. A second run that waited reads records written by the first, plans
   against the new state and applies nothing when there is nothing left to do.
4. **Variable groups**: `lab-<env>-datadog` linked to the environment's Key Vault, secrets
   `datadog-api-key`, `datadog-app-key` (names from `environment.yaml datadog.*_secret_name`). The plan/apply
   templates link it only for `obs-prereqs`, `obs-azure-integration`, `obs-monitoring` (step env `DD_API_KEY` /
   `DD_APP_KEY` for the Datadog provider) and `obs-kubernetes` (step env `TF_VAR_datadog_api_key`, an ephemeral
   variable); no other root sees the keys, and they are never written to disk. Grant the pipeline's plan and apply
   service connections "Use" on the group.
   They reach scripts only through `env:` and are never echoed (lint rule PL009).
5. **Branch policies** (Azure Repos ignores YAML `pr:` triggers): Repos → Branches → `main` →
   Branch policies → *Build validation* → this pipeline, *Required*, trigger *Automatic*, expiry
   *Immediately when main is updated*. PR builds compile only Select/Validate/Security (the
   generated stages are inserted with `${{ if ne(variables['Build.Reason'], 'PullRequest') }}`),
   use Microsoft-hosted agents and reference no service connection, variable group or self-hosted
   pool, so code from a PR never runs with credentials. Plans against real state happen only on
   `main` behind the environment approvals.
6. **Agent pools**: Microsoft-hosted (`ubuntu-24.04`) for Validate/Security/PR Select; the
   self-hosted pool `foundation-deploy-agents` (deployed by `foundation-deploy-agents` into the
   `deploy-agents` subnet) for everything that reaches private endpoints (state storage, Key Vault,
   ACR, smoke tests). Agents need `python3`, `az`, `git`, `docker` (or set `useAcrBuild`), `curl`.
7. **Bootstrap prerequisites**: containers `tfstate`, `contracts`, `plans`, `deployments`,
   `evidence` and **`packages`** (zip packages), plus the role assignments above.

## Operating

* **Retirement.** A component that has a deployment record but is no longer enabled (or no longer in
  the registry) is reported `retire-pending` and never destroyed automatically. To retire it add to
  `environments/<env>/retirements.yaml`:
  ```yaml
  retirements:
    - component: platform-db-mysql
      confirm: platform-db-mysql        # must repeat the id
      approved_by: lead@example.com
      reason: profile change
  ```
  The next run schedules it (`retire-scheduled`) unless an enabled component still depends on it
  (`retire-blocked`); the Retire stage destroys scheduled components consumers-first from the commit
  recorded in their deployment record, after the `lab-<env>-retire` approval.
* **Resuming a partial deployment.** Records are written only by a successful apply (or a plan with
  no changes); a failed/partial/canceled apply writes a non-`succeeded` record. Either *Rerun failed
  jobs* on the same run or start a new run: change detection re-selects every component whose
  record is not `succeeded`, and already-applied components plan to no changes.
* **Dry run** (`dryRun: true`): plans only – no Apply/Retire jobs are compiled, no records written.
* **Break-glass.** Run the pipeline in `manual` mode for the component. If the pipeline itself is
  unavailable, an operator with the bootstrap break-glass role can run the same scripts locally:
  `python3 tools/config/render.py`, `python3 tools/contracts/materialize.py --source <contracts url>`,
  `pipelines/scripts/tf-init.sh`, `terraform plan/apply`, then `python3 tools/contracts/publish.py`
  and `python3 tools/deploy/record.py write` so the next pipeline run sees the change.
  Document the action in the change record.
* **Timeouts**: per-job `timeoutInMinutes` from the registry (`timeout_minutes`, default 60);
  `retryCountOnTaskFailure` is used only for idempotent network steps (artifact downloads, tool
  installs, `terraform init`, artifact resolve).

## Files

| Path | Purpose |
|---|---|
| `azure-pipelines.yml` | triggers, runtime parameters, Select/Validate/Security, include of the generated stages |
| `pipelines/generated/component-stages.yml` | GENERATED (Build, C_* stages, Retire, Verify, Drift, Evidence) |
| `pipelines/templates/*.yml` | terraform-plan, terraform-apply, build-artifact, build-dotnet, build-python, build-frontend, container-image, security-scan, validate, smoke, telemetry-verify, deployment-marker, retire, drift, evidence, steps-setup |
| `pipelines/scripts/*.sh` | Terraform env/init/prepare/plan/apply, pinned tool installer |
| `pipelines/variables/` | compile-time per-environment settings and tool versions |
