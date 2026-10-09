# Telemetry transport & collection: authoritative paths and duplicate prevention

This page is the single reference for **who collects what, where** in the portable Datadog package
(`observability/`). It implements ADR-0001 §10. Every rule below is enforced by code and covered by a test
(the test is named in brackets).

Status vocabulary (ADR §11): everything here is **implemented**. The Fluent Bit configs, OTel gateway, Datadog
Agent DBM checks and the Linux host installer are **locally-verified** (docker, `observability/tests/transport/`).
Nothing is **deployed** or **verified**: this sandbox has no Azure or Datadog credentials.

## 1. Collection path per architecture

| Architecture | Application logs (only path) | Traces + metrics (OTLP) | Platform metrics | Platform logs |
|---|---|---|---|---|
| AKS | Fluent Bit **DaemonSet** tails `/var/log/containers` (`config/fluent-bit/k8s-daemonset.yaml`) | Node Datadog Agent OTLP receiver, `hostPort` 4317/4318, endpoint `http://$(DD_AGENT_HOST):4317` (`status.hostIP`) | Azure integration | AKS diagnostic settings (`kube-audit-admin`, ...) to the platform-logs hub |
| VM / VMSS | Fluent Bit **service** tails the app log file (`linux-host.yaml` / `windows-host.yaml`) | Host Agent OTLP receiver on `localhost:4317/4318` | Azure integration + Agent | - |
| ACA (apps) | Fluent Bit **sidecar** tails `LOG_FILE_PATH` on a shared EmptyDir (`sidecar.yaml`, or `sidecar-forward.yaml` to the aggregator) | OTel **gateway** (internal ingress): `https://<gw>` (OTLP/HTTP) or `http://<gw>:4317` (gRPC) | Azure integration | `ContainerAppSystemLogs` to the platform-logs hub |
| ACA **jobs** | stdout, then environment diagnostic setting `ContainerAppConsoleLogs`, then Event Hub `app-logs`, then aggregator (**allow-listed job names only**) | gateway | Azure integration | as ACA |
| ACI | Fluent Bit sidecar (secret volume with config, `aci_sidecar` output of `modules/instrumentation`) | gateway | Azure integration | - |
| App Service / Functions / Logic Apps Std | console, then diagnostic settings (`AppServiceConsoleLogs`, `AppServiceAppLogs`, `FunctionAppLogs`, `WorkflowRuntime`), then Event Hub `app-logs`, then aggregator `kafka` input | gateway (Functions host also exports OTLP logs, which are **dropped**, see 2.4) | Azure integration | `AppServiceHTTPLogs`, ... to the platform-logs hub |
| Browser | - (RUM) | RUM + `allowedTracingUrls` (content package) | - | - |
| Databases | DB logs: diagnostic settings (platform hub) | client spans from app SDKs | Azure integration | `PostgreSQLLogs`, `SQLSecurityAuditEvents`, ... |
| Databases (DBM) | - | - | Datadog Agent DBM check from the observability subnet (ACI) or AKS cluster checks (`modules/dbm`) | - |

`modules/instrumentation` computes the per-app integration hook (env vars, Kubernetes patch, Container Apps
sidecar patch, App Service app settings, ACI sidecar) from the `obs-telemetry-transport` contract. The owning
application deployment root applies that hook.

## 2. Duplicate-prevention rules

### 2.1 One collector per application log line
| Rule | Where it is enforced |
|---|---|
| The Datadog Agent never collects container or host logs: `datadog.logs.enabled=false`, `containerCollectAll=false` (Helm); `DD_LOGS_ENABLED=false` (VM drop-in, Windows machine env) | `modules/kubernetes` [kubernetes.tftest `defaults`; helm-template render check], `modules/host-agents` scripts [hosts.tftest `vm_and_vmss`; `test_host_installer.py`] |
| Agent OTLP log ingestion is off: `datadog.otlp.logs.enabled=false`, `DD_OTLP_CONFIG_LOGS_ENABLED=false` | same as above |
| Apps never export OTLP logs: `OTEL_LOGS_EXPORTER=none` | `modules/instrumentation` [instrumentation.tftest `aks_dotnet_uses_node_agent_and_daemonset`] |
| `LOG_FILE_PATH` is set only on the sidecar and host routes. Apps on the Event Hub and DaemonSet routes log to stdout only. | `modules/instrumentation` [`appservice_eventhub_route_app_settings`, `aks_*`] |
| The DaemonSet excludes the `kube-system`, `datadog`, `fluent-bit` (and other configured) namespaces. Pods can opt out with `fluentbit.io/exclude: "true"`. | `config/fluent-bit/k8s-daemonset.yaml`, `modules/fluent-bit` [render.tftest `k8s_daemonset`] |

### 2.2 Diagnostic settings: app-log categories only for the Event Hub route
`modules/diagnostic-settings` takes an `app_log_route` for each resource:

* `eventhub`: the supported app-log categories (`AppServiceConsoleLogs`, `AppServiceAppLogs`, `FunctionAppLogs`,
  `WorkflowRuntime`, `ContainerAppConsoleLogs`) go to the **app-logs** hub.
* `sidecar | daemonset | host | none`: app-log categories are **never** exported. App-log categories never reach
  the platform hub, even if someone lists them in the platform allow-list.
* Platform categories are an allow-list for each resource type, intersected with
  `azurerm_monitor_diagnostic_categories`. A resource type that supports no listed category gets no setting.
* Metrics are never exported through diagnostic settings, because the Azure integration already collects
  them.

[diagnostics.tftest `routes_and_categories`, `daemonset_route_excludes_app_logs`; the lab diagnostics root discovery.tftest]

### 2.3 Container Apps environments carry both routes
An environment exports `ContainerAppConsoleLogs` for **all** of its apps. In practice:

* The environment's setting includes `ContainerAppConsoleLogs` **only if** at least one app or job in that
  environment declares `app_log_route = eventhub` (normally only jobs, which have no sidecar).
  [lab diagnostics root `jobs_route_environment_console_logs_to_app_hub`, `sidecar_only_environment_exports_no_console_logs`]
* The aggregator keeps console records only for allow-listed apps and jobs (`FLB_ACA_CONSOLE_ALLOW`, contract
  `fluentbit.aca_console_allow`; the lab default is `<prefix>-caj-*`). It drops the stdout of sidecar-collected
  apps and the Fluent Bit sidecar's own output.
  [`test_fluentbit.py::test_aggregator_forward_and_eventhub_kafka`: evt-0103 is delivered; evt-0104 and evt-0105 are dropped]
* The lab diagnostics root raises a `check` when an Event Hub route app is missing from the allow-list.
  [`allow_list_mismatch_is_flagged`]

### 2.4 OTLP logs at the gateway: accepted and dropped
The Azure Functions host exports host and worker logs over OTLP as soon as `OTEL_EXPORTER_OTLP_ENDPOINT` is set,
and `host.json` filters do not stop this. Those application logs already reach Datadog through
`FunctionAppLogs`, Event Hubs and the aggregator. The gateway therefore has a `logs` pipeline that ends in the
`nop` exporter:

* It **accepts** the logs, so clients see no export errors or retries.
* It **forwards nothing**.

The opt-in overlay `gateway-logs-forward.yaml` (`gateway.otlp_logs = "forward"`) exists only for sources that
have no Fluent Bit route.
[`test_otel_gateway.py::test_gateway_accepts_and_drops_otlp_logs_by_default`, `test_gateway_logs_forward_overlay_is_opt_in`]

### 2.5 Native Azure integration
`azurerm_datadog_monitor_tag_rule` keeps `resource_log_enabled = false` by default. When enabled, the native
resource-log forwarding creates its own diagnostic settings, which would duplicate 2.2 and 2.3. Datadog's
*automated log forwarding* (ARM template, control-plane Function Apps) also creates diagnostic settings. That
conflicts with ADR rule 4, so this package does not use it (see `modules/azure-integration/README.md`).

### 2.6 Traces and metrics
* Every app sends OTLP to exactly one target (`otlp_target` = `agent` | `gateway`).
* APM stats are computed once, by the gateway's `datadog/connector` on 100% of spans, before sampling.
* Gateway replicas report `host_metadata.enabled=false` and do not become hosts.

## 3. Pipeline signals for monitors
| Signal | Value |
|---|---|
| Tag on every Fluent Bit record | `telemetry.pipeline:fluent-bit` in `ddtags` (Lua `eh_finalize`) |
| Canary | `dummy` input in the DaemonSet, aggregator and host configs. Emits 1 record per minute: `service:telemetry-canary`, attribute `canary:true`, `env:<env>` tag |
| Fluent Bit self-metrics | Names keep `_total` (e.g. `fluentbit_output_errors_total`). Aggregator: Prometheus endpoint `:2020/api/v2/metrics/prometheus`, scraped by the gateway. DaemonSet and hosts: `fluentbit_metrics` input, then OTLP to the node or host Agent. Each point has an `env` label/attribute. |
| Collector self-metrics | `otelcol_*` names **without** the type suffix (`without_type_suffix: true`, e.g. `otelcol_exporter_send_failed_spans`), scraped with an `env` label |

[`test_fluentbit.py` (pipeline tag, canary, `_total`), `test_otel_gateway.py::test_gateway_self_and_fluentbit_metrics_naming`]

Datadog's OpenMetrics V2 check renames counters to `<name>.count`, which is why the DaemonSet and hosts push
OTLP instead of being scraped by the Agent. This was verified locally: the Agent 7.84.2 openmetrics check
produced `fluentbit_output_errors_total.count`.

## 4. Network exposure
Every receiver is internal:

* ACA ingress is `external = false` (VNet-only) for both apps. Setting `external_ingress = true` is rejected by
  validation [transport.tftest `reject_public_receivers`].
* The optional `bearertokenauth` overlay adds token checks on OTLP. It is only available on the upstream
  collector, because DDOT does not ship that extension.
* Event Hubs denies public traffic except trusted services (Azure Monitor diagnostic settings). Collectors reach
  it through a private endpoint.
