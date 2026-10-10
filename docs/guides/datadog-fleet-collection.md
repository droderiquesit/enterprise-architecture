# Datadog fleet collection: one path per platform (package 4.0.0)

This guide shows how every resource type of the fleet sends its telemetry to Datadog with the observability package
defaults, which Datadog features apply, and which combinations Datadog does not support. Version 4.0.0 has **one
Datadog collection path per platform**: the Datadog Agent wherever an Agent can run (nodes, hosts, and as a sidecar in
ACI container groups), serverless-init on Container Apps, and Azure diagnostic settings where neither can run.
Fluent Bit is only the `log_pipeline = fluent_bit_direct` fallback (and the Batch node collector).

| Default | Policy setting (`observability/config/fleet-policy.yaml`) |
|---|---|
| Observability Pipelines Worker as the central log hop | `log_pipeline = observability_pipelines` |
| One log collector per architecture | `architectures.<arch>.logs.collector`: `agent` (aks, vm, vmss - Linux and Windows), `agent_sidecar` (aci), `serverless_init` (aca), `azure` (appservice, functions, logicapp), `fluent_bit` (batch) |
| Datadog tracing libraries | `apm.mode = datadog` |
| Managed runtimes: a Datadog sidecar next to the app | `architectures.aca.apm.managed_runtime_path = serverless_init`, `architectures.aci.apm.managed_runtime_path = agent_sidecar` |
| Continuous Profiler on | `profiling.enabled = true` |
| One Agent pin for the whole fleet | `agent.image` + `agent.version` (7.84.2; same version as `versions.yaml` `images.datadog_agent`), `agent.serverless_init` (1.10.4) |
| Remote Configuration on, remote updates off | `agent.remote_configuration = true`, `agent.remote_updates = false` |

The machine-readable version is [`catalog/telemetry-capabilities.yaml`](../../catalog/telemetry-capabilities.yaml),
rendered to [`docs/coverage/telemetry-capability-matrix.md`](../coverage/telemetry-capability-matrix.md).
Module-level rules (duplicate prevention, robustness per hop) are in
[`observability/modules/README-transport.md`](../../observability/modules/README-transport.md).

Status: implemented and tested offline (Terraform tests with mock providers, local docker tests). Locally verified with
docker (synthetic data, mock intake, mock Delinea DSV):

* ACI Datadog Agent sidecar (Agent 7.84.2, `observability/tests/transport/test_agent_sidecar.py`): the rendered
  `datadog.yaml` / log config and the module's start command; the API key `ENC[dsv://...]` resolved by the dsv-fetch
  secret backend from a mock DSV; a trace on `localhost:8126`, a DogStatsD metric on `localhost:8125` and lines of the
  shared log file arrive (logs at an Observability Pipelines Worker stand-in, the Worker's Datadog Agent source engine);
* Container Apps serverless-init 1.10.4 (same test file): its start command resolves `DD_API_KEY` with dsv-fetch, the
  sidecar tails `DD_SERVERLESS_LOG_PATH` and ships to the Worker stand-in via `DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_*`;
* Fluent Bit 5.1.3 -> the Worker's fluent source (fallback), the VRL programs, the Worker 2.22.0 bootstrap, the APM
  gateway Agent (DSV secret backend, non-local traces, health), `helm template` of the datadog chart and the Worker chart.

The application libraries were verified by the app tracer builder against a real Agent 7.84.2: ddtrace 4.15.6 and
dd-trace-dotnet 3.55.1 traces, a .NET -> Python 128-bit trace, log correlation, DogStatsD custom metrics, and Python
and .NET profiles through the Agent profiling proxy.

**Not verified live (no Azure, no Datadog org):**

* the Worker running the pipeline (it needs a Datadog org and Remote Configuration);
* the ACI Agent sidecar and serverless-init on Azure (IMDS / `IDENTITY_ENDPOINT` tokens from the sidecars, uid 65532
  init containers writing into ACI / Container Apps EmptyDir volumes);
* Kafka SASL to Event Hubs; SSI and profiler injection in a real cluster; the APM gateway on Azure Container Apps.

## 1. One fleet inventory input

Every resource is listed once: in the onboarding manifests (rendered `resources`), or in the contracts the lab
diagnostics root discovers. `modules/fleet-inventory` turns the list into a collection plan with exactly one
collector per signal. `terraform output collection_matrix` of
[`examples/existing-environment`](../../observability/examples/existing-environment/README.md) prints the plan.

## 2. Matrix per resource type

"-> Worker" = the Observability Pipelines Worker (Datadog Agent source `:8282` for Agents / serverless-init, Kafka
source for Event Hubs), which applies the tag policy and sends to Datadog Logs.

| Resource type | Collector (deployed by) | App logs | Traces | Profiles | Custom / runtime metrics | Platform metrics | Platform logs | DBM / RUM |
|---|---|---|---|---|---|---|---|---|
| AKS pods | Datadog Agent DaemonSet + Cluster Agent (Datadog Helm chart, `modules/kubernetes`) | Agent (container stdout) -> Worker | SSI (admission controller) -> node Agent | SSI `DD_PROFILING_ENABLED=auto` | DogStatsD -> node Agent | Azure integration | diagnostic settings -> Event Hubs -> Worker | DBM as cluster checks |
| Linux VM / VMSS | Datadog Agent installed by an Azure VM Application, assigned by Azure Policy to resources tagged `datadog:enabled` (`modules/host-agents`) | Agent file tail -> Worker | host SSI -> local Agent | host SSI `auto` | DogStatsD `localhost` | Azure integration + Agent | - | Agent DBM on SQL VMs |
| Windows VM / VMSS | same (Windows VM Application version) | Agent file tail -> Worker (no Fluent Bit) | OpenTelemetry -> Agent OTLP | **no** (see 4) | OTel -> Agent | Azure integration + Agent | - | - |
| Container Apps | **serverless-init sidecar** per replica (`modules/instrumentation` `container_app_patch`) | serverless-init tails `LOG_FILE_PATH` on a shared EmptyDir -> Worker | library in image -> serverless-init (`localhost:8126`) | library -> serverless-init | DogStatsD `udp://localhost:8125` -> serverless-init | Azure integration | system logs -> Worker | - |
| ACI | **Datadog Agent sidecar** per container group (`modules/instrumentation` `aci_sidecar`) | Agent tails `LOG_FILE_PATH` on a shared emptyDir -> Worker | library in image -> Agent sidecar (`localhost:8126`) | library -> Agent sidecar | DogStatsD `udp://localhost:8125` -> Agent sidecar | Azure integration | - | separate ACI DBM Agent only when no cluster exists |
| Container Apps jobs | none (run-to-completion) | console -> diagnostic settings -> Event Hubs -> Worker (`logs.collector = azure`) | library -> APM gateway | partial (short runs) | **no DogStatsD** | Azure integration | as Container Apps | - |
| App Service Linux / Windows code | Azure diagnostic settings | console / app logs -> Event Hubs -> Worker | **OpenTelemetry** -> OTel gateway by default (`architectures.appservice`); per workload `apm.mode = datadog`: library (`Datadog.Trace.Bundle`, `ddtrace`) -> APM gateway (VNet integration) | default: no; per-workload datadog: yes (.NET Linux / Windows x64, Python Linux) | default: OTel; per-workload datadog: no DogStatsD | Azure integration | HTTP / platform logs -> Worker | - |
| App Service Windows container | as above | as above | partial (not a documented Datadog target) | partial | no DogStatsD | Azure integration | as above | - |
| Functions (all plans), Durable Functions | Azure diagnostic settings | `FunctionAppLogs` -> Event Hubs -> Worker | **OpenTelemetry** -> OTel gateway (package exception) | **no** | OTel | Azure integration | as App Service | - |
| Logic Apps | Azure diagnostic settings | `WorkflowRuntime` -> Event Hubs -> Worker | none | n/a | - | Azure integration | - | - |
| Batch | Fluent Bit (job preparation task; no Agent on Batch pools) | Fluent Bit -> Worker | OpenTelemetry | no | OTel | Azure integration | - | - |
| Static Web Apps (browser) | Browser RUM SDK | - | RUM -> APM (`allowedTracingUrls`, `datadog` + `tracecontext`) | n/a | RUM | - | - | **RUM** (create / existing, replay 0) |
| Databases (SQL, PostgreSQL, MySQL) | Agent DBM checks | - | client spans + `DD_DBM_PROPAGATION_MODE=full` | n/a | - | Azure integration | diagnostic settings -> Worker | **DBM**: cluster checks when an AKS cluster exists, else an ACI DBM Agent |
| Subscription / tenant | Azure diagnostic settings | - | - | - | - | - | Activity Log / Entra ID -> Event Hub -> Worker | - |

How each Datadog component gets the API key (Delinea DSV only - ADR-0001 section 14; nothing in Terraform state, VM
extension settings, run-command parameters, VM Application parameters or IaC-set env vars):

| Component | Key path |
|---|---|
| AKS node Agent, Cluster Agent, cluster-checks runners | `dsv-fetch agent-backend` as `secret_backend_command` (binary copied by an init container) |
| Linux / Windows VMs, VMSS | the VM Application installs the Agent and `dsv-fetch` / `dsv-fetch.exe` (`secret_backend_command`); the host identity reads the key path |
| ACI Agent sidecar | init container `dsv-fetch-install` copies the static binary into an emptyDir (ACI init containers have no managed identity, so it makes no DSV call); the Agent's start command installs it root-owned 0500 and the Agent resolves `api_key: ENC[dsv://...]` with the group identity |
| Container Apps serverless-init | init container `dsv-fetch-install` copies the binary (no identity needed, every workload profile); the sidecar runs `dsv-fetch init --format dotenv` into its own `/tmp`, sources and truncates the file and execs `/datadog-init` (serverless-init has no secret backend) |
| Observability Pipelines Worker, APM gateway | dsv-fetch dotenv / secret backend (`modules/telemetry-transport`) |

With `log_pipeline = fluent_bit_direct` (fallback) every "-> Worker" becomes the 2.x path: Fluent Bit sidecars on
Container Apps / ACI (the serverless-init / Agent sidecars keep traces and DogStatsD, their log collection is off),
the Fluent Bit DaemonSet on AKS and the host service on VMs, all shipping to the Datadog intake, and the Fluent Bit
aggregator for Event Hubs. With `apm.mode = otel` traces follow the 2.x OpenTelemetry path, and Datadog profiling is off;
the Container Apps / ACI sidecars still collect the logs.

### ACI Agent sidecar: design notes and cost

* **Logs through a shared file, not a socket.** The app writes JSON lines to `LOG_FILE_PATH` (`/var/log/app/app.log`
  on the `app-logs` emptyDir) and the Agent tails it (`conf.d/app.d` file source with `service` / `source`). The apps
  already implement `LOG_FILE_PATH` for every file tailer (serverless-init, hosts, the Fluent Bit fallback), the file
  buffers across Agent restarts, and the Agent TCP/UDP log listener would need a network log handler in every app.
* **Localhost only.** `apm_non_local_traffic` and `dogstatsd_non_local_traffic` are off: containers of a group share one
  network namespace, nothing outside the group can send to the sidecar.
* **Sizing.** Default 0.25 vCPU / 0.5 GB (`agent.sidecar` in the fleet policy, `agent_sidecar` per workload). ACI bills
  vCPU-seconds and GB-seconds of every container: at Linux pay-as-you-go rates the sidecar costs about USD 11 per
  always-on group per month (check current Azure pricing for the region). Datadog bills each group as one
  infrastructure host and, with traces, one APM host (the Agent hostname is the container group name).
* **No container runtime socket.** Datadog documents no ACI-specific Agent integration; the standard image runs without
  container autodiscovery or live containers (Azure integration metrics `azure.containerinstance_*` cover the group).

### Container Apps serverless-init: logs

In **sidecar mode** serverless-init collects logs by tailing a file on a shared volume (`DD_SERVERLESS_LOG_PATH`,
Datadog docs "Azure Container Apps - sidecar"); it cannot read another container's stdout/stderr (that is the
in-container wrapper mode, where the image's entrypoint is `/datadog-init`). The package therefore sets
`DD_LOGS_ENABLED=true`, `DD_SERVERLESS_LOG_PATH=$LOG_FILE_PATH`, `DD_SOURCE` / `DD_SERVICE` / `DD_TAGS` on the sidecar and
mounts the `app-logs` EmptyDir in both containers. In Observability Pipelines mode the sidecar sends to the Worker
(`DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_ENABLED` / `_URL`; not documented by Datadog for serverless-init, verified
locally with 1.10.4). Without the Worker URL in the transport contract (`aggregator.agent_logs_url`) the sidecars do not
collect logs and the plan warns - there is no direct-to-intake bypass of the Worker.

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
| `DD_AGENT_HOST` + `DD_DOGSTATSD_PORT` / `DD_DOGSTATSD_URL` | AKS: `status.hostIP` + 8125; hosts, ACI Agent sidecar and serverless-init: `udp://localhost:8125` | DogStatsD target |
| `DD_RUNTIME_METRICS_ENABLED` | `true` only next to an Agent (node, host, ACI sidecar, serverless-init) | runtime metrics use DogStatsD |
| `DD_TRACE_AGENT_URL` | unset next to a local Agent / sidecar (`localhost:8126`); `http://<apm-gateway>:8126` on the agent_gateway path | traces and profiles |
| `DD_DBM_PROPAGATION_MODE` | `full` | DBM <-> APM links |
| `DD_DATA_STREAMS_ENABLED`, `AZURE_EXPERIMENTAL_ENABLE_ACTIVITY_SOURCE` | `true` (.NET) | Data Streams Monitoring for Azure Service Bus (Datadog supports it for .NET) |
| `DD_TRACE_SAMPLE_RATE` | only when `apm.sample_rate` is set | otherwise the Agent decides (adaptive / remote) |
| `OTEL_EXPORTER_OTLP_*`, `OTEL_SDK_DISABLED`, `OTEL_RESOURCE_ATTRIBUTES` | **never** in this mode | Datadog maps `OTEL_RESOURCE_ATTRIBUTES` to `DD_TAGS` (duplicate tags) |
| `LOG_FILE_PATH` | Container Apps / ACI / hosts | the file the local collector tails |

Agent side: `apm.ignore_resources` (`GET /healthz`, `GET /readyz`, `GET /version`, `GET /api/healthz`) becomes
`DD_APM_IGNORE_RESOURCES` / `apm_config.ignore_resources` on every Agent (and serverless-init), because the .NET tracer
traces the health probes.

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
| Python on AKS / Linux VMs / Container Apps / ACI / App Service Linux | yes (POSIX) | `auto` (SSI) / `true` | stack, lock, memory, heap, timeline |
| Python on Azure Functions | **preview** only | off by package policy | - |
| Python on Windows | **no** (the CPU profile is POSIX only) | off | - |
| Node / Java (where used) | yes | library defaults | library defaults |
| Any runtime with `apm.mode = otel` | **no**: Datadog profiling needs the Datadog library | off; Python only: `profiling.otel_mode = python_preview` adds the ddtrace profiler next to the OTel SDK with `DD_PROFILING_PREVIEW_OTEL_CONTEXT_ENABLED=true` (preview) | Python types |
| Windows VM services | **no** in this package (they stay on OTel: SSI on Windows covers IIS only) | off | - |
| Logic Apps, browsers | n/a | - | - |

Profiles carry `DD_ENV` / `DD_SERVICE` / `DD_VERSION` and `DD_TAGS`, so they join the traces (code hotspots) and the
tag-policy scopes. They upload through the same Agent as the traces: the node Agent, the host Agent, the ACI Agent
sidecar, serverless-init or the APM gateway (trace-agent profiling proxy).

Overhead guardrails:

* Allocation, heap and lock profiling stay off by default.
* SSI uses `auto`.
* `profiling.enabled: false` turns profiling off per environment, architecture or workload.

What applications must provide:

* the Datadog library: SSI injects it on AKS and Linux hosts; the image carries `dd-trace-dotnet` (`/opt/datadog`) or
  `ddtrace` elsewhere, and App Service and Functions use `Datadog.Trace.Bundle`;
* for Python, `import ddtrace.auto` or `ddtrace-run`;
* on Container Apps and ACI: JSON log lines to `LOG_FILE_PATH`.

The `app_requirements` output of `modules/instrumentation` lists them per workload.

## 5. Unsupported or excluded combinations

| Combination | Why | Package behaviour |
|---|---|---|
| Datadog tracers on Azure Functions / Durable Functions | Datadog documents neither the Functions host spans nor Durable Functions V2 orchestration spans for this setup | `architectures.functions.apm.mode: otel` (OpenTelemetry -> OTel gateway) |
| SSI on Windows services | Windows SSI is IIS only | Windows hosts fall back to OpenTelemetry for traces (logs: Agent) |
| DogStatsD behind the APM gateway (Container Apps jobs, App Service per-workload datadog, ACA / ACI `managed_runtime_path = agent_gateway` opt-outs) | DogStatsD is UDP / UDS; Container Apps ingress is TCP | Container Apps default to serverless-init and ACI to the Agent sidecar (DogStatsD on localhost); App Service defaults to `apm.mode = otel`; elsewhere runtime metrics off and custom metrics need `apm.mode = otel` for that workload |
| serverless-init with Delinea DSV | serverless-init 1.10.4 reads `DD_API_KEY` only from its environment (no `ENC[]`, no `datadog.yaml` key - verified) | its start command runs the dsv-fetch binary (installed by the `dsv-fetch-install` init container) and sources the dotenv from its own `/tmp`: `/bin/sh -c '<dsv-bin>/dsv-fetch init --out /tmp/dsv-fetch --format dotenv ... && set -a && . <file> && set +a && : > <file> && exec /datadog-init'` (no Container Apps secret, nothing in state, nothing on a shared volume) |
| serverless-init reading the app's stdout | sidecar mode tails files only | apps write `LOG_FILE_PATH` on the shared EmptyDir |
| Datadog App Service sidecar | not integrated in the package modules | App Service workloads default to OpenTelemetry (`architectures.appservice.apm.mode: otel`) |
| Functions Consumption (Windows) and the APM gateway | no VNet integration | OpenTelemetry (functions exception) to the serverless OTLP intake |
| Agent on Container Apps / App Service / Functions nodes | no node access | serverless-init sidecar (Container Apps) or Event Hubs (App Service / Functions) for logs |
| Sidecars in Container Apps jobs | a sidecar keeps run-to-completion executions alive | `logs.collector = azure`, tracer -> APM gateway |
| Profiling in otel mode | needs the Datadog library | off (Python preview opt-in) |
| Event Hubs read twice | the aggregator and the Worker would both consume | the aggregator is not deployed in OP mode |
| `agent_sidecar` outside ACI, `serverless_init` outside Container Apps | not a collection path there | the fleet policy falls back to the architecture default and reports `log_collector_reason` |

## 6. Fleet management

* **Agent version:** one pin, `agent.image:agent.version` (7.84.2) in the fleet policy, matching `versions.yaml`
  `images.datadog_agent`, for the Helm chart, the VM Application versions, the ACI Agent sidecar and the APM gateway;
  `agent.serverless_init` pins serverless-init (1.10.4). The pipeline promotes a new pin dev -> test -> prod. The
  Worker is pinned by `op_worker.version` (2.22.0, chart 2.22.0).
* **Fleet Automation** is used for inventory (which Agents run where, with which configuration). **Remote updates**
  stay off by default (`agent.remote_updates`, `DD_REMOTE_UPDATES`); turn them on only together with an upgrade
  window (`agent.upgrade_schedule`, `modules/fleet-automation` -> `datadog_fleet_schedule`).
* Consistent Agent configuration everywhere:
  * tags from the tag policy;
  * logs to the Worker;
  * OTLP receivers, APM and DogStatsD only on localhost / host IP;
  * process collection off unless enabled;
  * `apm.ignore_resources`;
  * the API key only as `ENC[dsv://...]` through the dsv-fetch secret backend.
* **Golden image (optional).** Baking the Agent and dsv-fetch into a VM image is supported but not required: the
  Azure Policy + VM Application path installs the pinned Agent on every tagged VM / VMSS instance (new VMSS instances
  get it from the scale set model). A golden image only shortens first boot; it must carry the same pin and still
  read the key from DSV (no key in the image), and the policy keeps the application version authoritative.

## 7. Remote Configuration governance

Remote Configuration stays **on** for every Agent: the Observability Pipelines Worker requires it, and it carries
Fleet Automation inventory, remote APM sampling and Agent flares. Components poll Datadog over HTTPS (443) with their
API key; Datadog returns only changes relevant to the requesting component, and the component validates their
signature (Datadog docs, Remote Configuration). What can change remotely is governed in Datadog, not in this repository:

* **Org and key level:** Remote Configuration is enabled in Organization Settings (`org_management`) and per API key
  (`api_keys_write`). The fleet's ingest key needs it (the Worker refuses to start otherwise). Prefer opting out per
  product over disabling it globally.
* **RBAC:** grant the write permissions only to a small platform role - Fleet Automation `fleet_policies_write`,
  `agent_upgrade_write`, `fleet_flare`; APM `apm_remote_configuration_write`, `apm_service_ingest_write`; Observability
  Pipelines `observability_pipelines_write` / `_deploy` / `_delete`. Everyone else keeps the read permissions.
* **Audit Trail:** Datadog Audit Trail records who changed what (API / application keys, Remote Configuration-backed
  features such as sampling rules, Fleet Automation policies and upgrades, pipeline deployments). Keep Audit Trail
  enabled and route its events to the security team's monitors.
* **Guardrails in the package:** `agent.remote_updates = false` (no remote Agent upgrades), pinned versions promoted by
  the pipeline, and `apm.sample_rate` / `ignore_resources` in Git; a remote sampling change shows up in Audit Trail and
  can be reverted there.

## 8. Accepted risk: the VM / VMSS DSV-reader identity

On VMs and VMSS the Azure Policy attaches a per-environment user-assigned identity that can read **one** DSV path: the
Datadog API key. IMDS hands tokens for an attached identity to **any process on the host**, so every local process (not
only the Datadog Agent) could read that key. This is accepted because:

* the key is an **ingest-only** Datadog API key: it can submit telemetry but cannot read data, query the org or change
  configuration (application keys are never on hosts);
* the identity reads nothing else (one DSV policy, one path; no Azure RBAC role on data planes);
* the key is per environment, rotates in DSV (Agents re-read it through the secret backend) and its usage is visible
  in Datadog (usage attribution, Audit Trail for key events).

A workload that cannot accept it (e.g. untrusted multi-tenant code on the host) uses a separate host-specific key path
and identity, or the optional golden image with a host-scoped identity; containerised platforms (AKS, ACI, Container
Apps) scope the identity to the workload.
