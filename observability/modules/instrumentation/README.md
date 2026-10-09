# modules/instrumentation: the integration hook for app owners

A pure function module with no providers and no resources. An existing application's **own deployment
pipeline** calls it with the service identity and the `obs-telemetry-transport` contract, then applies the
result to its own resource. Observability never owns app settings (ADR-0001 §3 rule 2).

Inputs:
* `service {service, env, version, team, domain, tier, application, owner, region}`
* `runtime`: dotnet | python | node | java | browser
* `architecture`: aks | aca | aci | appservice | functions | vm | vmss | logicapp
* `telemetry`: the contract object, or a hand-built equivalent for non-lab environments
* Optional: `container_name`, `log_file_path`, `otlp_protocol`, `trace_sample_ratio`, `key_vault_identity_id`,
  `extra_resource_attributes`, `sidecar_resources`

| Output | Use |
|---|---|
| `env` | `DD_ENV/SERVICE/VERSION`, `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` (deployment.environment[.name], service.version/namespace, team, domain, tier, cloud.platform ...), `OTEL_EXPORTER_OTLP_ENDPOINT` + `_PROTOCOL` (Agent for AKS/VM, gateway otherwise), parentbased_traceidratio sampler, `OTEL_LOGS_EXPORTER=none`, runtime extras, `LOG_FILE_PATH` (sidecar and host routes only), `AzureFunctionsJobHost__telemetryMode=OpenTelemetry` (Functions) |
| `secret_env` | name to Key Vault secret id (for example `OTEL_EXPORTER_OTLP_HEADERS` when the gateway requires a token) |
| `k8s_patch` / `k8s_patch_object` | strategic-merge patch: unified-service labels on the Deployment and pod template, `DD_AGENT_HOST` from `status.hostIP` declared before the env that references it |
| `container_app_patch` / `_json` | azurerm_container_app-shaped `secrets` (Key Vault refs + config files), `volumes` (EmptyDir `app-logs`, Secret `flb-files`), app container env/mounts, Fluent Bit `sidecars[]` (sub_path mounts, liveness `/api/v1/health:2020`) |
| `app_settings` | App Service / Functions / Logic Apps Std settings; secrets as `@Microsoft.KeyVault(SecretUri=...)` |
| `aci_sidecar` | container + volumes for azurerm_container_group. ACI cannot reference Key Vault, so the caller resolves `secure_environment_variables` from the listed secret ids (ephemeral read recommended). |
| `log_route`, `otlp_target`, `datadog_tags` | for docs, monitors and assertions |

## Examples
```hcl
module "hook" {
  source       = "git::https://<repo>//observability/modules/instrumentation?ref=<tag>"
  service      = { service = "hello-orders-api", env = "dev", version = var.version, team = "orders", domain = "commerce", tier = "backend", application = "enterprise-hello" }
  runtime      = "dotnet"
  architecture = "aca"
  telemetry    = var.obs_telemetry_transport          # the contract
  key_vault_identity_id = azurerm_user_assigned_identity.app.id
}

resource "azurerm_container_app" "app" {
  # ...
  dynamic "secret" {
    for_each = module.hook.container_app_patch.secrets
    content {
      name                = secret.value.name
      value               = secret.value.value
      key_vault_secret_id = secret.value.key_vault_secret_id
      identity            = secret.value.identity
    }
  }
  template {
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
          name        = env.value.name
          value       = env.value.value
          secret_name = env.value.secret_name
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
