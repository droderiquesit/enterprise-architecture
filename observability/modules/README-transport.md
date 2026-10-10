# Telemetry transport and collection: authoritative paths, robustness, duplicate prevention (3.0.0)

This page is the single reference for **who collects what, where** in the portable Datadog package (`observability/`).
The decisions come from `config/fleet-policy.yaml` (`modules/fleet-policy`, `modules/fleet-inventory`). Every rule
below is enforced by code and covered by a test; the test is named in brackets.

Status (ADR §11): everything is **implemented**. The following are **locally verified** with docker
(`tests/transport/`):

* the VRL programs;
* Fluent Bit -> Worker forward;
* the Worker bootstrap (fail closed);
* the APM gateway Agent (DSV secret backend, non-local traces, health);
* the OTel gateway;
* the DBM checks;
* the Linux installer.

Nothing is **deployed** or **verified** live: this sandbox has no Azure or Datadog credentials.

## 1. Authoritative path per resource type (package defaults)

`log_pipeline = observability_pipelines`, `logs.node_collector = agent`, `apm.mode = datadog`,
`apm.managed_runtime_path = agent_gateway`. The 2.x paths come back with `fluent_bit_direct` and `otel`.

| Resource / workload | Application logs | Traces + profiles | Custom / runtime metrics | Platform metrics + tags | Platform logs |
|---|---|---|---|---|---|
| AKS pods | Node **Datadog Agent** (container logs, `ad.datadoghq.com/<c>.logs`) -> Worker `datadog_agent` source :8282 | **SSI** (Cluster Agent admission controller, `targets` per namespace, `ddTraceVersions`, `DD_PROFILING_ENABLED=auto`) -> node Agent :8126 | DogStatsD to the node Agent (`DD_AGENT_HOST` = `status.hostIP`, `DD_DOGSTATSD_PORT` 8125) | Azure integration | AKS diagnostic settings -> Event Hubs -> Worker |
| Linux VM / VMSS | Host **Agent** tails the app log file (`conf.d/eh-applogs.d`) -> Worker :8282 | **host SSI** (installer `DD_APM_INSTRUMENTATION_ENABLED=host`) -> local Agent | DogStatsD `udp://localhost:8125` | Azure integration + Agent | - |
| Windows VM / VMSS | **Fluent Bit** service -> forward -> Worker :24224 | OpenTelemetry -> Agent OTLP (SSI on Windows is IIS only) | OTel metrics -> Agent OTLP | Azure integration + Agent | - |
| Container Apps (apps), ACI | **Fluent Bit sidecar** tails `LOG_FILE_PATH` -> forward -> Worker :24224 (no API key on the edge) | Datadog library in the image -> **APM gateway** (Agent on ACA, internal TCP 8126; `DD_TRACE_AGENT_URL`). Opt-in on ACA: serverless-init sidecar | off behind the gateway (DogStatsD has no TCP transport); serverless-init: localhost | Azure integration | `ContainerAppSystemLogs` -> Worker |
| Container Apps **jobs** | stdout -> `ContainerAppConsoleLogs` -> Event Hub `app-logs` -> Worker (allow-list `aca_console_allow`) | as Container Apps | as Container Apps | Azure integration | as Container Apps |
| App Service (Linux / Windows code, containers) | `AppServiceConsoleLogs` / `AppServiceAppLogs` -> Event Hubs -> Worker | Datadog library (.NET `Datadog.Trace.Bundle`, Python `ddtrace`) -> APM gateway over VNet integration | as Container Apps | Azure integration | `AppServiceHTTPLogs`, ... -> Worker |
| Functions, Durable Functions | `FunctionAppLogs` -> Event Hubs -> Worker | **OpenTelemetry** (exception: Datadog documents neither the Functions host nor Durable V2 spans) -> OTel gateway | OTel -> gateway | Azure integration | as App Service |
| Logic Apps | `WorkflowRuntime` -> Event Hubs -> Worker | none | - | Azure integration | - |
| Batch nodes | Fluent Bit (job preparation task) -> forward -> Worker (no key on the node) | OpenTelemetry -> gateway | OTel | Azure integration | - |
| Browser (Static Web Apps) | - | **RUM** (`modules/rum`, create or existing; `allowedTracingUrls` with `propagatorTypes [datadog, tracecontext]`; replay 0) | RUM | - | - |
| Databases | - | DBM <-> APM propagation `DD_DBM_PROPAGATION_MODE=full` in the tracers | Agent DBM checks (`modules/dbm`: ACI or AKS cluster checks) | Azure integration | diagnostic settings -> Worker |
| Subscription / tenant | - | - | - | - | Activity Log / Entra ID (`modules/azure-logs`) -> Event Hub `activity-logs` -> Worker |

One inventory drives the plan. `modules/fleet-inventory` takes every resource (`id`, `type`, `architecture`,
`runtime`, `os_type`, `tags`) and returns, for each signal, exactly one collector, the `diagnostic_targets` for
`modules/diagnostic-settings`, the `scope_tags` for the pipeline, and `dbm_candidates`.
[inventory.tftest]

## 2. The log pipeline (Observability Pipelines)

`modules/observability-pipeline` defines one `datadog_observability_pipeline` per environment.

**Sources**

* `fluent_bit` (24224): edge collectors.
* `datadog_agent` (8282): node and host Agents.
* `kafka`: the Event Hubs (SASL PLAIN, user `$ConnectionString`, `security.protocol=sasl_ssl`).
* `opentelemetry`: off.

**Processor group `app`**

* VRL normalisation of the record.
* Sensitive Data Scanner redaction (the same patterns as the 2.x Fluent Bit `eh_redact` filter).
* VRL tag policy: defaults for missing tags, value maps and normalisation. It never overwrites a value the client set.

**Processor group `azure`**

1. Unwrap and split the `records` array.
2. Shape into the Datadog forwarder form (`ddsource azure.<provider>`, `subscription_id`, `resource_group`, ...).
3. Apply the console allow list.
4. Filter, then dedupe on `correlationId`.
5. Sample per category, then apply the quota.
6. Add the resource-scope tags of the owning service.

**Destinations**

* `datadog_logs` with a disk buffer: at least 256 MiB, default 1 GiB, `when_full = block`.
* An optional Azure Storage archive.

[pipeline.tftest; `test_observability_pipelines.py::test_vrl_programs`]

The Worker (`datadog/observability-pipelines-worker:2.22.0`, pinned by the fleet policy) runs in one of two places.

**On Container Apps** (`modules/telemetry-transport`):

* Internal TCP ingress on 24224 (+ 8282, 8686 health).
* Startup, liveness and readiness probes on `/health`.
* CPU and TCP-connection scale rules, 2-6 replicas.
* One data dir per replica (EmptyDir or Azure Files).
* The dsv-fetch dotenv file (fail closed).

[transport.tftest `observability_pipelines_mode`, `op_dedicated_profile_uses_refresher`; `test_worker_bootstrap_fail_closed_and_env`]

**On AKS** (`modules/kubernetes` `op_worker`, chart `observability-pipelines-worker` 2.22.0):

* A StatefulSet with one PVC per replica, an HPA and a PDB.
* The API key from a dsv-k8s-synced Secret.
* Kafka SASL from `op_worker.secret_env`. The chart renders `valueFrom.secretKeyRef`; checked with `helm template`
  of chart 2.22.0.

[kubernetes.tftest `op_worker_on_aks`]

The Worker needs a live Datadog org at start-up: it validates the API key and downloads the pipeline through Remote
Configuration. The local test stops at API-key validation.

## 3. Robustness per hop

| Hop | Buffering | Retry / backpressure | Self-telemetry |
|---|---|---|---|
| App -> Fluent Bit (sidecar / host) | file tail with offset DB | resumes from the offset after a restart | Fluent Bit metrics (`fluentbit_*_total`), canary |
| Fluent Bit -> Worker (forward) | filesystem storage, `storage.total_limit_size 512M` | `require_ack_response`, `retry_limit no_limits`; `retain_metadata_in_forward_mode false` (the Worker's fluent source rejects the metadata form; verified) | Fluent Bit output retries / errors |
| Agent -> Worker (:8282) | Agent tailer offsets | the Agent retries with backoff; the tailers pause under backpressure | Agent status, `datadog.agent.*` |
| Event Hubs -> Worker (Kafka) | hub retention (1 day by default) is the buffer | consumer group `observability-pipelines`; offsets survive Worker restarts | Worker metrics in Observability Pipelines |
| Worker -> Datadog Logs | **disk buffer** per destination (persistent per replica) | `when_full = block`: backpressure to the sources instead of drops | Worker `/health`, pipeline metrics |
| Tracer -> node Agent / APM gateway | tracer in-memory queue | the tracer drops when the queue is full (documented Datadog behaviour); the gateway scales on TCP connections | trace-agent stats, `datadog.trace_agent.*` |
| OTel SDK -> OTel gateway -> Datadog (otel mode) | `sending_queue` | `retry_on_failure` | `otelcol_*` |

Fail-closed secrets: the Worker command, the dsv-fetch init containers and the Agent secret backend refuse to start
without their DSV-resolved values. No hop falls back to a key in env or config.
[`test_worker_bootstrap_fail_closed_and_env`, `test_apm_gateway_agent_resolves_key_from_dsv`]

## 4. Duplicate-prevention rules

| Rule | Where enforced |
|---|---|
| One application-log collector per line: when the Agent collects (AKS, Linux hosts), the Fluent Bit DaemonSet or host service is not installed (`fluent_bit` release count 0); with `fluent_bit_direct` the Agent's log collection is off | `modules/kubernetes` [`fleet_default_agent_logs_to_op_ssi_profiling`, `op_with_fluent_bit_node_collector`], `modules/host-agents` [hosts.tftest `fleet_default_agent_logs_ssi_op`] |
| Apps never export OTLP logs (`OTEL_LOGS_EXPORTER=none` in otel mode; no OTel variables at all in datadog mode) | `modules/instrumentation` [`datadog_mode_aks_ssi`] |
| One tracer per process: datadog mode emits `TELEMETRY_SDK=datadog` and `DD_TRACE_OTEL_ENABLED=true` (manual OTel-API / Activity spans go into the Datadog tracer); never `OTEL_EXPORTER_OTLP_*`, `OTEL_SDK_DISABLED` or `OTEL_RESOURCE_ATTRIBUTES` (Datadog maps that to `DD_TAGS`, which would duplicate tags) | `modules/fleet-policy`, `modules/instrumentation` |
| Diagnostic settings export app-log categories only for the `eventhub` route; platform categories are an allow list per type | `modules/diagnostic-settings` [diagnostics.tftest] |
| Container Apps environment console logs: exported only when a job needs them; the pipeline keeps only allow-listed jobs | lab diagnostics, VRL `azure_shape` [`test_vrl_programs`] |
| Event Hubs are consumed by exactly one reader: the Worker in OP mode (the Fluent Bit aggregator is not deployed), the aggregator in `fluent_bit_direct` | `modules/telemetry-transport` [transport.tftest `observability_pipelines_mode`] |
| Event Hubs redeliveries: dedupe processor; application categories on non-app hubs are dropped | VRL `azure_unwrap` / `azure_shape` |
| Native Azure log forwarding and the Event Hubs path are mutually exclusive per subscription / tenant | `modules/azure-integration`, `modules/azure-logs` validations |
| Functions OTLP logs at the OTel gateway: accepted and dropped (the `FunctionAppLogs` path carries them) | `test_otel_gateway.py` |
| Health-probe traces are dropped on every Agent (`DD_APM_IGNORE_RESOURCES` / `apm_config.ignore_resources` from `apm.ignore_resources`) | kubernetes / host-agents / transport tests |

## 5. Tags on every hop

`modules/tagging` renders one tag set per workload and per resource. The table shows how each path receives it.

| Path | How the tags arrive |
|---|---|
| Datadog libraries | `DD_ENV`, `DD_SERVICE`, `DD_VERSION`, `DD_TAGS` (extra policy keys) |
| Kubernetes | UST labels `tags.datadoghq.com/*`, `ad.datadoghq.com/tags`, `podLabelsAsTags` on the Agent; SSI label `admission.datadoghq.com/enabled` |
| Agents | `DD_TAGS` / `datadog.tags` of the environment identity |
| OTel gateway | `transform/eh_tag_policy` inserts missing attributes per `service.name` and never overwrites them [`test_gateway_tag_policy_overlay`] |
| Fluent Bit | Lua `eh_finalize`: static tags never override record keys; Kubernetes label map; Azure tag map + scope tags |
| Observability Pipelines | VRL `tags` (defaults, value maps, normalisation, `telemetry.pipeline:observability-pipelines`) |
| Azure resources | `azure_tags` (the deploy roots merge them), imported by the Datadog Azure integration |
| RUM | `globalContext` |

## 6. Network exposure

* Every receiver is internal. Container Apps ingress is `external = false` for the Worker, the APM gateway, the OTel
  gateway and the aggregator. Validation rejects public receivers [transport.tftest `reject_public_receivers`].
* Event Hubs denies public traffic except trusted services; collectors use a private endpoint.
* The Worker's fluent source runs plaintext inside the VNet (internal ingress only). `fluent_tls` enables TLS with
  certificate files written by dsv-fetch.
