# modules/fleet-policy

Resolves the fleet collection policy (`config/fleet-policy.yaml`) for one workload or resource (pure, no providers).

Precedence: defaults -> `architectures.<arch>` -> `environments.<env>` -> `overrides`. The Datadog support matrix
then decides the **effective** method (verified against docs.datadoghq.com on 2026-10-09/10).

| Output | Meaning |
|---|---|
| `log_pipeline`, `node_collector` | `observability_pipelines` or `fluent_bit_direct`; `agent` or `fluent_bit` (AKS; hosts are always `agent`) where an Agent runs (3.x output) |
| `log_collector`, `log_collector_reason` | 4.0.0: the application-log collector of the architecture - `agent` (aks, vm, vmss: Linux and Windows), `agent_sidecar` (aci), `serverless_init` (aca), `azure` (appservice, functions, logicapp; Container Apps jobs by override), `fluent_bit` (batch); with `fluent_bit_direct` `fluent_bit` (aks) / `fluent_bit_sidecar` (aca, aci) - `azure` and the VM / VMSS host Agent stay. An unsupported `logs.collector` falls back to the architecture default with a reason |
| `agent_image`, `agent_sidecar`, `serverless_init` | single pins: `agent.image:agent.version`; ACI Agent sidecar image + sizing (`agent.sidecar`, default 0.25 vCPU / 0.5 GB); serverless-init image + sizing (`agent.serverless_init`) |
| `apm` | `{requested_mode, mode, method, fallback_reason, library_versions, ...}`. Methods: `ssi_kubernetes`, `ssi_host`, `agent_sidecar` (ACI), `serverless_init` (ACA), `agent_gateway`, `otlp_agent`, `otlp_gateway`, `none` |
| `apm_env` | the Datadog-mode library contract: `TELEMETRY_SDK=datadog`, `DD_TRACE_OTEL_ENABLED=true`, `DD_TRACE_REMOVE_INTEGRATION_SERVICE_NAMES_ENABLED=true`, `DD_LOGS_INJECTION`, `DD_METRICS_OTEL_ENABLED=false`, DogStatsD target, `DD_RUNTIME_METRICS_ENABLED` (only next to an Agent), sampling, `DD_DBM_PROPAGATION_MODE`, DSM (.NET Service Bus). Never any `OTEL_*` variable |
| `profiling` | `{enabled, reason, env}`: Continuous Profiler env per runtime (.NET / Python types; `auto` under SSI), or the reason it is off |
| `agent`, `agent_apm_ignore_resources`, `op_worker`, `rum` | Agent version / Remote Configuration / remote updates; trace resources to drop; Worker sizing; RUM sampling, replay, propagators |

Fallbacks:

* Windows VMs fall back to `otel`: SSI on Windows is IIS only.
* Logic Apps get `none`.
* Functions stay on `otel` by package policy: Datadog documents neither the Functions host spans nor Durable V2 spans.
* The profiler is unsupported for .NET Function Apps; for Python on Functions it is preview only.
* `serverless_init` exists only on ACA and `agent_sidecar` only on ACI (both the defaults there; any other architecture
  falls back to `agent_gateway`). DogStatsD (`udp://localhost:8125`) and runtime metrics are on next to both sidecars.

## Test
`terraform init -backend=false && terraform test` in this directory (mock providers, no credentials): `tests/fleet_policy.tftest.hcl`. `observability/tests/tags/test_tags.py` validates `config/fleet-policy.yaml` against `schemas/fleet-policy.v1.schema.json`.
