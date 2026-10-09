# Application environment composer used by every deployment root:
#   instrumentation contract (observability/modules/instrumentation, a pure function module) +
#   identity (AZURE_CLIENT_ID) + fault-injection wiring + service-specific env.
# Secret VALUES never pass through here: secrets are Key Vault versionless ids rendered per platform as
#   - Container Apps: secret { key_vault_secret_id, identity } + env secret_name
#   - App Service / Functions / Logic Apps: "@Microsoft.KeyVault(SecretUri=...)" app setting
#   - AKS: Secrets Store CSI driver SecretProviderClass -> synced Kubernetes Secret (secretKeyRef)
#   - ACI / VM: resolved by the caller (documented per root).
module "instrumentation" {
  source = "../../../../observability/modules/instrumentation"

  service = {
    service     = var.service.name
    env         = var.service.env
    version     = var.service.version
    team        = var.service.team
    domain      = var.service.domain
    tier        = var.service.tier
    application = "enterprise-hello"
    owner       = var.service.owner
    region      = var.service.region
  }
  runtime                   = var.runtime
  architecture              = var.architecture
  telemetry                 = var.telemetry
  otlp_protocol             = var.otlp_protocol
  trace_sample_ratio        = var.trace_sample_ratio
  key_vault_identity_id     = var.key_vault_identity_id
  extra_resource_attributes = var.extra_resource_attributes
  log_file_path             = "/var/log/app/app.log"
}

locals {
  # Values owned by the deployment (identity, faults, build metadata). The instrumentation env wins for
  # telemetry keys; service extra_env wins for nothing telemetry-related (it is merged first).
  base = merge(
    var.extra_env,
    {
      LOG_LEVEL      = var.log_level
      FAULTS_ENABLED = var.faults.enabled ? "true" : "false"
      GIT_COMMIT     = var.service.commit
    },
    var.port == null ? {} : { PORT = tostring(var.port) },
    var.identity_client_id == null ? {} : { AZURE_CLIENT_ID = var.identity_client_id },
  )
  env = merge(local.base, module.instrumentation.env)

  secret_env = merge(
    var.secret_env,
    var.faults.token_secret_id == null ? {} : { FAULT_TOKEN = var.faults.token_secret_id },
    module.instrumentation.secret_env,
  )

  # Container Apps secret names: lowercase alphanumerics and '-'.
  secret_names = { for k in keys(local.secret_env) : k => lower(replace(k, "_", "-")) }

  app_settings = merge(
    local.env,
    { for k, id in local.secret_env : k => "@Microsoft.KeyVault(SecretUri=${id})" },
  )
}
