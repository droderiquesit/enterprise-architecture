# Application environment composer used by every deployment root:
#   instrumentation contract (observability/modules/instrumentation, a pure function module) +
#   identity (AZURE_CLIENT_ID) + fault-injection wiring + service-specific env.
# Secret VALUES never pass through here (ADR-0001 section 14): every secret setting is an ordinary env var / app
# setting whose VALUE is a Delinea DSV reference (dsv://<path>#<element>). The application resolves it at start-up
# (hello_common / Hello.Common) with its user-assigned managed identity, using the DSV runtime env published here
# (DSV_TENANT, DSV_TLD, DSV_BASE_URL, DSV_AUTH, AZURE_CLIENT_ID). The same map works on every platform:
#   Container Apps / ACI env, App Service / Functions / Logic Apps app settings, Kubernetes env (Helm values), VM env.
# Third-party sidecars (Fluent Bit) get their keys through the dsv-fetch helper (instrumentation patch).
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
  identity_client_id        = var.identity_client_id
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
    # hello_common (Python): workload identity on AKS, managed identity elsewhere.
    var.runtime == "python" && var.identity_client_id != null ? {
      AZURE_CREDENTIAL_MODE = var.architecture == "aks" ? "workload_identity" : "managed_identity"
    } : {},
  )
  # secret settings: NAME -> dsv:// reference (values are references, resolved by the app)
  secret_env = merge(
    var.secret_env,
    var.faults.token_ref == null ? {} : { FAULT_TOKEN = var.faults.token_ref },
    module.instrumentation.secret_env,
  )

  env = merge(local.base, local.secret_env, module.instrumentation.env)

  # App Service / Functions / Logic Apps Standard: identical map (no @Microsoft.KeyVault references)
  app_settings = local.env
}
