# Container Apps jobs (hello-jobs, hello-traffic):
#   seed (manual) | reconcile-trigger (schedule) | traffic (schedule, bounded) | process-batch-items (event-driven,
#   KEDA azure-servicebus scaler on queue batch-items, authenticated with the job's user-assigned identity).
# Azure Batch daily-aggregate is a runtime submission (scripts/submit-batch-job.sh), not Terraform.
# Logs: jobs are run-to-completion, so no Fluent Bit sidecar (it would keep executions alive); stdout is
# collected through the environment's ContainerAppConsoleLogs diagnostic setting (obs-diagnostics -> Event Hubs).
module "meta" {
  source = "../modules/service-meta"
}

resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  ids = var.foundation_identity.identities
  aca = var.platform_containerapps
  sb  = var.platform_messaging

  # Kubernetes-internal *.svc.cluster.local URLs (deploy-core-aks) are not resolvable from Container Apps jobs.
  core_apps   = { for k, a in merge(try(var.deploy_core_aks.apps, {}), try(var.deploy_core_aca.apps, {})) : k => a if a.url != null && !can(regex("\\.svc\\.cluster\\.local", coalesce(a.url, "x"))) }
  catalog_url = try(local.core_apps["hello-catalog-api"].url, null)
  orders_url  = coalesce(var.settings.orders_api_url, try(local.core_apps["hello-orders-api"].url, null), "unset")
  durable_url = coalesce(var.settings.durable_api_url, try("https://${var.deploy_durable.function_app.hostname}", null), "unset")
  api_origin  = coalesce(try(var.deploy_core_aca.public_api.origin, null), try(var.deploy_core_aks.public_api.origin, null), "unset")
  frontend    = try(var.deploy_frontend.url, null)

  jobs = merge(
    {
      seed = {
        svc = "hello-jobs", trigger = "manual", args = ["seed"], timeout = 600, cpu = 0.5, memory = "1Gi"
        env = merge(
          { ADAPTERS_JSON = jsonencode(var.settings.adapters) },
          local.catalog_url == null ? {} : { CATALOG_API_URL = local.catalog_url },
        )
      }
      reconcile = {
        svc = "hello-jobs", trigger = "schedule", cron = var.settings.reconcile_cron, args = ["reconcile-trigger"], timeout = 300, cpu = 0.25, memory = "0.5Gi"
        env = local.durable_url == "unset" ? {} : { DURABLE_API_URL = local.durable_url }
      }
    },
    var.settings.batch_processor.enabled ? {
      batchitems = {
        svc = "hello-jobs", trigger = "event", args = ["process-batch-items"], timeout = 300, cpu = 0.5, memory = "1Gi"
        env = merge(
          {
            MESSAGING_MODE     = "servicebus"
            SERVICEBUS_FQDN    = local.sb.fqdn
            SB_QUEUE           = local.sb.queues["batch-items"].name
            BATCH_MAX_MESSAGES = tostring(var.settings.batch_processor.messages_per_job)
            RESULT_SINK        = var.settings.result_tables_endpoint == null ? "log" : "table"
          },
          var.settings.result_tables_endpoint == null ? {} : { TABLES_ENDPOINT = var.settings.result_tables_endpoint },
        )
      }
    } : {},
    var.settings.traffic.enabled && local.frontend != null ? {
      traffic = {
        svc = "hello-traffic", trigger = "schedule", cron = var.settings.traffic_cron, args = [], timeout = var.settings.traffic.duration_seconds + 120, cpu = 1, memory = "2Gi"
        env = {
          FRONTEND_URL             = local.frontend
          API_BASE_URL             = local.api_origin
          TRAFFIC_RPS              = tostring(var.settings.traffic.rps)
          TRAFFIC_DURATION_SECONDS = tostring(var.settings.traffic.duration_seconds)
          TRAFFIC_BROWSER_JOURNEYS = tostring(var.settings.traffic.browser_journeys)
        }
      }
    } : {},
  )
}

module "env" {
  source   = "../modules/app-env"
  for_each = local.jobs

  service = {
    name    = each.value.svc
    version = local.artifact_version[module.meta.services[each.value.svc].artifact]
    commit  = local.artifact_commit[module.meta.services[each.value.svc].artifact]
    env     = local.env_name
    team    = module.meta.services[each.value.svc].team
    owner   = module.meta.services[each.value.svc].owner
    domain  = module.meta.services[each.value.svc].domain
    tier    = module.meta.services[each.value.svc].tier
    region  = local.location
  }
  runtime            = "python"
  architecture       = "aca"
  telemetry          = local.telemetry
  identity_client_id = local.ids[each.value.svc].client_id
  faults             = { enabled = false }
  port               = null
  log_level          = var.settings.log_level
  trace_sample_ratio = var.settings.trace_sample_ratio
  extra_env          = merge(each.value.env, { JOB_NAME = each.key }, local.orders_url == "unset" ? {} : { ORDERS_API_URL = local.orders_url })
}

locals {
  # Jobs log to stdout only (see header); drop the sidecar file sink the ACA hook would add.
  job_env = { for k in keys(local.jobs) : k => { for n, v in module.env[k].env : n => v if n != "LOG_FILE_PATH" } }
}

resource "azurerm_container_app_job" "this" {
  for_each                     = local.jobs
  name                         = "${local.prefix}-caj-${each.key}-${local.env_name}"
  resource_group_name          = azurerm_resource_group.this.name
  location                     = coalesce(local.aca.location, local.location)
  container_app_environment_id = local.aca.environment_id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = each.value.timeout
  replica_retry_limit          = each.value.trigger == "event" ? 1 : 0
  tags                         = merge(local.tags, { service = each.value.svc, version = local.artifact_version[module.meta.services[each.value.svc].artifact] }, module.env[each.key].azure_tags)

  identity {
    type         = "UserAssigned"
    identity_ids = [local.ids[each.value.svc].id]
  }

  registry {
    server   = var.platform_shared.acr_login_server
    identity = local.ids[each.value.svc].id
  }

  # No Container Apps secrets: secret settings (e.g. FAULT_TOKEN) are env values holding dsv:// references that the
  # job resolves at start-up with its managed identity (ADR-0001 §14). Jobs have no sidecar, so no dsv-fetch.
  dynamic "manual_trigger_config" {
    for_each = each.value.trigger == "manual" ? [1] : []
    content {
      parallelism              = 1
      replica_completion_count = 1
    }
  }

  dynamic "schedule_trigger_config" {
    for_each = each.value.trigger == "schedule" ? [1] : []
    content {
      cron_expression          = each.value.cron
      parallelism              = 1
      replica_completion_count = 1
    }
  }

  dynamic "event_trigger_config" {
    for_each = each.value.trigger == "event" ? [1] : []
    content {
      parallelism              = 1
      replica_completion_count = 1
      scale {
        min_executions              = 0
        max_executions              = var.settings.batch_processor.max_executions
        polling_interval_in_seconds = var.settings.batch_processor.polling_seconds
        rules {
          name             = "servicebus-batch-items"
          custom_rule_type = "azure-servicebus"
          # Workload identity auth for the KEDA scaler (no connection string secret).
          identity_id = local.ids[each.value.svc].id
          metadata = {
            namespace    = local.sb.namespace_name
            queueName    = local.sb.queues["batch-items"].name
            messageCount = tostring(var.settings.batch_processor.messages_per_job)
          }
        }
      }
    }
  }

  template {
    container {
      name   = each.value.svc
      image  = try(var.artifacts[module.meta.services[each.value.svc].artifact].image, null)
      args   = each.value.args
      cpu    = each.value.cpu
      memory = each.value.memory

      dynamic "env" {
        for_each = sort(keys(local.job_env[each.key]))
        content {
          name  = env.value
          value = local.job_env[each.key][env.value]
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = can(regex("@sha256:[a-f0-9]{64}$", var.artifacts[module.meta.services[each.value.svc].artifact].image))
      error_message = "Job images must be digest-pinned (svc-jobs / svc-traffic)."
    }
  }
}

# dsv-fetch (sidecar key init/refresher container): this root's registry artifact img-dsv-fetch (digest-pinned) wins
# over the image published in the transport contract (ADR-0001 section 14).
locals {
  telemetry = merge(var.obs_telemetry_transport, {
    secrets = merge(var.obs_telemetry_transport.secrets, {
      fetch_image = try(coalesce(try(var.artifacts["img-dsv-fetch"].image, null), var.obs_telemetry_transport.secrets.fetch_image), null)
    })
  })
}
