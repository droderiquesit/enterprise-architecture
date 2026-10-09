# Delivery: operator guide

Two Azure DevOps pipelines deploy **only the components that changed, plus what they need**, to the lab
environments. Both are thin entry files that `extends:` the same governed template,
[`pipelines/templates/universal.yml`](templates/universal.yml):

| Pipeline (ADO definition name) | Entry file | Scope | Runs when |
|---|---|---|---|
| `lab-platform` | [`azure-pipelines.yml`](../azure-pipelines.yml) | IaC platform: `foundation-*`, `platform-*`, observability infrastructure (`obs-prereqs`, `obs-azure-integration`, `obs-telemetry-transport`, `obs-kubernetes`, `obs-dbm`) | push to `main` (dev), PR build validation, nightly 02:17 UTC drift (dev), manual runs (any environment / mode); tag `observability-v<semver>` = observability package release only |
| `lab-applications` | [`azure-pipelines.applications.yml`](../azure-pipelines.applications.yml) | artifacts (`svc-*`), Helm charts, `deploy-*` roots, and the observability roots that read application contracts (`obs-hosts`, `obs-diagnostics`, `obs-monitoring`) | push to `main` (dev), **every successful `lab-platform` run on `main` that deployed dev** (pipeline resource trigger), PR build validation, nightly 02:47 UTC drift (dev), manual runs |

Architecture picture: [docs/diagrams/svg/05-delivery.svg](../docs/diagrams/svg/05-delivery.svg).

```
             push main / PR / schedule / manual / tag observability-v*
                    |                                         |
                    v                                         v
   lab-platform (scope platform)                lab-applications (scope applications)
   Select -> Validate + Security                Select -> Validate + Security + Helm lint
     -> P_x plan -> C_x apply (dependency          -> Build (artifacts: resolve | build | promote; charts)
        order, parallel where independent)         -> P_x plan -> C_x apply -> Retire -> Verify (smoke,
     -> Retire -> Drift -> Evidence                   telemetry) -> Drift -> Evidence
           |  run succeeded on main (dev)                  ^
           +------ pipeline resource trigger --------------+
   tag build: ObservabilityRelease only (test, package, sha256, Universal Package)
```

Status (ADR-0001 §11): **implemented** - YAML, templates and tools pass the repository's static checks and
unit tests. Neither pipeline has been run in an Azure DevOps organisation from this repository; nothing has
been deployed by them. See [What only a real Azure DevOps organisation can prove](#what-only-a-real-azure-devops-organisation-can-prove).

## How a run works

| Stage | Agent | Credentials | What it does |
|---|---|---|---|
| Select | hosted (PR) / `deployPool` | none (PR) / plan identity | validates registry, scopes, environment config and promotion policy; `python3 -m tools.changeset select --scope <scope>`; publishes `selection.json`; tags the run `env-<env>`, `scope-<scope>` |
| Validate | Microsoft-hosted | **none** | matrix over selected components of the scope (`tools/validate/component.py`), Helm lint (applications), tooling tests, pipeline lint, template-contract lint, ownership, provider pins, generated-file check |
| Security | Microsoft-hosted | **none** | gitleaks, trivy fs, checkov (pinned, checksum-verified) |
| Build (applications) | `deployPool` | build identity | per artifact: first environment of a chain resolves the image/package tagged with the source fingerprint or builds + pushes it **by digest** (provenance, SBOM); later environments **promote** the exact digest/sha256 the previous environment recorded (never rebuild). Helm charts: content-addressed `helm package` + OCI push |
| P_&lt;x&gt; | `deployPool` | plan identity | render config, materialize contracts, artifact digests, `terraform plan -detailed-exitcode`, plan policy, binding manifest, plan file to the protected `plans` container; publishes the summary |
| C_&lt;x&gt; | `deployPool` | apply identity, environment `lab-<env>` | runs only when the plan has changes and the component is an apply candidate. Approvals are evaluated when this stage starts, i.e. **after** the plan summary exists. Verifies the binding (stale plan → fail), applies, deploys code + smoke (deployment roots), publishes the contract, writes the deployment record |
| Retire | `deployPool` | apply identity, `lab-<env>-retire` | destroys approved retirements of the scope, consumers first |
| Verify (applications) | `deployPool` | plan identity + Datadog keys | HTTP smoke from contract endpoints + telemetry verification |
| Drift | `deployPool` | none | drift report (drift mode) |
| Evidence | `deployPool` | plan identity + Datadog key | deployment report, `evidence.json`, Datadog DORA deployment events |

### Change detection

Per component: `validation_fp` (files, shared modules discovered from `source = "../.."`, referenced Helm
charts, `inputs` globs, tests, docs) and `deploy_fp` (same without tests/docs, plus rendered config, tool
versions, consumed contract majors, registry entry, artifact source fingerprints). Records:
`deployments/<env>/<id>.json` (status, fingerprints, `contracts_sha` it was planned with, scope).

| Mode | Selection |
|---|---|
| `auto` | PR → `pr`, schedule → `drift`, otherwise `deploy` |
| `pr` | rename-aware `git diff -M merge-base(origin/<target>, HEAD)..HEAD` + base/head fingerprints; validate changed components of the scope and consumers of infrastructure changes; no credentials |
| `deploy` | deploy_fp ≠ record, no record, record status ≠ `succeeded`, **or upstream contracts changed since the record** (`contracts_sha`); consumers of infrastructure changes are planned; apply only when the plan has changes |
| `manual` | listed components (+ upstream planned without apply; `withConsumers` adds consumers) |
| `reconcile` | every enabled component of the scope planned, applied where the plan has changes |
| `drift` | every enabled component planned, nothing applied, drift report |
| `retire` | only scheduled retirements |
| `promote` | `deploy` selection for test/prod, refused unless the `promote_from` environment successfully deployed the same code |

Preview a run before pushing:

```bash
python3 -m tools.changeset explain --env dev                       # like a PR build of the working tree
python3 -m tools.changeset explain --env dev --scope applications --records-dir <records> --contracts-dir <contracts>
```

### Cross-pipeline ordering (platform before applications)

* A platform component never depends on an applications component (`python3 -m tools.changeset graph`
  fails otherwise); `obs-hosts` is in the applications pipeline because it must run after `deploy-vm-workloads`.
* When a commit changes a platform component, the applications run **on that same commit** does not plan the
  application components that (transitively) consume it: they are reported as *waiting for the platform
  pipeline* (warning, `selection.summary.waiting`).
* When the platform run succeeds, the resource trigger starts the applications pipeline. Its Select compares
  each component's current materialized contracts with the `contracts_sha` in its record and re-plans exactly
  the consumers whose inputs changed; if no contract changed, nothing is redeployed.
* Last line of defence: the apply re-renders the contracts and refuses a plan made before an upstream contract
  changed (**"stale plan; re-run"**).

### Stage conditions

`P_x`: `and(not(canceled()), <Select/Validate/Security succeeded>, sel_x == 'true', <its artifacts ready>,
upstream_ok(u) for each direct upstream u in the same pipeline)` with
`upstream_ok(u) = and(or(P_u succeeded, and(P_u skipped, sel_u != 'true')), C_u in (Succeeded, SucceededWithIssues, Skipped))`:
an unselected or unchanged upstream does not block; a failed/canceled/rejected or selected-but-skipped
upstream blocks (an infrastructure change selects every transitive consumer, so blocking propagates).
`C_x`: plan stage succeeded, `has_changes`, apply candidate, not a dry run. No `always()` /
`succeededOrFailed()` on deploy stages (lint PL001). Tests evaluate the generated expressions for
Succeeded / SucceededWithIssues / Skipped / Failed / Canceled upstreams and simulate whole runs.

## Promotion: dev → test → prod

[`environments/promotion.yaml`](../environments/promotion.yaml) defines the chain. dev builds; test promotes
from dev, prod from test. Run either pipeline with `environment: test|prod`, `mode: promote` (allowed modes
per environment are enforced by Select; test/prod allow `promote`, `drift`, `retire`):

1. Select refuses unless every enabled component of the scope has a `succeeded` record in the source
   environment with identical source / tool / registry / artifact fingerprints ("deploy this commit there first").
2. Build promotes artifacts: `az acr import` by digest (digest re-verified) and package copy with sha256 check
   from the source environment's registry/packages (`tools/deploy/artifacts.py promote`); nothing is rebuilt.
3. Plans/applies use the target environment's state, config and approvals (`lab-test`, `lab-prod`).

Promote platform first, then applications (their Select waits otherwise).

## Adding things

* **Component**: registry entry in `catalog/components.yaml` (`scope` only when the default by layer is
  wrong), enable it in a profile, then `python3 tools/pipeline/generate.py` and commit both generated files.
* **Environment**: `environments/<env>/environment.yaml`, `pipelines/variables/<env>.yml`, an entry in
  `environments/promotion.yaml`, and the name in the `environment` parameter values of **both** entry files.
  `python3 tools/validate/pipeline_templates.py` fails until all four agree (ENV001-ENV003).
* **Service**: source under `applications/services/<svc>/`, artifact entry (`kind: artifact`), add it to the
  deployment root's `artifacts`; Helm charts under `applications/charts/<name>/` are picked up automatically
  for roots that reference them.

## Operating

* **Retirement**: a recorded component that is no longer enabled is `retire-pending`; it is destroyed only
  when `environments/<env>/retirements.yaml` lists it with `confirm: <component id>`, no enabled component
  depends on it, and `lab-<env>-retire` is approved; consumers retire first, from the recorded commit.
* **Drift**: nightly in dev for both scopes (plan only, report, run marked SucceededWithIssues on drift);
  run `mode: drift` manually for test/prod.
* **Resuming**: a failed/partial/canceled apply writes a non-succeeded record, so the next run re-selects it.
  *Rerun failed jobs* is safe for plan stages; for a failed apply stage rerun the plan stage too (the saved
  plan may be stale) or start a new run.
* **Dry run** (`dryRun: true`): plans only; apply stages are skipped without requesting approvals.
* **Break-glass**: `mode: manual` with the component. If the pipelines are unavailable, an operator with the
  bootstrap break-glass role runs `tools/config/render.py`, `tools/contracts/materialize.py`,
  `pipelines/scripts/tf-init.sh`, `terraform plan/apply`, `tools/contracts/publish.py` and
  `tools/deploy/record.py write` locally, and records the action in the change log.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Select fails "invalid pipeline scopes" | a platform component depends on an applications component | set `scope: applications` on it or remove the edge |
| Select fails "mode 'auto' is not allowed for environment 'test'" | test/prod only accept `promote`, `drift`, `retire` | run with `mode: promote` |
| Select fails "cannot promote … has not successfully deployed this commit" | source environment runs other code | promote/deploy the commit in the source environment first |
| Applications run plans nothing, warns "waiting for the platform pipeline" | platform change on the same commit not yet deployed | let the platform run finish; it triggers the applications run |
| Apply fails "stale plan; re-run" | an upstream contract changed between plan and apply | rerun the plan stage (or a new run) |
| Plan fails "protected resource delete/replace" | plan policy | review; add an unexpired `allow_destroy` entry to `environments/<env>/approvals.yaml` |
| Build promote fails "no successful artifact record in 'dev'" | artifact never built/recorded in the source environment | run the applications pipeline in dev for this commit |
| Validate fails "… is stale; run tools/pipeline/generate.py" | registry changed without regeneration | regenerate and commit both generated files |
| `pipeline_templates.py` LIM003 warning/error | expanded YAML approaching ADO limits | see [Scaling](#scaling-and-limits) |
| Required template check fails on a resource | pipeline does not extend `universal.yml` or the check points at another ref | fix the entry file / check configuration |
| Stage waits on "Exclusive lock" | another run holds `lab-<env>` | expected (`lockBehavior: sequential`); cancel the older run if obsolete |

## Scaling and limits

Azure Pipelines limits (Learn, *Templates*: at most 100 included YAML files, 100 nesting levels, 20 MB parse
memory - "typically 600 KB-2 MB of on-disk YAML"; *Stages*: up to 256 jobs per stage). No limit on the number
of stages is documented. `tools/validate/pipeline_templates.py` fails before them: >80 files, depth >20,
estimated expanded size >1,000,000 bytes (warning above 600,000), >200 jobs in a stage (including the
validate matrix legs). Current estimate: platform ~450 KB, applications ~340 KB. When a budget is exceeded:
split the scope further (another `scope` value and generated file, chained by a pipeline resource trigger),
shard the Build stage, and keep parallelism bounded by the `deployPool` size (`validateMaxParallel` bounds
the validation matrix).

## One-time Azure DevOps setup checklist

1. **Pipelines**: create `lab-platform` from `azure-pipelines.yml` and `lab-applications` from
   `azure-pipelines.applications.yml` (the names matter: the resource trigger uses `source: lab-platform`).
2. **Service connections** (Azure Resource Manager → *Workload identity federation*, issuer
   `https://login.microsoftonline.com/<tenant>/v2.0`, subject copied from the connection, ADR §13) per environment:
   `sc-lab-<env>-plan`, `sc-lab-<env>-apply`, `sc-lab-<env>-build`; names and ids in
   `pipelines/variables/<env>.yml`. Terraform uses `ARM_USE_OIDC`, `ARM_ADO_PIPELINE_SERVICE_CONNECTION_ID`,
   `SYSTEM_ACCESSTOKEN`, `SYSTEM_OIDCREQUESTURI` (token refresh during long applies). Authorize them for the
   two pipelines only. Promoting environments' build identities need AcrPull on the source registry and Blob
   Data Reader on the source `deployments`/`packages` containers.
3. **Environments** `lab-<env>` (Approvals - required for test/prod, two approvers, requester cannot approve;
   **Exclusive lock**) and `lab-<env>-retire` (separate approvers + Exclusive lock). Exclusive lock +
   `lockBehavior: sequential` queue concurrent runs; every plan/apply stage also takes a stage-level lock.
4. **Required template**: on every service connection, both environments per env, the `deployPool` agent pool
   and the Datadog variable groups: *Approvals and checks → Required template → repository
   `enterprise-architecture`, ref `refs/heads/main`, path `pipelines/templates/universal.yml`*.
5. **Variable groups** `lab-<env>-datadog` linked to the environment Key Vault (secrets `datadog-api-key`,
   `datadog-app-key`); used only by the roots that need them and by Verify/Evidence, mapped through `env:`.
6. **Branch policies** (Azure Repos ignores YAML `pr:`): on `main` add *Build validation* for **both**
   pipelines (required, automatic). PR builds compile only Select/Validate/Security on hosted agents without
   credentials; each validates its own scope; a docs-only PR selects nothing.
7. **Agent pools**: Microsoft-hosted for Validate/Security/PR/release; self-hosted `foundation-deploy-agents`
   (VNet) for everything that reaches private endpoints (needs `python3`, `az`, `git`, `docker` or
   `useAcrBuild`, `curl`).
8. **Permissions**: only release managers may queue runs with `environment: prod`; contributors may queue
   dev. Azure Artifacts feed `observabilityFeed` (pipelines/variables/tools.yml): the project Build Service
   needs *Feed Publisher*.
9. **Bootstrap prerequisites**: storage containers `tfstate`, `contracts`, `plans`, `deployments`,
   `evidence`, `packages` and the role assignments of `bootstrap/identities.tf`.

## What only a real Azure DevOps organisation can prove

Compilation of the templates by Azure Pipelines (`extends` + `${{ else }}` + `${{ variables.x }}` from
template variables inside included templates, `lower()`, `iif()`, `replace()`), stage-level output variables
across 100+ stages, matrix from a relayed output variable, the pipeline resource trigger with branch + tag
filters, Required template / Exclusive lock / approval behaviour, `lockBehavior` at stage level, workload
identity federation token refresh during long applies, `az acr import` digest preservation across registries,
Universal Package publishing, and the real expanded-size margin. The repository proves the logic (selection,
conditions, ordering, promotion gates, lint) with tests and static checks only.

## Files

| Path | Purpose |
|---|---|
| `azure-pipelines.yml`, `azure-pipelines.applications.yml` | thin entries (triggers, parameters) |
| `pipelines/templates/universal.yml` | governed template: release dispatch vs lab stages |
| `pipelines/templates/universal-stages.yml` | Select, Validate, Security, include of the generated stages |
| `pipelines/generated/{platform,applications}-stages.yml` | GENERATED (Build, P_/C_ stages, Retire, Verify, Drift, Evidence) |
| `pipelines/templates/*.yml` | plan, apply, build-artifact, container-image, build-*, helm-charts, security-scan, validate, smoke, telemetry-verify, deployment-marker, retire, drift, evidence, observability-release, steps-* |
| `pipelines/scripts/*.sh` | Terraform env/init/prepare/plan/apply/failure-record, agent setup, pinned tool installer |
| `pipelines/variables/` | compile-time settings per environment, tool versions |
| `environments/promotion.yaml` | promotion chains |
