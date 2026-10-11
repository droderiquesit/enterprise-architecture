# azure-enterprise-observability-lab

A configurable Azure enterprise **test environment**, a working sample application (**Enterprise Hello**) that
exercises it end to end, and a **portable, versioned Datadog fleet collection configuration package** (tags, Agent fleet,
Observability Pipelines, tracers, RUM) that onboards services from one YAML manifest each. Everything is Terraform, Python,
.NET, TypeScript and Go in one repository, delivered by two Azure DevOps pipelines (platform and applications) on one
governed template that deploy only the components that changed (plus what they need).

> **Status.** Code is implemented and statically validated (Terraform `fmt`/`validate`/`terraform test` with mock
> providers, unit tests, local docker integration tests for the services). **Nothing has been deployed to Azure or
> verified against a Datadog organisation** from this repository: no credentials were available while it was built,
> and no evidence file exists under [`docs/evidence/`](docs/evidence/README.md). Status words follow
> [ADR-0001 section 11](docs/architecture/ADR-0001-design-contract.md#11-testing-levels-and-evidence-vocabulary);
> validation summary: [validation results](docs/evidence/validation-results.md).

## What is in it

| Layer | Directory | What it owns |
|---|---|---|
| bootstrap | [`bootstrap/`](bootstrap/README.md) | Terraform state storage (`tfstate`, `contracts`, `plans`, `deployments`, `evidence`, `packages` containers), pipeline identities with workload identity federation, optional Datadog Entra app. Applied manually, local state first, then migrated. |
| foundation | [`foundation/`](foundation/README.md) | hub/spoke or single-spoke network, subnet catalogue with delegations, NSGs, NAT/firewall egress, private DNS zones, workload identities + Delinea DSV secret access (users/policies as code; no Key Vault), budget + policy, private deployment agents, optional edge (App Gateway, Front Door, APIM, Firewall, Bastion) |
| platform | [`platform/`](platform/README.md), [`platform/data/`](platform/data/README.md) | compute platforms (AKS, Container Apps, App Service, Functions, VM, VMSS, Batch, Service Fabric, ARO, specialized), ACR, Service Bus, 17 database/data-store roots |
| applications | [`applications/`](applications/deployments/README.md) | Enterprise Hello services (React frontend, .NET BFF/orders/inventory/durable, Python catalog/adapters/worker/jobs/functions/partner-sim/traffic, Logic Apps) and one deployment root per hosting group |
| observability | [`observability/`](observability/README.md) | portable, versioned package for fleet collection configuration ([CHANGELOG](observability/CHANGELOG.md)): tag policy, fleet policy, Observability Pipelines, one log collector per architecture, APM / profiling / RUM / DBM, Azure integration and diagnostic settings, `dsv-fetch` for every Datadog key read from Delinea DSV; lab roots under `observability/lab/`. Optional monitors / SLOs / dashboards: [`observability/extras/content/`](observability/extras/content/README.md) |
| delivery | [`azure-pipelines.yml`](azure-pipelines.yml) (platform), [`azure-pipelines.applications.yml`](azure-pipelines.applications.yml) (applications), [`pipelines/`](pipelines/README.md), [`tools/`](tools/README.md) | two pipelines on one governed template: change detection, generated plan/apply stages, promotion dev -> test -> prod, plan binding, contracts, smoke, telemetry verification, evidence, observability package release |
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
| `observability-only` | Datadog collection configuration (Azure integration, RUM prerequisites) for existing resources; no lab infrastructure | no |
| `custom` | explicit `custom_components`; hard dependencies added automatically | depends |

## Quick start

Local validation needs no credentials; the first deployment needs Azure, Azure DevOps, Datadog and Delinea DSV
([prerequisites](docs/guides/prerequisites-and-bootstrap.md)). Walk-through: [docs/guides/quick-start.md](docs/guides/quick-start.md).

```bash
pip install -r pipelines/requirements-tools.txt pytest
python3 tools/validate/all_terraform.py --workers 4   # fmt/init/validate/test for every root and module
python3 -m pytest -q tests
bootstrap/scripts/bootstrap.sh --env dev              # then the Azure DevOps setup in pipelines/README.md
```

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
pipelines/, azure-pipelines*.yml  platform + applications pipelines (generated stages in pipelines/generated/)
tools/                          changeset, config, contracts, validate, deploy, smoke, report, catalog, docs
docs/                           ADR, guides, runbooks, diagrams, coverage (generated), evidence
tests/                          tooling tests (changeset, pipeline, tools, catalog)
```

## Status summary

<!-- BEGIN STATUS (generated by tools/docs/generate.py) -->
| Catalog | Total | implemented | disabled | blocked | cataloged | live validation |
|---|---:|---:|---:|---:|---:|---|
| Azure services (`catalog/services/*.yaml`) | 103 | 56 | 14 | 2 | 31 | not-run: 103 |

Components in `catalog/components.yaml`: **74** (15 artifact, 1 docs, 58 terraform; 26 applications, 1 bootstrap, 1 docs, 7 foundation, 10 observability, 29 platform). Non-GA lifecycle entries in the service catalog: 13.
<!-- END STATUS -->

Per-requirement status: [IMPLEMENTATION_CHECKLIST.md](docs/IMPLEMENTATION_CHECKLIST.md); blockers and limitations:
[known-limitations.md](docs/known-limitations.md).

## Documentation

Start at the [documentation index](docs/README.md); the binding design contract is
[ADR-0001](docs/architecture/ADR-0001-design-contract.md).
