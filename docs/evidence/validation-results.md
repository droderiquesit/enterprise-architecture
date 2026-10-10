# Validation results

Results are reported at three separate levels (ADR-0001 §11). A higher level never inherits a lower level's
result: nothing below is claimed as deployed or operationally verified.

Run date: 2026-10-10 (observability **4.1.0** pass: ARO enrolment `obs-kubernetes-aro` and Service Fabric managed
cluster node enrolment; ARO application workloads switched to Delinea DSV direct reads with Entra workload identity -
`platform-aro` federates the app identities, `deploy-specialized` renders the hello-service chart 2.1.2 in
`secretsMode: dsv`). Toolchain: Terraform 1.16.5, azurerm 5.9.0, azapi 2.13.0, datadog 4.25.0, Go 1.24.7 locally
(release pin 1.24.13 via the digest-pinned builder image), .NET SDK 10.0.401, Python 3.13, Node 22, Helm (tests/kubernetes),
Fluent Bit 5.1.3, OTel Collector Contrib 0.162.0, Datadog Agent 7.84.2, Datadog serverless-init 1.10.4, checkov 3.3.26,
graphify 0.9.84. Rows marked "not re-run" were not repeated in this pass (their code did not change).

## 1. Static validation (no cloud access)

| Check | Command | Result |
|---|---|---|
| Terraform roots + shared modules: fmt, init, validate, `terraform test` (mock providers) | `python3 tools/validate/all_terraform.py --workers 4` | **96 ok, 0 failed, 0 missing** (88 test files; new: `obs-kubernetes-aro`; `platform-aro` app workload identity federation runs, `deploy-specialized` ARO DSV / workload identity runs) |
| IaC security scan | `checkov -d . --framework terraform --quiet --compact` | **328 passed, 0 failed**, 215 skipped (each skip carries an inline justification); 5 parsing errors (checkov HCL parser limitation; `terraform validate` passes): `observability/modules/otel-collector/main.tf`, `observability/modules/host-agent-policy/main.tf` (ARM template expressions in policy JSON) and three `.tftest.hcl` files (`dbm`, `host-agent-policy`, `kubernetes` tests) |
| Service catalog | `python3 tools/catalog/validate.py --check-provider` | 103 entries, 0 errors, 0 warnings; every azurerm type exists in 5.9.0 |
| Coverage documents up to date | `python3 tools/catalog/render_coverage.py --check` | up to date |
| Output contract schemas | `python3 tools/contracts/validate.py --all` | 54 schemas ok (incl. `obs-kubernetes-aro` v1, `platform-aro` 1.1.0 `workload_identities`, `platform-servicefabric` 1.1.0 `node_types`, `obs-kubernetes` v2, `obs-telemetry-transport` v3) |
| Ownership rules (ADR §3) | `python3 tools/validate/ownership.py` | 0 findings |
| Provider pins + lock files + fleet image pins | `python3 tools/validate/versions.py` | 96 directories, 0 errors (incl. `images.datadog_agent` / `images.datadog_serverless_init` = fleet policy) |
| Pipeline lint, template contracts + ADO limits, generated stages, CODEOWNERS | `pipeline_lint.py`, `pipeline_templates.py`, `tools/pipeline/generate.py --check`, `tools/ado/codeowners.py --check` | 0 errors after regenerating the stage files (stale: `platform-aro` now depends on `foundation-identity`); platform (42 components, 84 plan/apply stages) and applications (15 components, 13 artifact jobs) up to date; CODEOWNERS up to date |
| CI suite catalog | `python3 -m tools.ci check` | 92 suites OK |
| Cheap CI gates | `python3 -m tools.ci gates` | 13/13 passed (incl. ruff `E9,F63,F7,F82`, shellcheck, terraform fmt) |
| Change detection, pipeline conditions/templates, tools, review engine, Helm chart tests | `python3 -m pytest -q -n 4 tests` | **567 passed**, 25 skipped (opt-in docker e2e and kind smoke); new: ARO workload identity under `restricted-v2`, Terraform-rendered ARO values (SA annotation, pod label, `DSV_AUTH=azure`, no Secret) |
| Profiles resolve | `tools/config/resolve.py --env <env> --profile <p>` | minimal, enterprise, full, specialized, observability-only, custom x dev / test / prod: 18/18 ok |
| Observability content, tags, portability, Kubernetes chart render | `pytest observability/tests/{content,tags}` + `pytest observability/tests/{portability,kubernetes}` | **66 passed** (46 + 20; portability: 4.1.0 tarball vendored outside the repo; chart: datadog 3.253.2 via `helm template` + post-renderer, AKS and OpenShift) |
| Observability transport incl. docker tests (Fluent Bit, OTel gateway, Worker, APM gateway Agent with the dsv-fetch binary, DBM, ACI Agent sidecar, ACA serverless-init) | `pytest observability/tests/transport` (dockerd running) | **25 passed**, 0 skipped |
| dsv-fetch 2.0.0 (Go) | `go test ./... && go vet ./...` (+ `GOOS=windows`, `GOARCH=arm64` vet); `pytest observability/images/dsv-fetch/tests` | Go unit tests ok, vet clean on linux/amd64, linux/arm64, windows/amd64; conformance suite + host-agent-package tests: **62 passed** |
| VM Application package / policy modules | `pytest observability/modules/host-agent-package/tests` (Linux installer in ubuntu:24.04, shellcheck, terraform test) | included in the 62 above |
| Optional extras content (not packaged) | `pytest observability/extras/content/tests` | **35 passed** |
| Onboarding manifests | `observability/tools/onboarding/validate.py --strict`, `render.py render --check` (package v2: lab dev + existing-environment prod; extras v1 with routing/archetypes) | valid; **fixed**: 33 + 4 rendered services were stale (`package_version` 4.0.0) and were re-rendered for 4.1.0, now up to date; extras 33 up to date |
| .NET services | `dotnet build -c Release -warnaserror`, `dotnet test --solution EnterpriseHello.sln -c Release` | not re-run (no .NET change in this pass); last run 2026-10-10: 0 warnings, 0 errors, **116 passed** |
| Python services + frontend | `applications/python/build.sh --steps lint,test`; frontend `npx vitest run` + `tsc -b` | not re-run (no Python service / frontend change); last run 2026-10-10: ruff clean, **164 Python passed**, **20 vitest passed**, `tsc -b` clean |
| Helm chart (`applications/charts/hello-service`, 2.1.2) | `pytest tests/charts` (helm lint --strict on Helm 4 + 3, kubeconform 1.36.0, schema rejection cases, Terraform-rendered core-aks + ARO values); checkov kubernetes on the rendered examples | included in the 567 above; checkov k8s 709 passed / 22 failed (accepted findings, chart README); kind smoke opt-in |
| Delinea DSV tooling (`tools/secrets`, mock DSV), artifact unpack, fleet pin check | `pytest tests/tools` | included above (new: `test_artifact_unpack.py`, `test_versions_fleet_pins.py`) |
| Codebase knowledge graph (Graphify, local only, not committed) | `pytest tools/graphify/tests`; `tools/graphify/build.sh` | **8 passed**; build ok (14003 nodes incl. 474 IaC, 33408 edges, 763 communities) |
| Docs | `tools/docs/check_links.py`, `render_diagrams.sh --check`, `tools/docs/generate.py --check` | 0 broken links (214 files); diagrams up to date; generated docs up to date after regenerating `docs/guides/component-ownership.md` (`platform-aro` consumes `foundation-identity`) |

## 2. Local integration (docker, emulators, mock Datadog intake)

| Suite | Result | Evidence |
|---|---|---|
| End-to-end browser journey (`python3 tests/integration/run_e2e.py`, Fluent Bit direct log path, `telemetry.pipeline:fluent-bit`) | **12/12 checks passed** (run 20261010T225141Z; incl. secrets resolved from mock Delinea DSV, no secret value in logs/intake) | [local/LATEST.md](local/LATEST.md) |
| Fluent Bit / OTel gateway / Worker / APM gateway / DBM agent / ACI Agent sidecar / ACA serverless-init docker tests (`observability/tests/transport`) | included in the 25 passed above (secrets from a mock Delinea DSV through the dsv-fetch 2.0.0 binary; no key in env, image or Terraform) | transport test README |
| Datadog chart + dsv-fetch post-renderer (`observability/tests/kubernetes`, `helm template`, no cluster; AKS and OpenShift / ARO values) | passed (in the 66 above) | `observability/tests/kubernetes/test_datadog_chart.py` |
| VM Application Linux installer (ubuntu:24.04 container, systemd stubbed) | passed (in the 62 above) | `observability/modules/host-agent-package/tests/test_installers.py` |
| Helm chart on a local kind cluster (v1.36.4, restricted pod security): install, probes, upgrade + rollback | 2026-10-09: passed | `tests/charts/test_kind_smoke.py` |
| Python service integration suites (`build.sh --steps integration`) | 2026-10-09: 21 passed (Postgres, Citus, MySQL, Redis, SQL Server, Mongo wire, Cassandra, Azurite, Service Bus emulator, Chromium) | service READMEs |
| .NET orders-api against SQL Server; Durable Functions host with Azurite + SQL Server | 2026-10-09: passed (orchestrations Fulfilled / Failed+compensated, batch, reconciliation) | `applications/dotnet/README.md` |
| Observability package portability (packaged 4.1.0 tarball consumed outside the repo, upgrade + removal plans) | passed (in the 66 above) | `observability/tests/portability` |

Not exercised locally (no Azure): Azure Policy evaluation / remediation, VM Application publishing and install on real
VMs / VMSS / Service Fabric node types, Windows hosts, ACI and Container Apps runtime behaviour, AKS and ARO workload
identity with DSV, anything on ARO (no cluster: SCC admission, the OpenShift pod-identity webhook, the Datadog Agent on
OpenShift) ([known limitations](../known-limitations.md#application-and-telemetry-limitations)).

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

Not provable without a real managed-identity ARO cluster (observability 4.1.0 and the ARO application path): the
`clusterProfile.oidcIssuer` value and the `platform-aro` federated credentials matching it; the OpenShift pod-identity
webhook injecting `AZURE_*` env + the projected token into hello-catalog-api and the Datadog Agent pods; `restricted-v2`
(app, runners) and the chart SCCs (node Agent, Cluster Agent) admitting those pods; Entra token exchange and Delinea DSV
accepting the federated identity (`xms_mirid`); Datadog log / APM / SSI collection on CRI-O; `deploy-aro.sh` against the
OpenShift API.
