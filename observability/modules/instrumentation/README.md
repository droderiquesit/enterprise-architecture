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
  `extra_resource_attributes`, `sidecar_resources`, `fleet_policy`, `apm` / `profiling` (per-workload overrides),
  `serverless_init` (Container Apps: `subscription_id`, `resource_group`, image/sizing)

Datadog mode on managed runtimes (fleet policy): Container Apps default to the **serverless-init sidecar**
(`architectures.aca.apm.managed_runtime_path = serverless_init`: tracer on `localhost:8126`, DogStatsD on
`udp://localhost:8125`); its `DD_API_KEY` is written from Delinea DSV by a second dsv-fetch run (`dsv-fetch-datadog`,
dotenv `serverless-init.env` on the in-memory `dsv-secrets` volume) and sourced by the sidecar before
`exec /datadog-init` - no Container Apps secret. Opt out per workload with `apm = { managed_runtime_path = "agent_gateway" }`
(APM gateway, no DogStatsD). App Service defaults to OpenTelemetry (`architectures.appservice.apm.mode = otel`: the package
has no Datadog App Service sidecar integration and the APM gateway carries no DogStatsD); `apm = { mode = "datadog" }`
opts a workload into the tracer -> APM gateway path. A per-architecture mode of the policy wins over the contract's
environment-wide `env.fleet.EH_APM_MODE`.

| Output | Use |
|---|---|
| `env` | `DD_ENV/SERVICE/VERSION`, `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` (deployment.environment[.name], service.version/namespace, team, domain, tier, cloud.platform ...), `OTEL_EXPORTER_OTLP_ENDPOINT` + `_PROTOCOL` (Agent for AKS/VM, gateway otherwise), parentbased_traceidratio sampler, `OTEL_LOGS_EXPORTER=none`, runtime extras, `LOG_FILE_PATH` (sidecar and host routes only), `AzureFunctionsJobHost__telemetryMode=OpenTelemetry` (Functions) |
| `secret_env` | name to Delinea DSV reference (`dsv://...`, e.g. `OTEL_EXPORTER_OTLP_HEADERS` when the gateway requires a token); already part of `env` - the app resolves it at start-up |
| `dsv_env`, `sidecar_secret_refs`, `fetch_args` | DSV runtime env (`DSV_TENANT/TLD/BASE_URL/AUTH`, `AZURE_CLIENT_ID`; also merged into `env`), the sidecar's secrets and the dsv-fetch command line |
| `k8s_patch` / `k8s_patch_object` | strategic-merge patch: unified-service labels on the Deployment and pod template, `DD_AGENT_HOST` from `status.hostIP` declared before the env that references it |
| `container_app_patch` / `_json` | azurerm_container_app-shaped `secrets` (the non-secret Fluent Bit config files only), `volumes` (EmptyDir `app-logs`, Secret `flb-files`, EmptyDir `dsv-secrets`), `init_containers` (dsv-fetch, Consumption profile) / `refresher_containers` (Dedicated profiles), app container env/mounts, `sidecars[]`: Fluent Bit (sub_path mounts, `/dsv-secrets`, liveness `/api/v1/health:2020`) and, on the serverless-init path, `datadog` (`command` sources the DSV dotenv file, liveness TCP 8126) |
| `app_settings` | App Service / Functions / Logic Apps Std settings: plain values; secret settings carry the `dsv://` reference (no Key Vault references). Host-read settings (`AzureWebJobsStorage`, trigger connections) cannot be `dsv://` - keep them identity-based |
| `aci_sidecar` | Fluent Bit container + `fetcher` (dsv-fetch refresher container: ACI init containers cannot use managed identity; re-fetches hourly) + volumes for azurerm_container_group; `secure_environment_variables` is empty |
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
      for_each = module.hook.container_app_patch.init_containers   # dsv-fetch -> /dsv-secrets
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
      content { /* name, image, cpu, memory, args, env, volume_mounts (with sub_path) */ }
    }
  }
}
```
AKS: `kubectl patch deployment hello-bff --type strategic -p "$(terraform output -raw k8s_patch)"`, or merge
`k8s_patch_object` into a `kubernetes_deployment_v1`.
App Service and Functions: `app_settings = merge(local.app_settings, module.hook.app_settings)`.

Caveat: the Container Apps sidecar mounts the config files from Container Apps secrets with `sub_path`, because
azurerm 5.9 has no secret-volume item paths. This is implemented and unit-tested, but not deployed.

Tests: `tests/instrumentation.tftest.hcl` covers 11 runs, including negative tests (unknown runtime, literal API
key, bad tag value). `modules/telemetry-transport` tests feed a real contract into this module.
