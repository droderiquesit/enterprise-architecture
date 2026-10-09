# azure-enterprise-observability-lab

A configurable Azure enterprise **test environment**, a working sample application (**Enterprise Hello**) that
exercises it end to end, and a **portable, versioned Datadog observability-as-code package** that onboards services
from one YAML manifest each. Everything is Terraform, Python and .NET in one repository, delivered by one universal
Azure DevOps pipeline that deploys only the components that changed (plus what they need).

> **Status.** Code is implemented and statically validated (Terraform `fmt`/`validate`/`terraform test` with mock
> providers, unit tests, local docker integration tests for the services). **Nothing has been deployed to Azure or
> verified against a Datadog organisation** from this repository: no credentials were available while it was built,
> and no evidence file exists under [`docs/evidence/`](docs/evidence/README.md). Status words follow
> [ADR-0001 section 11](docs/architecture/ADR-0001-design-contract.md#11-testing-levels-and-evidence-vocabulary).

- Validation summary: [docs/evidence/validation-results.md](docs/evidence/validation-results.md)

## What is in it

| Layer | Directory | What it owns |
|---|---|---|
| bootstrap | [`bootstrap/`](bootstrap/README.md) | Terraform state storage (`tfstate`, `contracts`, `plans`, `deployments`, `evidence`, `packages` containers), pipeline identities with workload identity federation, optional Datadog Entra app. Applied manually, local state first, then migrated. |
| foundation | [`foundation/`](foundation/README.md) | hub/spoke or single-spoke network, subnet catalogue with delegations, NSGs, NAT/firewall egress, private DNS zones, Key Vault + workload identities, budget + policy, private deployment agents, optional edge (App Gateway, Front Door, APIM, Firewall, Bastion) |
| platform | [`platform/`](platform/README.md), [`platform/data/`](platform/data/README.md) | compute platforms (AKS, Container Apps, App Service, Functions, VM, VMSS, Batch, Service Fabric, ARO, specialized), ACR, Service Bus, 17 database/data-store roots |
| applications | [`applications/`](applications/deployments/README.md) | Enterprise Hello services (React frontend, .NET BFF/orders/inventory/durable, Python catalog/adapters/worker/jobs/functions/partner-sim/traffic, Logic Apps) and one deployment root per hosting group |
| observability | [`observability/`](observability/README.md) | portable package (monitors, SLOs, synthetics, dashboards, catalog, RUM, Azure integration, diagnostic settings, Fluent Bit / OTel transport, agents, DBM) + lab roots under `observability/lab/` |
| delivery | [`azure-pipelines.yml`](azure-pipelines.yml), [`pipelines/`](pipelines/README.md), [`tools/`](tools/README.md) | change detection, generated per-component stages, plan binding, contracts, smoke, telemetry verification, evidence |
| catalog | [`catalog/`](catalog/) | component registry, Azure service catalog (100 entries), architecture matrix, telemetry capabilities, contract schemas, provider gaps |

Architecture pictures: [docs/diagrams](docs/diagrams/README.md) (foundation, platform, application, telemetry, delivery).

## Profiles

Selected with `profile:` in `environments/<env>/environment.yaml` (details: [deployment profiles](docs/guides/deployment-profiles.md)).

| Profile | Intent | Expensive |
|---|---|---|
| `minimal` | smallest end-to-end slice: SWA frontend -> BFF/APIs on Container Apps -> Azure SQL + PostgreSQL, Service Bus Standard, Durable Functions (Flex), partner-sim on ACI, jobs, full telemetry | no |
| `enterprise` | common enterprise patterns: AKS, App Service, Container Apps, Functions, VM, VMSS, SQL, PostgreSQL, MySQL, Cosmos NoSQL, Managed Redis, Table Storage, private agents, hub-spoke | no (but well above minimal) |
| `full` | every implemented and eligible catalog entry, deployed in groups `g1`..`g6` | yes, requires confirmation |
| `specialized` | restricted / partner / preview / high-cost services (SF, ARO, SQL MI, Cassandra MI, HorizonDB, ...) | yes, requires confirmation |
| `observability-only` | monitoring applied to existing resources; no lab infrastructure | no |
| `custom` | explicit `custom_components`; hard dependencies added automatically | depends |

## Quick start

Full walk-through: [docs/guides/quick-start.md](docs/guides/quick-start.md).

```bash
# 1. local validation (no credentials)
pip install -r pipelines/requirements-tools.txt pytest
python3 -m tools.changeset graph                      # registry valid + acyclic
python3 tools/config/resolve.py --env dev             # what the dev profile enables
python3 tools/validate/all_terraform.py --workers 4   # fmt/init/validate/test for every root and module
python3 -m pytest -q tests
python3 tools/docs/generate.py --check && tools/docs/render_diagrams.sh --check && python3 tools/docs/check_links.py

# 2. bootstrap (operator workstation, Owner on the subscription)
bootstrap/scripts/bootstrap.sh --env dev              # local state -> migrated to the state account

# 3. Azure DevOps: service connections, environments, variable group, branch policy (pipelines/README.md),
#    then run azure-pipelines.yml (mode auto) - foundation first on Microsoft-hosted agents, then private agents.
```

Prerequisites, provider registrations, quotas and the bootstrap sequence before private agents exist:
[prerequisites-and-bootstrap.md](docs/guides/prerequisites-and-bootstrap.md).

## Repository map

```
bootstrap/                      state storage + pipeline identities (manual root)
foundation/{network,identity,governance,deploy-agents,edge}/   foundation roots; foundation/modules/{naming,tags,private-endpoint}
platform/shared, platform/messaging, platform/compute/*, platform/data/*   platform roots; platform/modules/*
applications/services/*         service source (one artifact component each)
applications/deployments/*      application deployment roots (own app resources + settings)
applications/{dotnet,python,shared}/   build tooling and shared libraries
observability/modules/*         portable package modules; observability/lab/* lab roots; observability/onboarding/* lab manifests
catalog/                        components.yaml, services/*.yaml, architecture-matrix.yaml, telemetry-capabilities.yaml, contracts/, schemas/
environments/                   dev/environment.yaml, profiles/*.yaml, schema/
pipelines/, azure-pipelines.yml universal pipeline (generated stages in pipelines/generated/)
tools/                          changeset, config, contracts, validate, deploy, smoke, report, catalog, docs
docs/                           ADR, guides, runbooks, diagrams, coverage (generated), evidence
tests/                          tooling tests (changeset, pipeline, tools, catalog)
```

## Status summary

<!-- BEGIN STATUS (generated by tools/docs/generate.py) -->
| Catalog | Total | implemented | disabled | blocked | cataloged | live validation |
|---|---:|---:|---:|---:|---:|---|
| Azure services (`catalog/services/*.yaml`) | 101 | 55 | 14 | 2 | 30 | not-run: 101 |

Components in `catalog/components.yaml`: **69** (13 artifact, 1 docs, 55 terraform; 25 applications, 1 bootstrap, 1 docs, 5 foundation, 8 observability, 29 platform). Non-GA lifecycle entries in the service catalog: 13.
<!-- END STATUS -->

Live validation: **not-run** for every component and service. Per-requirement status with links to the implementing
files: [IMPLEMENTATION_CHECKLIST.md](docs/IMPLEMENTATION_CHECKLIST.md). Exact blockers and limitations:
[known-limitations.md](docs/known-limitations.md). Generated coverage: [service coverage matrix](docs/coverage/coverage-matrix.md),
[telemetry capability matrix](docs/coverage/telemetry-capability-matrix.md).

## Documentation

| Topic | Document |
|---|---|
| Design contract (binding) | [ADR-0001](docs/architecture/ADR-0001-design-contract.md) |
| Getting started | [quick start](docs/guides/quick-start.md), [prerequisites and bootstrap](docs/guides/prerequisites-and-bootstrap.md), [deployment profiles](docs/guides/deployment-profiles.md) |
| Ownership | [component ownership](docs/guides/component-ownership.md) (generated), [architecture deployment matrix](docs/guides/architecture-deployment-matrix.md) (generated) |
| Observability | [service onboarding tutorial](docs/guides/service-onboarding-tutorial.md), [production adoption of the package](docs/guides/observability-production-adoption.md), [demo walkthrough](docs/guides/demo-walkthrough.md) |
| Cost | [cost and lifecycle](docs/guides/cost-and-lifecycle.md) |
| Operations | [runbooks](docs/runbooks/README.md): secret rotation, rollback, teardown, break-glass, alert response, fault injection |
| Evidence | [docs/evidence](docs/evidence/README.md) |
