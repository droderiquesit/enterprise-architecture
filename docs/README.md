# Documentation index

Everything under `docs/`, grouped by what you want to do. Status words (`implemented`, `locally-verified`, `deployed`,
`verified`, ...) follow [ADR-0001 section 11](architecture/ADR-0001-design-contract.md#11-testing-levels-and-evidence-vocabulary):
nothing in this repository has been deployed to Azure or verified against a Datadog organisation.

Pages marked *generated* are written by `python3 tools/docs/generate.py` or `python3 tools/catalog/render_coverage.py`;
edit their sources, never the pages. Diagrams are rendered by `tools/docs/render_diagrams.sh`.

## Start here

| Document | Use it for |
|---|---|
| [Repository README](../README.md) | what the lab is, layers, profiles, status summary |
| [ADR-0001 - design contract](architecture/ADR-0001-design-contract.md) | the binding rules: layers and ownership, state, contracts, naming, telemetry paths, Delinea DSV (sections 13-14 hold the dated amendments, including observability 4.0.0) |
| [Quick start](guides/quick-start.md) | local validation without credentials, then the first deployment |
| [Prerequisites and bootstrap](guides/prerequisites-and-bootstrap.md) | Azure, Azure DevOps, Datadog and Delinea DSV prerequisites; bootstrap before private agents exist |
| [Deployment profiles](guides/deployment-profiles.md) | `minimal`, `enterprise`, `full`, `specialized`, `observability-only`, `custom`; cost per profile |
| [Diagrams](diagrams/README.md) | foundation, platform, application, telemetry and delivery pictures |

## Architecture and ownership

| Document | Use it for |
|---|---|
| [Component ownership](guides/component-ownership.md) (*generated*) | every registry component: layer, owner, contracts, profiles |
| [Architecture deployment matrix](guides/architecture-deployment-matrix.md) (*generated*) | which service runs on which hosting architecture and data store |
| [Service coverage matrix](coverage/coverage-matrix.md) (*generated*) | the Azure service catalog with status and lifecycle |
| [Telemetry capability matrix](coverage/telemetry-capability-matrix.md) (*generated*) | which Datadog signals each architecture and database family supports |

## Observability (package 4.0.0)

| Document | Use it for |
|---|---|
| [Datadog fleet collection](guides/datadog-fleet-collection.md) | the authoritative collection path per resource type: one log collector per architecture, APM library contract, profiler support, how each Agent gets its key from DSV |
| [Datadog tagging](guides/datadog-tagging.md) | the tag policy and where each signal gets its tags |
| [Azure platform logs](guides/azure-logs-to-datadog.md) | Activity Log, resource logs and Entra ID logs through Event Hubs to the Observability Pipelines Worker |
| [Service onboarding tutorial](guides/service-onboarding-tutorial.md) | onboarding one service with a v2 manifest |
| [Production adoption](guides/observability-production-adoption.md) | using a package release against existing infrastructure; upgrade, rollback, removal |
| [Demo walkthrough](guides/demo-walkthrough.md) | one order traced from the browser to the durable workflow |
| Package reference | [observability/README.md](../observability/README.md), [CHANGELOG](../observability/CHANGELOG.md), [UPGRADING](../observability/UPGRADING.md), [transport rules](../observability/modules/README-transport.md) |

## Delivery and development

| Document | Use it for |
|---|---|
| [Pipelines operator guide](../pipelines/README.md) | the two pipelines (`lab-platform`, `lab-applications`), stages, modes, one-time Azure DevOps setup |
| [Branching and development](guides/branching-and-development.md) | trunk-based flow, who approves what, fast PR builds |
| [Automated PR review](guides/automated-pr-review.md) | GitHub Copilot code review for Azure Repos plus the `eh-review/policy` bot |
| [Graphify knowledge graph](guides/graphify.md) | local, keyless codebase graph for "what depends on X" / impact queries (`tools/graphify/build.sh`) |
| [CONTRIBUTING](../CONTRIBUTING.md) | before you push, branch names, rules CI enforces |
| [Cost and lifecycle](guides/cost-and-lifecycle.md) | budgets, default SKUs, auto-stop, retention, teardown order |

## Operations

| Document | Use it for |
|---|---|
| [Runbooks](runbooks/README.md) | secret rotation, rollback, lock recovery, quarantine, CI speed, teardown, break-glass, fault injection |
| [Alert response](runbooks/alert-response.md) (*generated*) and [per-service alert pages](runbooks/alerts/README.md) (*generated*) | procedures behind the optional monitoring content's runbook links |

## Status and evidence

| Document | Use it for |
|---|---|
| [Known limitations](known-limitations.md) | blockers, secrets that land in state, unverified behaviour, exceptions |
| [Implementation checklist](IMPLEMENTATION_CHECKLIST.md) | per-requirement status with links to the implementing files |
| [Evidence](evidence/README.md) | what counts as evidence; [validation results](evidence/validation-results.md) of the static and local checks |
