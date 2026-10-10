# Validation results

Results are reported at three separate levels (ADR-0001 §11). A higher level never inherits a lower level's
result: nothing below is claimed as deployed or operationally verified.

Run date: 2026-10-10 (observability 3.0.0 integration pass). Toolchain: Terraform 1.16.5, azurerm 5.9.0, azapi 2.13.0,
datadog 4.25.0, .NET SDK 10.0.401, Python 3.13, Node 22, Fluent Bit 5.1.3, OTel Collector Contrib 0.162.0, Datadog Agent
7.84.2, Datadog serverless-init 1.10.4, checkov 3.3.26. Rows marked "2026-10-09" were not re-run in this pass (their
code did not change).

## 1. Static validation (no cloud access)

| Check | Command | Result |
|---|---|---|
| Terraform roots + shared modules: fmt, init, validate, `terraform test` (mock providers) | `python3 tools/validate/all_terraform.py --workers 4` | **93 ok, 0 failed, 0 missing** (85 test files) |
| IaC security scan | `checkov -d . --framework terraform --quiet --compact` | **316 passed, 0 failed**, 207 skipped (each skip carries an inline justification); 1 parsing error: `observability/modules/otel-collector/main.tf` (unchanged file, checkov HCL parser limitation; `terraform validate` passes) |
| Service catalog | `python3 tools/catalog/validate.py --check-provider` | 102 entries, 0 errors, 0 warnings; every azurerm type exists in 5.9.0 |
| Coverage documents up to date | `python3 tools/catalog/render_coverage.py --check` | up to date |
| Output contract schemas | `python3 tools/contracts/validate.py --all` | all ok (incl. `obs-telemetry-transport` v3; v2 kept) |
| Ownership rules (ADR §3) | `python3 tools/validate/ownership.py` | 0 findings |
| Provider pins + lock files | `python3 tools/validate/versions.py` | 93 directories, 0 errors |
| Pipeline lint, template contracts + ADO limits, generated stages, CODEOWNERS | `pipeline_lint.py`, `pipeline_templates.py`, `tools/pipeline/generate.py --check`, `tools/ado/codeowners.py --check` | 0 errors; platform (41 components) and applications (15 components, 13 artifact jobs) stage files up to date |
| Cheap CI gates | `python3 -m tools.ci gates` | 13/13 passed (incl. ruff `E9,F63,F7,F82`, shellcheck, terraform fmt) |
| Change detection, pipeline conditions/templates, tools, review engine, Helm chart tests | `python3 -m pytest -q -n 4 tests` | **558 passed**, 25 skipped (opt-in docker e2e and kind smoke) |
| Profiles resolve | `tools/config/resolve.py --env dev --profile <p>` | minimal, enterprise, full, specialized, observability-only: ok (`obs-monitoring` is optional, in no built-in profile) |
| Observability content + portability | `pytest observability/tests/content observability/tests/portability` | **30 passed** |
| Observability transport incl. Azure platform/control-plane log tests | `pytest observability/tests/transport` | 23 passed, 1 skipped (opt-in network test) |
| Optional extras content (not packaged) | `pytest observability/extras/content/tests` | **35 passed** |
| Onboarding manifests | `observability/tools/onboarding/validate.py --strict`, `render.py render --check` (package v2; extras v1 with routing/archetypes) | valid; 33 services up to date (package and extras) |
| .NET services | `dotnet test --solution EnterpriseHello.sln -c Release` | 2026-10-09: **106 passed**, 0 warnings in Release build |
| Python services + frontend | `applications/python/build.sh --steps lint,test`; frontend `npx vitest run` + `tsc -b` | 2026-10-09: ruff clean, 137 Python passed; 2026-10-10: **20 vitest passed** (incl. RUM `globalContext`), typecheck clean |
| Helm chart (`applications/charts/hello-service`, 2.1.0) | `pytest tests/charts` (helm lint --strict on Helm 4 + 3, kubeconform 1.36.0, schema rejection cases) | 185 passed, 2 skipped (kind smoke, opt-in) |
| Delinea DSV tooling (`tools/secrets`, mock DSV) and `dsv-fetch` helper | `pytest tests/tools`, `pytest observability/images/dsv-fetch` | tests/tools included above; dsv-fetch 2026-10-09: 35 passed |
| Docs | `tools/docs/check_links.py`, `render_diagrams.sh --check`, `tools/docs/generate.py --check` | 0 broken links; diagrams and generated docs up to date |

## 2. Local integration (docker, emulators, mock Datadog intake)

| Suite | Result | Evidence |
|---|---|---|
| End-to-end browser journey (`python3 tests/integration/run_e2e.py`, Fluent Bit direct log path, `telemetry.pipeline:fluent-bit`) | **12/12 checks passed** (run 20261010T021945Z; frontend image rebuilt from the current source; incl. secrets resolved from mock Delinea DSV, no secret value in logs/intake) | [local/LATEST.md](local/LATEST.md) |
| Fluent Bit / OTel gateway / Worker / DBM agent docker tests (`observability/tests/transport`) | included in the 23 passed above | transport test README |
| serverless-init 1.10.4 API key from a dsv-fetch dotenv file (ad hoc docker check, not a committed test) | `DD_API_KEY` sourced from the file before `exec /datadog-init` reached a local mock intake with traces and a DogStatsD custom metric; `datadog.yaml` `api_key` and `ENC[]` are not read | [known limitations](../known-limitations.md#application-and-telemetry-limitations) |
| Helm chart on a local kind cluster (v1.36.4, restricted pod security): install, probes, upgrade + rollback | 2026-10-09: passed | `tests/charts/test_kind_smoke.py` |
| Python service integration suites (`build.sh --steps integration`) | 2026-10-09: 21 passed (Postgres, Citus, MySQL, Redis, SQL Server, Mongo wire, Cassandra, Azurite, Service Bus emulator, Chromium) | service READMEs |
| .NET orders-api against SQL Server; Durable Functions host with Azurite + SQL Server | 2026-10-09: passed (orchestrations Fulfilled / Failed+compensated, batch, reconciliation) | `applications/dotnet/README.md` |
| Observability package portability (packaged tarball consumed outside the repo, upgrade + removal plans) | passed (in the 30 above) | `observability/tests/portability` |

What is real vs emulated vs mocked locally: Service Bus and Storage are the official emulators; SQL Server, PostgreSQL,
Redis are real engines; Cosmos DB is replaced by an in-memory store; Entra ID authentication is not exercised; every
Datadog endpoint is a local mock intake (payload shape only, no Datadog ingestion, indexing, monitors or UI).

## 3. Live verification (Azure + Datadog)

**Not run.** This repository was built in a sandbox without Azure or Datadog credentials. No component has the
status `deployed` or `verified`. Exact prerequisites to run live verification:

1. An Azure subscription with the resource providers and quotas listed in
   [prerequisites-and-bootstrap](../guides/prerequisites-and-bootstrap.md), and an operator able to run `bootstrap/`.
2. An Azure DevOps organisation/project with the service connections, environments, variable groups and agent pool
   from [pipelines/README.md](../../pipelines/README.md).
3. A Datadog organisation (API + application key in Delinea DSV, RUM enabled, Database Monitoring and Synthetics
   entitlements).
4. Then: run the universal pipeline with profile `minimal`; the Verify stage runs smoke tests and
   `observability/tools/verify/telemetry_verify.py`, and evidence is pulled into `docs/evidence/<env>/<run-id>/`
   with `tools/report/pull_evidence.py`.

Not provable without a real Azure DevOps organisation: YAML compilation by Azure DevOps, approvals/exclusive-lock
behaviour, workload identity federation token exchange.
