# Consumer root for an EXISTING environment (package 3.0.0). Uses only the vendored, versioned package release
# (./vendor.sh -> ./.vendor/observability-<version>/). It CONNECTS existing resources to Datadog with the package tag
# policy: Datadog-side collection objects (Azure integration, Observability Pipelines pipeline, RUM application),
# diagnostic settings on the supplied resources, the Datadog Agent / Observability Pipelines Worker on the existing
# AKS cluster, DBM cluster checks and the instrumentation settings the application owners apply. Azure resources are
# referenced by the ids written in manifests/<env>/*.yaml and are never created, changed or destroyed here.
# Monitors, SLOs and dashboards are not part of the package (they exist in your organisation; extras/content in the
# source repository holds the optional 2.x content modules).
locals {
  rendered_dir = "${path.module}/rendered/${var.env}"
  services     = [for f in sort(fileset(local.rendered_dir, "*.json")) : jsondecode(file("${local.rendered_dir}/${f}"))]
  by_service   = { for s in local.services : s.service => s }

  # One fleet inventory input: every manifest resource with the tags of its owning service.
  inventory = merge([
    for s in local.services : {
      for r in s.resources : "${s.service}/${r.role}" => {
        id            = r.id
        type          = r.type
        architecture  = r.role == "app" ? s.architecture : null
        runtime       = r.role == "app" ? s.runtime : null
        os_type       = s.os_type
        tags          = r.tags
        app_log_route = r.role == "app" ? s.telemetry.logs_route : null
        tier          = r.tier
      }
    }
  ]...)

  op_enabled = var.observability_pipelines.enabled
  eh         = local.op_enabled && var.observability_pipelines.eventhub != null
}

module "fleet" {
  source    = "./.vendor/observability-3.0.0/modules/fleet-inventory"
  resources = local.inventory
  env       = var.env
}

# Environment-level tags (filled into telemetry that arrives without them; never overwrite a client value)
module "env_tags" {
  source           = "./.vendor/observability-3.0.0/modules/tagging"
  enforce_required = false
  identity         = { env = var.env, region = var.region, managed_by = "terraform" }
}

module "azure_integration" {
  source = "./.vendor/observability-3.0.0/modules/azure-integration"
  count  = var.azure_integration.enabled ? 1 : 0

  mode             = "app_registration"
  tenant_id        = var.azure_integration.tenant_id
  subscription_ids = var.azure_integration.subscription_ids
  app_registration = {
    client_id                   = var.azure_integration.client_id
    auth                        = "secretless"
    service_principal_object_id = var.azure_integration.sp_object_id
    assign_monitoring_reader    = var.azure_integration.assign_monitoring_reader
  }
}

module "diagnostics" {
  source = "./.vendor/observability-3.0.0/modules/diagnostic-settings"
  count  = var.diagnostics.enabled ? 1 : 0

  resources = module.fleet.diagnostic_targets
  destination = {
    authorization_rule_id = var.diagnostics.destination.authorization_rule_id
    app_logs_hub          = var.diagnostics.destination.app_logs_hub
    platform_logs_hub     = var.diagnostics.destination.platform_logs_hub
  }
  platform_log_tier = var.diagnostics.platform_log_tier
}

# Subscription Activity Log (+ optional Entra ID) of the supplied subscriptions -> activity-logs hub.
module "azure_logs" {
  source = "./.vendor/observability-3.0.0/modules/azure-logs"
  count  = var.diagnostics.enabled ? 1 : 0

  activity_log = {
    enabled          = var.azure_logs.activity_log_enabled
    subscription_ids = var.azure_logs.subscription_ids
    categories       = var.azure_logs.categories
  }
  entra = var.azure_logs.entra
  destination = {
    authorization_rule_id = var.diagnostics.destination.authorization_rule_id
    eventhub_name         = coalesce(var.diagnostics.destination.activity_logs_hub, var.diagnostics.destination.platform_logs_hub)
  }
}

# Datadog Observability Pipelines: one pipeline per environment. Sources: Datadog Agents and Fluent Bit edge
# collectors, plus the Event Hubs (Kafka endpoint) the diagnostic settings above export to. The Worker runs on the
# existing AKS cluster (module.kubernetes op_worker); its API key and the Event Hubs listen connection string come
# from Secrets kept by the Delinea dsv-k8s syncer - never through Terraform.
module "observability_pipeline" {
  source = "./.vendor/observability-3.0.0/modules/observability-pipeline"
  count  = local.op_enabled ? 1 : 0

  name         = "${var.env}-logs"
  env          = var.env
  datadog_site = var.datadog_site
  default_tags = { for k, v in module.env_tags.tags : k => v if contains(["env", "region", "managed_by"], k) }
  sources = {
    eventhub = local.eh ? { topics = var.observability_pipelines.eventhub.topics } : null
  }
  azure = {
    scope_tags = module.fleet.scope_tags
  }
  secret_refs = {
    api_key                    = var.telemetry.api_key_ref
    eventhub_connection_string = local.eh ? var.observability_pipelines.eventhub.connection_string_ref : null
  }
  eventhub_bootstrap = local.eh ? var.observability_pipelines.eventhub.bootstrap : null
}

module "rum" {
  source       = "./.vendor/observability-3.0.0/modules/rum"
  count        = length(var.rum) > 0 ? 1 : 0
  datadog_site = var.datadog_site
  applications = { for k, a in var.rum : k => merge(a, {
    service  = k
    env      = var.env
    identity = { for tk, tv in try(local.by_service[k].identity, {}) : tk => tv if !contains(["env", "service", "version"], tk) }
  }) }
}

module "dbm" {
  source = "./.vendor/observability-3.0.0/modules/dbm"
  count  = var.dbm.enabled ? 1 : 0

  hosting  = "cluster_checks"
  datadog  = { site = var.datadog_site, env = var.env }
  identity = { for k, v in local.by_service["orders-api"].identity : k => v if !contains(["env", "service"], k) }
  databases = {
    orders-postgresql = {
      engine          = "postgres"
      deployment_type = "flexible_server"
      host            = var.dbm.host
      port            = 5432
      username        = "datadog"
      auth            = "password"
      password_ref    = { kind = "dsv", name = var.dbm.password_ref }
      resource_id     = var.dbm.resource_id
      service         = "orders-api"
    }
  }
}

module "kubernetes" {
  source = "./.vendor/observability-3.0.0/modules/kubernetes"
  count  = var.kubernetes.enabled ? 1 : 0

  cluster_name = var.kubernetes.cluster_name
  datadog      = { site = var.datadog_site, env = var.env }
  identity     = merge(var.kubernetes.identity, { region = var.region })
  log_pipeline = local.op_enabled ? "observability_pipelines" : "fluent_bit_direct"
  api_key = {
    mode                      = var.kubernetes.api_key_mode
    cluster_agent_secret_name = var.kubernetes.cluster_agent_secret_name
  }
  dsv = {
    api_key_ref        = var.telemetry.api_key_ref
    tenant             = var.telemetry.secrets.tenant
    tld                = var.telemetry.secrets.tld
    base_url           = var.telemetry.secrets.base_url
    fetch_image        = var.telemetry.secrets.fetch_image
    identity_client_id = var.kubernetes.identity_client_id
  }
  apm = { namespaces = var.kubernetes.ssi_namespaces }
  op_worker = {
    enabled             = local.op_enabled
    pipeline_id         = local.op_enabled ? module.observability_pipeline[0].pipeline_id : null
    api_key_secret_name = var.observability_pipelines.api_key_secret_name
    env                 = { for k, v in try(module.observability_pipeline[0].worker_env, {}) : k => v }
    secret_env = { for k, v in {
      DD_OP_SOURCE_KAFKA_SASL_PASSWORD = { secret_name = try(var.observability_pipelines.eventhub.synced_secret_name, ""), key = try(var.observability_pipelines.eventhub.synced_secret_key, "") }
    } : k => v if local.eh }
  }

  cluster_checks = var.dbm.enabled ? module.dbm[0].cluster_check_confd : {}
}

# Instrumentation settings (env vars / app settings / k8s patches) the application owners apply in their own
# deployment code (this root never changes application settings).
module "instrumentation" {
  source   = "./.vendor/observability-3.0.0/modules/instrumentation"
  for_each = var.instrumented_services

  service = merge(
    { for k, v in local.by_service[each.key].identity : k => v if contains(["domain", "tier", "application", "owner", "region"], k) },
    { service = each.key, env = var.env, version = each.value.version, team = local.by_service[each.key].identity.team },
  )
  runtime      = local.by_service[each.key].runtime
  architecture = local.by_service[each.key].architecture
  os_type      = local.by_service[each.key].os_type
  telemetry    = var.telemetry
}
