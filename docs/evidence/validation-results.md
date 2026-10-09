# Validation results

Results are reported at three separate levels (ADR-0001 §11). A higher level never inherits a lower level's
result: nothing below is claimed as deployed or operationally verified.

Run date: 2026-10-09. Toolchain: Terraform 1.16.5, azurerm 5.9.0, azapi 2.13.0, datadog 4.25.0, .NET SDK 10.0.401,
Python 3.13, Node 22, Fluent Bit 5.1.3, OTel Collector Contrib 0.162.0, Datadog Agent 7.84.2.

## 1. Static validation (no cloud access)

| Check | Command | Result |
|---|---|---|
| Terraform roots + shared modules: fmt, init, validate, `terraform test` (mock providers) | `python3 tools/validate/all_terraform.py --workers 4` | **86 ok, 0 failed, 0 missing** (284 test runs in 78 test files) |
| IaC security scan | `checkov -d . --framework terraform` | **342 passed, 0 failed**, 203 skipped (each skip carries an inline justification) |
| Service catalog | `python3 tools/catalog/validate.py --check-provider` | 101 entries, 0 errors, 0 warnings; every azurerm type exists in 5.9.0 |
| Coverage documents up to date | `python3 tools/catalog/render_coverage.py --check` | up to date |
| Output contract schemas | `python3 tools/contracts/validate.py --all` | all ok |
| Ownership rules (ADR §3) | `python3 tools/validate/ownership.py` | 0 findings |
| Provider pins + lock files | `python3 tools/validate/versions.py` | 84 directories, 0 errors |
| Pipeline lint, template contracts + ADO limits, generated stages | `pipeline_lint.py`, `pipeline_templates.py`, `tools/pipeline/generate.py --check` | 0 errors; platform (39 components) and applications (15 components, 13 artifact jobs) stage files up to date |
| Change detection, pipeline conditions/templates, tools, Helm chart tests | `python3 -m pytest -q tests` | **297 passed**, 14 skipped (opt-in docker e2e and kind smoke) |
| Profiles resolve | `tools/config/resolve.py --env dev --profile <p>` | minimal, enterprise, full, specialized, observability-only: ok |
| Observability content + portability | `pytest observability/tests/content observability/tests/portability` | **57 passed** |
| Observability transport incl. Azure platform/control-plane log tests | `pytest observability/tests/transport` | 18 passed, 1 skipped (opt-in network test) |
| Onboarding manifests | `observability/tools/onboarding/validate.py --strict`, `render.py render --check` | valid; 33 services up to date |
| .NET services | `dotnet test --solution EnterpriseHello.sln -c Release` | **79 passed**, 0 warnings in Release build |
| Python services + frontend | `applications/python/build.sh --steps lint,test` | ruff clean; **137 Python + 18 vitest passed** |
| Helm chart (`applications/charts/hello-service`) | `pytest tests/charts` (helm lint --strict on Helm 4 + 3, kubeconform 1.36.0, schema rejection cases) | 153 passed; kind smoke (opt-in) 2 passed |
| Docs | `tools/docs/check_links.py`, `render_diagrams.sh --check`, `tools/docs/generate.py --check` | 0 broken links; diagrams and generated docs up to date |

## 2. Local integration (docker, emulators, mock Datadog intake)

| Suite | Result | Evidence |
|---|---|---|
| End-to-end browser journey (`python3 tests/integration/run_e2e.py`) | **11/11 checks passed** | [local/LATEST.md](local/LATEST.md) |
| Fluent Bit / OTel gateway / DBM agent docker tests (`observability/tests/transport`) | 13 passed | transport test README |
| Helm chart on a local kind cluster (v1.36.4, restricted pod security): install, probes, upgrade + rollback | passed | `tests/charts/test_kind_smoke.py` |
| Python service integration suites (`build.sh --steps integration`) | 21 passed (Postgres, Citus, MySQL, Redis, SQL Server, Mongo wire, Cassandra, Azurite, Service Bus emulator, Chromium) | service READMEs |
| .NET orders-api against SQL Server; Durable Functions host with Azurite + SQL Server | passed (orchestrations Fulfilled / Failed+compensated, batch, reconciliation) | `applications/dotnet/README.md` |
| Observability package portability (packaged tarball consumed outside the repo, upgrade + removal plans) | passed | `observability/tests/portability` |

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
3. A Datadog organisation (API + application key in Key Vault, RUM enabled, Database Monitoring and Synthetics
   entitlements).
4. Then: run the universal pipeline with profile `minimal`; the Verify stage runs smoke tests and
   `observability/tools/verify/telemetry_verify.py`, and evidence is pulled into `docs/evidence/<env>/<run-id>/`
   with `tools/report/pull_evidence.py`.

Not provable without a real Azure DevOps organisation: YAML compilation by Azure DevOps, approvals/exclusive-lock
behaviour, workload identity federation token exchange.
