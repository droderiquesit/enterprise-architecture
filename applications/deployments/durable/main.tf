# hello-durable (.NET 10 isolated Durable Functions) on Flex Consumption + optional Windows Consumption app
# running only Reconciliation. Identity-based host storage (AzureWebJobsStorage__*), identity-based Service Bus
# trigger connection (ServiceBusConnection__*), VNet integration (flex-integration subnet), OTel to the gateway,
# logs via diagnostic settings (FunctionAppLogs -> Event Hubs, owned by obs-diagnostics) - no sidecar.
# Code is deployed by the pipeline (scripts/deploy-zip.sh -> az functionapp deployment source config-zip / one deploy).
module "meta" {
  source = "../modules/service-meta"
}

locals {
  svc      = "hello-durable"
  meta     = module.meta.services[local.svc]
  artifact = local.meta.artifact
  fx       = var.platform_functions
  flex     = local.fx.flex[var.settings.flex_app_key]
  identity = var.foundation_identity.identities[local.flex.identity]
  rg       = local.fx.resource_group_name
  fx_loc   = coalesce(local.fx.location, local.location)
  task_hub = coalesce(var.settings.task_hub, "hellodurable${local.env_name}")
  suffix   = module.naming.suffix

  y1_enabled = local.fx.consumption_windows != null && var.settings.windows_consumption_enabled
  y1_ident   = local.y1_enabled ? var.foundation_identity.identities[local.fx.consumption_windows.identity] : null

  private = var.settings.network_mode == "private-endpoint" || (var.settings.network_mode == "auto" && var.foundation_network != null)
  pe_zone = try(var.foundation_network.private_dns_zones["webapps"].id, null)

  # Upstream URLs: settings override > optional deploy contracts > unset (the code then simulates the call).
  # Kubernetes-internal URLs (*.svc.cluster.local) are not resolvable from Functions and are ignored.
  core_urls             = { for k, a in merge(try(var.deploy_core_aks.apps, {}), try(var.deploy_core_aca.apps, {})) : k => a.url if a.url != null && !can(regex("\\.svc\\.cluster\\.local", coalesce(a.url, "x"))) }
  appsvc_apps           = try(var.deploy_appservice.apps, {})
  appsvc_inventory_urls = [for k in sort(keys(local.appsvc_apps)) : local.appsvc_apps[k].url if local.appsvc_apps[k].service == "hello-inventory-api" && local.appsvc_apps[k].url != null]
  orders_url            = coalesce(var.settings.orders_api_url, lookup(local.core_urls, "hello-orders-api", null), "unset")
  inventory_url         = coalesce(var.settings.inventory_api_url, try(local.appsvc_inventory_urls[0], null), lookup(local.core_urls, "hello-inventory-api", null), "unset")
  partner_url           = coalesce(var.settings.partner_api_url, try(var.deploy_partner_sim.url, null), "unset")

  # Functions that run on the Windows Consumption app only (Reconciliation) are disabled on Flex and vice versa.
  reconciliation_functions = ["ReconciliationTimer", "StartReconciliation"]
  flex_only_functions      = ["OrderEventsStarter", "StartOrderWorkflow", "StartBatch", "PurgeHistory"]

  common_env = merge(
    {
      DURABLE_TASK_HUB                              = local.task_hub
      RECONCILE_SCHEDULE                            = var.settings.reconcile_schedule
      DURABLE_HISTORY_RETENTION_DAYS                = tostring(var.settings.history_retention_days)
      PAYMENT_TIMEOUT_SECONDS                       = tostring(var.settings.payment_timeout_secs)
      STORAGE_MODE                                  = "sql"
      SQL_CONNECTION_STRING                         = "Server=tcp:${var.platform_db_sql.server.fqdn},${var.platform_db_sql.server.port};Database=${var.platform_db_sql.databases["fulfillment"].name};Encrypt=True"
      SQL_USE_AZURE_CREDENTIAL                      = "true"
      SERVICEBUS_FQDN                               = var.platform_messaging.fqdn
      BATCH_ITEMS_QUEUE                             = var.platform_messaging.queues["batch-items"].name
      ServiceBusConnection__fullyQualifiedNamespace = var.platform_messaging.fqdn
      ServiceBusConnection__credential              = "managedidentity"
    },
    local.orders_url == "unset" ? {} : { ORDERS_API_URL = local.orders_url },
    local.inventory_url == "unset" ? {} : { INVENTORY_API_URL = local.inventory_url },
    local.partner_url == "unset" ? {} : { PARTNER_API_URL = local.partner_url },
    var.settings.faults_enabled ? { FAULT_ACTIVITY_FAILURE_RATE = tostring(var.settings.activity_failure_rate) } : {},
  )
}

module "env" {
  source = "../modules/app-env"
  service = {
    name    = local.svc
    version = local.artifact_version[local.artifact]
    commit  = local.artifact_commit[local.artifact]
    env     = local.env_name
    team    = local.meta.team
    owner   = local.meta.owner
    domain  = local.meta.domain
    tier    = local.meta.tier
    region  = local.fx_loc
  }
  runtime            = "dotnet"
  architecture       = "functions"
  telemetry          = var.obs_telemetry_transport
  identity_client_id = local.identity.client_id
  faults = {
    enabled   = var.settings.faults_enabled
    token_ref = lookup(var.foundation_identity.secrets.refs, "fault-token", null)
  }
  port               = null
  log_level          = var.settings.log_level
  trace_sample_ratio = var.settings.trace_sample_ratio
  # Functions host: OTLP over HTTP to the gateway (http/protobuf), generic endpoint so the host emits Durable V2 spans.
  otlp_protocol = "http/protobuf"
  extra_env     = local.common_env
}

resource "azurerm_function_app_flex_consumption" "this" {
  #checkov:skip=CKV_AZURE_221:public_network_access_enabled is false in private-endpoint mode; restricted mode denies by default with explicit allow ranges.
  name                = "${local.prefix}-func-durable-${local.env_name}-${local.suffix}"
  resource_group_name = local.rg
  location            = local.fx_loc
  service_plan_id     = local.flex.plan_id
  tags                = merge(local.tags, { service = local.svc, version = local.artifact_version[local.artifact] })

  runtime_name           = "dotnet-isolated"
  runtime_version        = "10.0"
  maximum_instance_count = var.settings.maximum_instance_count
  instance_memory_in_mb  = var.settings.instance_memory_in_mb
  http_concurrency       = var.settings.http_concurrency

  # Deployment package container (one deploy) with the user-assigned identity; no keys.
  storage_container_type            = "blobContainer"
  storage_container_endpoint        = local.flex.deployment_container_url
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = local.identity.id

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity.id]
  }

  https_only                                     = true
  public_network_access_enabled                  = !local.private
  virtual_network_subnet_id                      = local.fx.flex_integration_subnet_id
  webdeploy_publish_basic_authentication_enabled = false
  client_certificate_mode                        = "Optional"

  app_settings = merge(module.env.app_settings, {
    AzureWebJobsStorage__accountName = local.flex.storage_account_name
    AzureWebJobsStorage__credential  = "managedidentity"
    AzureWebJobsStorage__clientId    = local.identity.client_id
    ServiceBusConnection__clientId   = local.identity.client_id
    }, local.y1_enabled ? { for f in local.reconciliation_functions : "AzureWebJobs.${f}.Disabled" => "true" } : {},
  )

  dynamic "always_ready" {
    for_each = var.settings.always_ready_instances > 0 ? [1] : []
    content {
      name           = "durable"
      instance_count = var.settings.always_ready_instances
    }
  }

  site_config {
    minimum_tls_version               = "1.2"
    http2_enabled                     = true
    health_check_path                 = "/api/healthz"
    health_check_eviction_time_in_min = 10
    ip_restriction_default_action     = local.private ? null : "Deny"

    dynamic "ip_restriction" {
      for_each = local.private ? [] : var.settings.allowed_ip_ranges
      content {
        name       = "allow-${ip_restriction.key}"
        action     = "Allow"
        ip_address = ip_restriction.value
        priority   = 100 + ip_restriction.key
      }
    }
  }
}

module "private_endpoint" {
  source = "../../../foundation/modules/private-endpoint"
  count  = local.private ? 1 : 0

  name                 = "${local.names.private_endpoint}-durable"
  resource_group_name  = local.rg
  location             = local.fx_loc
  subnet_id            = var.foundation_network.subnets["private-endpoints"].id
  target_resource_id   = azurerm_function_app_flex_consumption.this.id
  subresource_names    = ["sites"]
  private_dns_zone_ids = local.pe_zone == null ? [] : [local.pe_zone]
  tags                 = local.tags
}

# ---------------------------------------------------------------- Windows Consumption (Reconciliation only)
resource "azurerm_windows_function_app" "reconciliation" {
  #checkov:skip=CKV_AZURE_221:Consumption (Y1) has no private endpoint support; only Reconciliation timer + private-callers HTTP run here, denied by default via ip restrictions.
  #checkov:skip=CKV_AZURE_56:Authentication is not used; the HTTP surface is restricted by ip_restriction.
  count               = local.y1_enabled ? 1 : 0
  name                = "${local.prefix}-func-durrec-${local.env_name}-${local.suffix}"
  resource_group_name = local.rg
  location            = local.fx_loc
  service_plan_id     = local.fx.consumption_windows.plan_id
  tags                = merge(local.tags, { service = local.svc, version = local.artifact_version[local.artifact] })

  https_only                                     = true
  public_network_access_enabled                  = true
  builtin_logging_enabled                        = false
  functions_extension_version                    = "~4"
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  key_vault_reference_identity_id                = local.y1_ident.id
  # Identity-based host storage: the provider writes AzureWebJobsStorage__accountName; credential/clientId below
  # select the user-assigned identity.
  storage_account_name          = local.fx.consumption_windows.storage_account_name
  storage_uses_managed_identity = true

  identity {
    type         = "UserAssigned"
    identity_ids = [local.y1_ident.id]
  }

  # Run from the immutable package URL with the user-assigned identity (no Azure Files content share, no SAS).
  app_settings = merge(module.env.app_settings, {
    AZURE_CLIENT_ID                              = local.y1_ident.client_id
    AzureWebJobsStorage__accountName             = local.fx.consumption_windows.storage_account_name
    AzureWebJobsStorage__credential              = "managedidentity"
    AzureWebJobsStorage__clientId                = local.y1_ident.client_id
    ServiceBusConnection__clientId               = local.y1_ident.client_id
    DURABLE_TASK_HUB                             = "${local.task_hub}rec"
    WEBSITE_RUN_FROM_PACKAGE                     = try(var.artifacts[local.artifact].package_url, "")
    WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID = local.y1_ident.id
    }, { for f in local.flex_only_functions : "AzureWebJobs.${f}.Disabled" => "true" },
  )

  site_config {
    minimum_tls_version           = "1.2"
    use_32_bit_worker             = false
    ip_restriction_default_action = "Deny"
    application_stack {
      dotnet_version              = "v10.0"
      use_dotnet_isolated_runtime = true
    }
    dynamic "ip_restriction" {
      for_each = var.settings.allowed_ip_ranges
      content {
        name       = "allow-${ip_restriction.key}"
        action     = "Allow"
        ip_address = ip_restriction.value
        priority   = 100 + ip_restriction.key
      }
    }
  }
}

check "durable_artifact" {
  assert {
    condition     = try(var.artifacts[local.artifact].package_url != null, false)
    error_message = "svc-durable package (package_url + package_sha256) is required for the deploy step."
  }
}
