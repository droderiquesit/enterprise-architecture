# Validation results

Results are reported at three separate levels (ADR-0001 §11). A higher level never inherits a lower level's
result: nothing below is claimed as deployed or operationally verified.

Run date: 2026-10-10 (observability 4.0.0 integration pass: Datadog Agent deployment v4). Toolchain: Terraform 1.16.5,
azurerm 5.9.0, azapi 2.13.0, datadog 4.25.0, Go 1.24.7 locally (release pin 1.24.13 via the digest-pinned builder
image), .NET SDK 10.0.401, Python 3.13, Node 22, Helm (tests/kubernetes), Fluent Bit 5.1.3, OTel Collector Contrib
0.162.0, Datadog Agent 7.84.2, Datadog serverless-init 1.10.4, checkov 3.3.26. Rows marked "2026-10-09" were not re-run
in this pass (their code did not change).

## 1. Static validation (no cloud access)

| Check | Command | Result |
|---|---|---|
| Terraform roots + shared modules: fmt, init, validate, `terraform test` (mock providers) | `python3 tools/validate/all_terraform.py --workers 4` | **95 ok, 0 failed, 0 missing** (87 test files) |
| IaC security scan | `checkov -d . --framework terraform --quiet --compact` | **328 passed, 0 failed**, 215 skipped (each skip carries an inline justification); 5 parsing errors (checkov HCL parser limitation; `terraform validate` passes): `observability/modules/otel-collector/main.tf` (unchanged), `observability/modules/host-agent-policy/main.tf` (ARM template expressions in policy JSON) and three `.tftest.hcl` files (`dbm`, `host-agent-policy`, `kubernetes` tests) |
| Service catalog | `python3 tools/catalog/validate.py --check-provider` | 103 entries, 0 errors, 0 warnings; every azurerm type exists in 5.9.0 |
| Coverage documents up to date | `python3 tools/catalog/render_coverage.py --check` | up to date |
| Output contract schemas | `python3 tools/contracts/validate.py --all` | 53 schemas ok (incl. `obs-kubernetes` **v2**, v1 kept; `obs-telemetry-transport` v3); module/lab `obs-kubernetes` plans validated against v2 (`contract_check.py`) |
| Ownership rules (ADR §3) | `python3 tools/validate/ownership.py` | 0 findings |
| Provider pins + lock files + fleet image pins | `python3 tools/validate/versions.py` | 95 directories, 0 errors (incl. `images.datadog_agent` / `images.datadog_serverless_init` = fleet policy) |
| Pipeline lint, template contracts + ADO limits, generated stages, CODEOWNERS | `pipeline_lint.py`, `pipeline_templates.py`, `tools/pipeline/generate.py --check`, `tools/ado/codeowners.py --check` | 0 errors; platform (41 components) and applications (15 components, 13 artifact jobs) stage files up to date; CODEOWNERS 93 entries |
| CI suite catalog | `python3 -m tools.ci check` | 90 suites OK (new: `obs-kubernetes-chart`, `obs-host-agent-package`, `obs-agent-sidecar`) |
| Cheap CI gates | `python3 -m tools.ci gates` | 13/13 passed (incl. ruff `E9,F63,F7,F82`, shellcheck, terraform fmt) |
| Change detection, pipeline conditions/templates, tools, review engine, Helm chart tests | `python3 -m pytest -q -n 4 tests` | **564 passed**, 25 skipped (opt-in docker e2e and kind smoke) |
| Profiles resolve | `tools/config/resolve.py --env dev --profile <p>` | minimal, enterprise, full, specialized, observability-only: ok (`obs-monitoring` is optional, in no built-in profile) |
| Observability content, tags, portability, Kubernetes chart render | `pytest observability/tests/{content,tags,portability,kubernetes}` | **59 passed** (portability: 4.0.0 tarball vendored outside the repo; chart: datadog 3.253.2 via `helm template` + post-renderer) |
| Observability transport incl. docker tests (Fluent Bit, OTel gateway, Worker, APM gateway Agent with the dsv-fetch binary, DBM, ACI Agent sidecar, ACA serverless-init) | `pytest observability/tests/transport` | **25 passed**, 0 skipped (the 3.x host-installer network test was retired with the run-command host path) |
| dsv-fetch 2.0.0 (Go) | `go test ./... && go vet ./...` (+ `GOOS=windows`, `GOARCH=arm64` vet); `pytest observability/images/dsv-fetch/tests` | Go unit tests ok, vet clean on linux/amd64, linux/arm64, windows/amd64; conformance suite against the binary (Python 1.x removed) + host-agent-package tests: **62 passed** |
| VM Application package / policy modules | `pytest observability/modules/host-agent-package/tests` (Linux installer in ubuntu:24.04, shellcheck, terraform test) | included in the 62 above |
| Optional extras content (not packaged) | `pytest observability/extras/content/tests` | **35 passed** |
| Onboarding manifests | `observability/tools/onboarding/validate.py --strict`, `render.py render --check` (package v2: lab dev + existing-environment prod; extras v1 with routing/archetypes) | valid; 33 + 4 services up to date (re-rendered for `package_version` 4.0.0), extras 33 up to date |
| .NET services | `dotnet test --solution EnterpriseHello.sln -c Release` | 2026-10-09: **106 passed**, 0 warnings in Release build (no app code changed) |
| Python services + frontend | `applications/python/build.sh --steps lint,test`; frontend `npx vitest run` + `tsc -b` | 2026-10-09: ruff clean, 137 Python passed; 2026-10-10: **20 vitest passed**, typecheck clean (no app code changed in this pass) |
| Helm chart (`applications/charts/hello-service`, 2.1.0) | `pytest tests/charts` (helm lint --strict on Helm 4 + 3, kubeconform 1.36.0, schema rejection cases) | included in the 564 above; kind smoke opt-in |
| Delinea DSV tooling (`tools/secrets`, mock DSV), artifact unpack, fleet pin check | `pytest tests/tools` | included above (new: `test_artifact_unpack.py`, `test_versions_fleet_pins.py`) |
| Docs | `tools/docs/check_links.py`, `render_diagrams.sh --check`, `tools/docs/generate.py --check` | 0 broken links (201 files); diagrams and generated docs up to date |

## 2. Local integration (docker, emulators, mock Datadog intake)

| Suite | Result | Evidence |
|---|---|---|
| End-to-end browser journey (`python3 tests/integration/run_e2e.py`, Fluent Bit direct log path, `telemetry.pipeline:fluent-bit`) | **12/12 checks passed** (run 20261010T084539Z; incl. secrets resolved from mock Delinea DSV, no secret value in logs/intake) | [local/LATEST.md](local/LATEST.md) |
| Fluent Bit / OTel gateway / Worker / APM gateway / DBM agent / ACI Agent sidecar / ACA serverless-init docker tests (`observability/tests/transport`) | included in the 25 passed above (secrets from a mock Delinea DSV through the dsv-fetch 2.0.0 binary; no key in env, image or Terraform) | transport test README |
| Datadog chart + dsv-fetch post-renderer (`observability/tests/kubernetes`, `helm template`, no cluster) | passed (in the 59 above) | `observability/tests/kubernetes/test_datadog_chart.py` |
| VM Application Linux installer (ubuntu:24.04 container, systemd stubbed) | passed (in the 62 above) | `observability/modules/host-agent-package/tests/test_installers.py` |
| Helm chart on a local kind cluster (v1.36.4, restricted pod security): install, probes, upgrade + rollback | 2026-10-09: passed | `tests/charts/test_kind_smoke.py` |
| Python service integration suites (`build.sh --steps integration`) | 2026-10-09: 21 passed (Postgres, Citus, MySQL, Redis, SQL Server, Mongo wire, Cassandra, Azurite, Service Bus emulator, Chromium) | service READMEs |
| .NET orders-api against SQL Server; Durable Functions host with Azurite + SQL Server | 2026-10-09: passed (orchestrations Fulfilled / Failed+compensated, batch, reconciliation) | `applications/dotnet/README.md` |
| Observability package portability (packaged 4.0.0 tarball consumed outside the repo, upgrade + removal plans) | passed (in the 59 above) | `observability/tests/portability` |

Not exercised locally (no Azure): Azure Policy evaluation / remediation, VM Application publishing and install on real
VMs / VMSS, Windows hosts, ACI and Container Apps runtime behaviour, AKS workload identity with DSV
([known limitations](../known-limitations.md#application-and-telemetry-limitations)).

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
