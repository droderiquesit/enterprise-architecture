# Datadog fleet collection: per-resource matrix (package 3.0.0)

This guide shows how every resource type of the fleet sends its telemetry to Datadog with the observability package
defaults, which Datadog features apply, and which combinations Datadog does not support.

| Default | Policy setting (`observability/config/fleet-policy.yaml`) |
|---|---|
| Observability Pipelines as the log pipeline | `log_pipeline = observability_pipelines` |
| The Datadog Agent collects logs wherever it runs | `logs.node_collector = agent` |
| Datadog tracing libraries | `apm.mode = datadog` |
| Managed runtimes reach the in-VNet APM gateway | `apm.managed_runtime_path = agent_gateway` |
| Continuous Profiler on | `profiling.enabled = true` |

The machine-readable version is [`catalog/telemetry-capabilities.yaml`](../../catalog/telemetry-capabilities.yaml),
rendered to [`docs/coverage/telemetry-capability-matrix.md`](../coverage/telemetry-capability-matrix.md).
Module-level rules (duplicate prevention, robustness per hop) are in
[`observability/modules/README-transport.md`](../../observability/modules/README-transport.md).

Status: implemented and tested offline. Locally verified with docker:

* Fluent Bit 5.1.3 -> the Worker's fluent source;
* the VRL programs;
* the Worker 2.22.0 bootstrap;
* the APM gateway Agent 7.84.2: DSV secret backend, non-local traces, health;
* serverless-init 1.10.4 secret handling;
* `helm template` of the datadog chart 3.253.2 and the observability-pipelines-worker chart 2.22.0.

The application libraries were verified by the app tracer builder against a real Agent 7.84.2: ddtrace 4.15.6 and
dd-trace-dotnet 3.55.1 traces, a .NET -> Python 128-bit trace, log correlation, DogStatsD custom metrics, and Python
and .NET profiles through the Agent profiling proxy.

**Not verified live:**

* the Worker running the pipeline (it needs a Datadog org and Remote Configuration);
* Kafka SASL to Event Hubs;
* SSI and profiler injection in a real cluster;
* the APM gateway on Azure Container Apps.

## 1. One fleet inventory input

Every resource is listed once: in the onboarding manifests (rendered `resources`), or in the contracts the lab
diagnostics root discovers. `modules/fleet-inventory` turns the list into a collection plan with exactly one
collector per signal. `terraform output collection_matrix` of
[`examples/existing-environment`](../../observability/examples/existing-environment/README.md) prints the plan.

## 2. Matrix per resource type

| Resource type | App logs | Traces | Profiles | Custom / runtime metrics | Platform metrics | Platform logs | DBM / RUM |
|---|---|---|---|---|---|---|---|
| AKS pods | Agent DaemonSet -> OP Worker | SSI (admission controller) -> node Agent | SSI `DD_PROFILING_ENABLED=auto` | DogStatsD -> node Agent | Azure integration | diagnostic settings -> Event Hubs -> Worker | DBM cluster checks |
| Linux VM / VMSS | host Agent file tail -> Worker | host SSI -> local Agent | host SSI `auto` | DogStatsD `localhost` | Azure integration + Agent | - | Agent DBM on SQL VMs |
| Windows VM / VMSS | Fluent Bit service -> Worker | OpenTelemetry -> Agent OTLP | **no** (see 4) | OTel -> Agent | Azure integration + Agent | - | - |
| Container Apps / ACI | Fluent Bit sidecar -> Worker | library in image -> APM gateway | library -> APM gateway | **no DogStatsD** behind the gateway; serverless-init opt-in | Azure integration | system logs -> Worker | - |
| Container Apps jobs | console logs -> Event Hubs -> Worker | as Container Apps | partial (short runs) | as Container Apps | Azure integration | as Container Apps | - |
| App Service Linux / Windows code | console / app logs -> Event Hubs -> Worker | library (`Datadog.Trace.Bundle`, `ddtrace`) -> APM gateway (VNet integration) | yes (.NET Linux / Windows x64, Python Linux) | no DogStatsD | Azure integration | HTTP / platform logs -> Worker | - |
| App Service Windows container | as above | partial (not a documented Datadog target) | partial | no DogStatsD | Azure integration | as above | - |
| Functions (all plans), Durable Functions | `FunctionAppLogs` -> Event Hubs -> Worker | **OpenTelemetry** -> OTel gateway (package exception) | **no** | OTel | Azure integration | as App Service | - |
| Logic Apps | `WorkflowRuntime` -> Event Hubs -> Worker | none | n/a | - | Azure integration | - | - |
| Batch | Fluent Bit (job preparation) -> Worker | OpenTelemetry | no | OTel | Azure integration | - | - |
| Static Web Apps (browser) | - | RUM -> APM (`allowedTracingUrls`, `datadog` + `tracecontext`) | n/a | RUM | - | - | **RUM** (create / existing, replay 0) |
| Databases (SQL, PostgreSQL, MySQL) | - | client spans + `DD_DBM_PROPAGATION_MODE=full` | n/a | - | Azure integration | diagnostic settings -> Worker | **DBM** (Agent checks: ACI or AKS cluster checks) |
| Subscription / tenant | - | - | - | - | - | Activity Log / Entra ID -> Event Hub -> Worker | - |

With `log_pipeline = fluent_bit_direct` every "-> Worker" becomes the 2.x path:

* Fluent Bit to the Datadog intake;
* the Fluent Bit aggregator for Event Hubs;
* the Fluent Bit DaemonSet on AKS and the host service on VMs.

With `apm.mode = otel` traces follow the 2.x OpenTelemetry path, and Datadog profiling is off.

## 3. APM library contract (`apm.mode = datadog`)

Emitted by `modules/instrumentation` (from `modules/fleet-policy`) and agreed with the application libraries
(`applications/shared/python/hello_common`, `applications/dotnet`).

| Variable | Value | Why |
|---|---|---|
| `TELEMETRY_SDK` | `datadog` | the app starts the Datadog tracer and never the OpenTelemetry SDK (one tracer per process) |
| `DD_TRACE_OTEL_ENABLED` | `true` | manual OpenTelemetry-API / `Activity` spans of the apps flow into the Datadog tracer instead of being dropped |
| `DD_ENV`, `DD_SERVICE`, `DD_VERSION`, `DD_TAGS` | tag policy | unified service tagging; `DD_TAGS` carries team, owner, domain, tier, ... |
| `DD_TRACE_REMOVE_INTEGRATION_SERVICE_NAMES_ENABLED` | `true` | without it, .NET HTTP client spans get services such as `hello-orders-api-http-client` |
| `DD_LOGS_INJECTION` | `true` | trace / span ids in logs (correlation) |
| `DD_METRICS_OTEL_ENABLED` | `false` | custom metrics go to DogStatsD |
| `DD_AGENT_HOST` + `DD_DOGSTATSD_PORT` / `DD_DOGSTATSD_URL` | AKS: `status.hostIP` + 8125; hosts and serverless-init: `udp://localhost:8125` | DogStatsD target |
| `DD_RUNTIME_METRICS_ENABLED` | `true` only next to an Agent | runtime metrics use DogStatsD |
| `DD_TRACE_AGENT_URL` | `http://<apm-gateway>:8126` (managed runtimes) | traces and profiles to the in-VNet Agent |
| `DD_DBM_PROPAGATION_MODE` | `full` | DBM <-> APM links |
| `DD_DATA_STREAMS_ENABLED`, `AZURE_EXPERIMENTAL_ENABLE_ACTIVITY_SOURCE` | `true` (.NET) | Data Streams Monitoring for Azure Service Bus (Datadog supports it for .NET) |
| `DD_TRACE_SAMPLE_RATE` | only when `apm.sample_rate` is set | otherwise the Agent decides (adaptive / remote) |
| `OTEL_EXPORTER_OTLP_*`, `OTEL_SDK_DISABLED`, `OTEL_RESOURCE_ATTRIBUTES` | **never** in this mode | Datadog maps `OTEL_RESOURCE_ATTRIBUTES` to `DD_TAGS` (duplicate tags) |

Agent side: `apm.ignore_resources` (`GET /healthz`, `GET /readyz`, `GET /version`, `GET /api/healthz`) becomes
`DD_APM_IGNORE_RESOURCES` / `apm_config.ignore_resources` on every Agent, because the .NET tracer traces the health
probes.

## 4. Continuous Profiler support

Datadog documentation was checked on 2026-10-09/10:

* the per-language enabling pages;
* the supported versions page;
* the Azure App Service, Container Apps and Functions serverless pages.

| Runtime / hosting | Supported | Package setting | Profile types (fleet policy defaults) |
|---|---|---|---|
| .NET on AKS / Linux VMs (SSI) | yes | `DD_PROFILING_ENABLED=auto` (SSI profiles eligible processes) | CPU, wall time, exceptions, GC on; lock off; allocation and heap off (**preview**, higher overhead); code hotspots + endpoint profiling on |
| .NET on Container Apps, ACI, App Service Linux / Windows (x64) | yes | `DD_PROFILING_ENABLED=true` + CLR profiler env from `modules/instrumentation` | as above |
| .NET on Azure Function Apps | **no** (Datadog: Function Apps not supported) | off, reason reported | - |
| .NET on ARM64 | **no** (x64 only in this package) | - | - |
| Python on AKS / Linux VMs / Container Apps / App Service Linux | yes (POSIX) | `auto` (SSI) / `true` | stack, lock, memory, heap, timeline |
| Python on Azure Functions | **preview** only | off by package policy | - |
| Python on Windows | **no** (the CPU profile is POSIX only) | off | - |
| Node / Java (where used) | yes | library defaults | library defaults |
| Any runtime with `apm.mode = otel` | **no**: Datadog profiling needs the Datadog library | off; Python only: `profiling.otel_mode = python_preview` adds the ddtrace profiler next to the OTel SDK with `DD_PROFILING_PREVIEW_OTEL_CONTEXT_ENABLED=true` (preview) | Python types |
| Windows VM services | **no** in this package (they stay on OTel: SSI on Windows covers IIS only) | off | - |
| Logic Apps, browsers | n/a | - | - |

Profiles carry `DD_ENV` / `DD_SERVICE` / `DD_VERSION` and `DD_TAGS`, so they join the traces (code hotspots) and the
tag-policy scopes. They upload through the same Agent as the traces: the node Agent, the host Agent, the APM gateway
(trace-agent profiling proxy) or serverless-init.

Overhead guardrails:

* Allocation, heap and lock profiling stay off by default.
* SSI uses `auto`.
* `profiling.enabled: false` turns profiling off per environment, architecture or workload.

What applications must provide:

* the Datadog library: SSI injects it on AKS and Linux hosts; the image carries `dd-trace-dotnet` (`/opt/datadog`) or
  `ddtrace` elsewhere, and App Service and Functions use `Datadog.Trace.Bundle`;
* for Python, `import ddtrace.auto` or `ddtrace-run`.

The `app_requirements` output of `modules/instrumentation` lists them per workload.

## 5. Unsupported or excluded combinations

| Combination | Why | Package behaviour |
|---|---|---|
| Datadog tracers on Azure Functions / Durable Functions | Datadog documents neither the Functions host spans nor Durable Functions V2 orchestration spans for this setup | `architectures.functions.apm.mode: otel` (OpenTelemetry -> OTel gateway) |
| SSI on Windows services | Windows SSI is IIS only | Windows hosts fall back to OpenTelemetry |
| DogStatsD behind the APM gateway (Container Apps, ACI, App Service) | DogStatsD is UDP / UDS; Container Apps ingress is TCP | runtime metrics off; custom metrics need `managed_runtime_path = serverless_init` (ACA) or `apm.mode = otel` for that workload |
| serverless-init with Delinea DSV | serverless-init 1.10.4 does not resolve `ENC[]` (verified: it sent the literal value) | opt-in only; `DD_API_KEY` must be a Container Apps secret (documented exception to ADR-0001 §14) |
| Functions Consumption (Windows) and the APM gateway | no VNet integration | OpenTelemetry (functions exception) to the serverless OTLP intake |
| Agent on Container Apps / App Service / Functions nodes | no node access | Fluent Bit sidecar or Event Hubs for logs; APM gateway for traces |
| Profiling in otel mode | needs the Datadog library | off (Python preview opt-in) |
| Event Hubs read twice | the aggregator and the Worker would both consume | the aggregator is not deployed in OP mode |

## 6. Fleet management

* **Agent version:** pinned by `agent.version` (7.84.2) for Helm `agents.image.tag`, the host installers and the APM
  gateway image. The Worker is pinned by `op_worker.version` (2.22.0, chart 2.22.0).
* **Remote Configuration** is on for every Agent. It is required by the Worker and used for remote sampling and
  Fleet Automation.
* **Remote updates** are off by default (`agent.remote_updates`). Turn them on together with an upgrade window
  (`agent.upgrade_schedule`, `modules/fleet-automation` -> `datadog_fleet_schedule`).
* Consistent Agent configuration everywhere:
  * tags from the tag policy;
  * logs to the Worker;
  * OTLP receivers only on localhost / host IP;
  * process collection off unless enabled;
  * `apm.ignore_resources`.
