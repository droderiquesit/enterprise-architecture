# modules/instrumentation: the integration hook for app owners

A pure function module with no providers and no resources. An existing application's **own deployment
pipeline** calls it with the service identity and the `obs-telemetry-transport` contract, then applies the
result to its own resource. Observability never owns app settings (ADR-0001 §3 rule 2).

Inputs:
* `service {service, env, version, team, domain, tier, application, owner, region}`
* `runtime`: dotnet | python | node | java | browser
* `architecture`: aks | aca | aci | appservice | functions | vm | vmss | logicapp
* `telemetry`: the contract object, or a hand-built equivalent for non-lab environments
* Optional: `container_name`, `log_file_path`, `otlp_protocol`, `trace_sample_ratio`, `identity_client_id`, `fetch_resources`,
  `extra_resource_attributes`, `sidecar_resources` (Fluent Bit fallback), `fleet_policy`, `apm` / `profiling` / `logs`
  (per-workload overrides, e.g. `logs = { collector = "azure" }` for Container Apps jobs), `serverless_init` (Container
  Apps: `subscription_id`, `resource_group`, image/sizing overrides), `agent_sidecar` (ACI: image, cpu, memory_gb, hostname)
* `telemetry.aggregator.agent_logs_url`: the Observability Pipelines Worker's Datadog Agent source; without it the
  Datadog sidecars collect no logs in observability_pipelines mode (plan warning, no bypass of the Worker)

One Datadog collection path per platform (observability 4.0.0, fleet policy `logs.collector`):

* **ACI** (`agent_sidecar`): a pinned Datadog Agent sidecar (`agent.image:agent.version`, 0.25 vCPU / 0.5 GB) in the
  container group - traces `localhost:8126`, DogStatsD `udp://localhost:8125`, and `LOG_FILE_PATH` on the shared
  `app-logs` emptyDir (file source, chosen over the Agent TCP log listener: the apps already write the file for every
  tailer and it buffers across Agent restarts) -> OP Worker (`DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_*`). Key:
  `api_key: ENC[dsv://...]` resolved by `dsv-fetch agent-backend`; the `dsv-fetch-install` init container copies the
  static binary into the `dsv-bin` emptyDir (ACI init containers have no managed identity - it makes no DSV call) and
  the Agent's start command installs it root-owned 0500 before `exec /bin/entrypoint.sh`.
* **Container Apps** (`serverless_init`): the serverless-init sidecar tails `LOG_FILE_PATH` (`DD_SERVERLESS_LOG_PATH`;
  in sidecar mode it cannot read the app's stdout) and receives traces / DogStatsD on localhost. Its start command runs
  the dsv-fetch binary (installed by the identity-free `dsv-fetch-install` init container, so every workload profile
  works) into its own `/tmp`, sources and truncates the dotenv and execs `/datadog-init`.
* **Fluent Bit** only with `log_pipeline = fluent_bit_direct` (Container Apps / ACI sidecar + dsv-fetch env-yaml init
  or refresher container `init --refresh-seconds`); the Datadog sidecars then keep traces / DogStatsD with log collection off.

Datadog mode on managed runtimes (fleet policy): Container Apps default to the **serverless-init sidecar**
(`architectures.aca.apm.managed_runtime_path = serverless_init`) and ACI to the **Agent sidecar**
(`architectures.aci.apm.managed_runtime_path = agent_sidecar`): tracer on `localhost:8126`, DogStatsD on
`udp://localhost:8125`. Opt out per workload with `apm = { managed_runtime_path = "agent_gateway" }` (APM gateway, no
DogStatsD; the sidecar still collects logs unless `logs = { collector = "azure" }` on Container Apps). App Service defaults to OpenTelemetry (`architectures.appservice.apm.mode = otel`: the package
has no Datadog App Service sidecar integration and the APM gateway carries no DogStatsD); `apm = { mode = "datadog" }`
opts a workload into the tracer -> APM gateway path. A per-architecture mode of the policy wins over the contract's
environment-wide `env.fleet.EH_APM_MODE`.

| Output | Use |
|---|---|
| `env` | `DD_ENV/SERVICE/VERSION`, `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` (deployment.environment[.name], service.version/namespace, team, domain, tier, cloud.platform ...), `OTEL_EXPORTER_OTLP_ENDPOINT` + `_PROTOCOL` (Agent for AKS/VM, gateway otherwise), parentbased_traceidratio sampler, `OTEL_LOGS_EXPORTER=none`, runtime extras, `LOG_FILE_PATH` (file-tailing collectors only: ACI Agent sidecar, serverless-init, Fluent Bit fallback, hosts), `AzureFunctionsJobHost__telemetryMode=OpenTelemetry` (Functions) |
| `secret_env` | name to Delinea DSV reference (`dsv://...`, e.g. `OTEL_EXPORTER_OTLP_HEADERS` when the gateway requires a token); already part of `env` - the app resolves it at start-up |
| `dsv_env`, `sidecar_secret_refs`, `fetch_args` | DSV runtime env (`DSV_TENANT/TLD/BASE_URL/AUTH`, `AZURE_CLIENT_ID`; also merged into `env`), the Fluent Bit fallback's secrets and its dsv-fetch command line |
| `k8s_patch` / `k8s_patch_object` | strategic-merge patch: unified-service labels on the Deployment and pod template, `DD_AGENT_HOST` from `status.hostIP` declared before the env that references it |
| `container_app_patch` / `_json` | azurerm_container_app-shaped `volumes` (EmptyDir `app-logs`, `dsv-bin`; fallback: Secret `flb-files`, EmptyDir `dsv-secrets`), `init_containers` (`dsv-fetch-install`, `needs_identity = false`, every profile; fallback `dsv-fetch` env-yaml fetch, `needs_identity = true`, Consumption profile) / `refresher_containers` (fallback on Dedicated profiles), app container env/mounts, `sidecars[]`: `datadog` serverless-init (`command` resolves the key with dsv-fetch then execs `/datadog-init`, liveness TCP 8126) or, fallback, `fluent-bit` (sub_path mounts, liveness `/api/v1/health:2020`); `secrets` = the non-secret Fluent Bit config files (fallback only) |
| `app_settings` | App Service / Functions / Logic Apps Std settings: plain values; secret settings carry the `dsv://` reference (no Key Vault references). Host-read settings (`AzureWebJobsStorage`, trigger connections) cannot be `dsv://` - keep them identity-based |
| `aci_sidecar` | azurerm_container_group additions: `init_containers` (`dsv-fetch-install`), `containers` (`datadog-agent`; fallback `fluent-bit` + `dsv-fetch` refresher), each with `volumes` and `liveness_exec`; `app_volume_mounts`; `secure_environment_variables` is empty |
| `aci_agent_files` | the Agent sidecar's non-secret `datadog.yaml`, `app-logs.yaml`, `dsv.json`, start command and env (local tests, non-Terraform pipelines) |
| `log_collector`, `log_collector_reason` | `datadog-agent`, `datadog-agent-sidecar`, `serverless-init`, `diagnostic-settings`, `fluent-bit`, `fluent-bit-sidecar` |
| `log_route`, `otlp_target`, `datadog_tags` | for docs, monitors and assertions |

## Examples
```hcl
module "hook" {
  source       = "git::https://<repo>//observability/modules/instrumentation?ref=<tag>"
  service      = { service = "hello-orders-api", env = "dev", version = var.version, team = "orders", domain = "commerce", tier = "backend", application = "enterprise-hello" }
  runtime      = "dotnet"
  architecture = "aca"
  telemetry    = var.obs_telemetry_transport          # the contract
  identity_client_id = azurerm_user_assigned_identity.app.client_id
}

resource "azurerm_container_app" "app" {
  # ...
  dynamic "secret" {
    for_each = module.hook.container_app_patch.secrets
    content {
      name  = secret.value.name   # config files only
      value = secret.value.value
    }
  }
  template {
    dynamic "init_container" {
      # dsv-fetch-install (binary -> dsv-bin); keep needs_identity = true entries for the Consumption profile only
      for_each = [for c in module.hook.container_app_patch.init_containers : c if !c.needs_identity || local.consumption]
      content { /* name, image, cpu, memory, args, env, volume_mounts */ }
    }
    dynamic "volume" {
      for_each = module.hook.container_app_patch.volumes
      content {
        name         = volume.value.name
        storage_type = volume.value.storage_type
      }
    }
    container {
      name = "hello-orders-api" # == container_app_patch.app_container.name
      # ...
      dynamic "env" {
        for_each = module.hook.container_app_patch.app_container.env
        content {
          name  = env.value.name
          value = env.value.value   # dsv:// references included (resolved by the app)
        }
      }
      dynamic "volume_mounts" {
        for_each = module.hook.container_app_patch.app_container.volume_mounts
        content {
          name = volume_mounts.value.name
          path = volume_mounts.value.path
        }
      }
    }
    dynamic "container" {
      for_each = module.hook.container_app_patch.sidecars
      content { /* name, image, cpu, memory, command, args, env, volume_mounts (with sub_path), liveness_probe */ }
    }
  }
}
```
AKS: `kubectl patch deployment hello-bff --type strategic -p "$(terraform output -raw k8s_patch)"`, or merge
`k8s_patch_object` into a `kubernetes_deployment_v1`.
App Service and Functions: `app_settings = merge(local.app_settings, module.hook.app_settings)`.

ACI: see `applications/deployments/partner-sim/main.tf` (dynamic `init_container` / `container` blocks over
`aci_sidecar`, `try(...)` because the containers have different shapes).

Caveat: the Fluent Bit fallback on Container Apps mounts the config files from Container Apps secrets with `sub_path`,
because azurerm 5.9 has no secret-volume item paths. This is implemented and unit-tested, but not deployed. The ACI
Agent sidecar and serverless-init were run locally with docker (`observability/tests/transport/test_agent_sidecar.py`),
not on Azure.

Tests: `tests/instrumentation.tftest.hcl` covers 25 runs (ACI Agent sidecar, serverless-init, Fluent Bit fallback,
plan warning without a Worker URL, overrides). `modules/telemetry-transport` tests feed a real contract into this module.
