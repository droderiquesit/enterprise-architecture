# Logic Apps:
#   Consumption: hourly recurrence -> compose batch request -> Service Bus queue batch-items through the managed
#                Service Bus API connection authenticated with the user-assigned identity (azapi gap: azurerm_api_connection
#                cannot set parameterValueSet managedIdentityAuth).
#   Standard:    audit-archive workflow (order-events -> Blob Storage) on the WS1 plan; workflows are deployed as a zip
#                (svc-logicapps) by scripts/deploy-zip.sh. Logs: WorkflowRuntime diagnostic settings (obs-diagnostics).
module "meta" {
  source = "../modules/service-meta"
}

# Tag policy of the service for resources without an app-env (the Consumption workflow); the Standard app uses
# module.env[0].azure_tags (same tagging module inside the instrumentation hook).
module "svc_tags" {
  source = "../../../observability/modules/tagging"
  identity = {
    env         = local.env_name
    service     = local.svc
    version     = lookup(local.artifact_version, local.meta.artifact, "unknown")
    team        = local.meta.team
    owner       = local.meta.owner
    domain      = local.meta.domain
    tier        = local.meta.tier
    application = "enterprise-hello"
    region      = local.location
    managed_by  = "terraform"
    component   = "deploy-logicapps"
  }
}

resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  svc      = "hello-logicapps"
  meta     = module.meta.services[local.svc]
  identity = var.foundation_identity.identities[local.svc]
  sb       = var.platform_messaging
  as       = var.platform_appservice
  suffix   = module.naming.suffix

  consumption = var.settings.consumption_enabled
  la_plan     = try(local.as.plans["logicapps"], null)
  standard    = var.settings.standard_enabled && local.la_plan != null && local.as.logicapps_storage != null

  actions = jsondecode(var.settings.actions_file == null ? file("${path.module}/workflows/consumption-batch-request.actions.json") : file(var.settings.actions_file))

  private  = var.settings.network_mode == "private-endpoint" || (var.settings.network_mode == "auto" && var.foundation_network != null)
  st_parts = local.standard ? regex("/resourceGroups/([^/]+)/providers/Microsoft.Storage/storageAccounts/([^/]+)$", local.as.logicapps_storage.id) : ["", ""]
}

# ---------------------------------------------------------------- Consumption
resource "azapi_resource" "servicebus_connection" {
  count     = local.consumption ? 1 : 0
  type      = "Microsoft.Web/connections@2016-06-01"
  name      = "servicebus-${local.env_name}"
  parent_id = azurerm_resource_group.this.id
  location  = local.location
  tags      = local.tags

  body = {
    properties = {
      displayName = "Service Bus (managed identity)"
      api         = { id = "/subscriptions/${var.environment.subscription_id}/providers/Microsoft.Web/locations/${local.location}/managedApis/servicebus" }
      parameterValueSet = {
        name = "managedIdentityAuth"
        values = {
          namespaceEndpoint = { value = "sb://${local.sb.fqdn}/" }
        }
      }
    }
  }
  schema_validation_enabled = false # parameterValueSet is not in the embedded 2016-06-01 schema
}

resource "azurerm_logic_app_workflow" "batch_request" {
  count               = local.consumption ? 1 : 0
  name                = "${local.prefix}-logic-batchreq-${local.env_name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  tags                = merge(local.tags, { service = local.svc, version = lookup(local.artifact_version, local.meta.artifact, "n/a") }, module.svc_tags.azure_tags)

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity.id]
  }

  workflow_parameters = {
    "$connections" = jsonencode({ type = "Object", defaultValue = {} })
    "queueName"    = jsonencode({ type = "String", defaultValue = "batch-items" })
    "batchItems"   = jsonencode({ type = "Int", defaultValue = 10 })
  }
  parameters = {
    "$connections" = jsonencode({
      servicebus = {
        connectionId   = azapi_resource.servicebus_connection[0].id
        connectionName = azapi_resource.servicebus_connection[0].name
        id             = "/subscriptions/${var.environment.subscription_id}/providers/Microsoft.Web/locations/${local.location}/managedApis/servicebus"
        connectionProperties = {
          authentication = { type = "ManagedServiceIdentity", identity = local.identity.id }
        }
      }
    })
    "queueName"  = local.sb.queues["batch-items"].name
    "batchItems" = tostring(var.settings.batch_items)
  }
}

resource "azurerm_logic_app_trigger_recurrence" "hourly" {
  count        = local.consumption ? 1 : 0
  name         = "recurrence"
  logic_app_id = azurerm_logic_app_workflow.batch_request[0].id
  frequency    = var.settings.consumption_frequency
  interval     = var.settings.consumption_interval
}

resource "azurerm_logic_app_action_custom" "this" {
  for_each     = { for k, v in local.actions : k => jsonencode(v) if local.consumption }
  name         = each.key
  logic_app_id = azurerm_logic_app_workflow.batch_request[0].id
  body         = each.value
}

# ---------------------------------------------------------------- Standard
module "env" {
  source = "../modules/app-env"
  count  = local.standard ? 1 : 0
  service = {
    name    = local.svc
    version = lookup(local.artifact_version, local.meta.artifact, "unknown")
    commit  = lookup(local.artifact_commit, local.meta.artifact, "unknown")
    env     = local.env_name
    team    = local.meta.team
    owner   = local.meta.owner
    domain  = local.meta.domain
    tier    = local.meta.tier
    region  = local.location
  }
  runtime            = "dotnet"
  architecture       = "logicapp"
  telemetry          = var.obs_telemetry_transport
  identity_client_id = local.identity.client_id
  faults             = { enabled = false }
  port               = null
  extra_env = {
    serviceBus_fullyQualifiedNamespace = local.sb.fqdn
    serviceBus_clientId                = local.identity.client_id
    ARCHIVE_TOPIC                      = local.sb.topic.name
    ARCHIVE_SUBSCRIPTION               = var.settings.archive_subscription
    AzureBlob_blobStorageEndpoint      = try(local.as.logicapps_storage.blob_endpoint, "")
    ARCHIVE_CONTAINER                  = var.settings.archive_container
  }
}

data "azurerm_storage_account" "logicapps" {
  # Documented exception (README "Secrets in state"): the Workflow Standard host needs the storage account key
  # (AzureWebJobsStorage + the Azure Files content share; key access cannot be disabled outside ASE v3 - Microsoft
  # Learn) and azurerm_logic_app_standard has no write-only/identity-only form, so the key lands in state.
  count               = local.standard ? 1 : 0
  name                = local.st_parts[1]
  resource_group_name = local.st_parts[0]
}

resource "azurerm_logic_app_standard" "archive" {
  #checkov:skip=CKV_AZURE_222:Public access is disabled in private-endpoint mode (variable-driven).
  #checkov:skip=CKV_AZURE_213:Health check is not applicable to workflow hosts (no HTTP health route).
  count                                    = local.standard ? 1 : 0
  name                                     = "${local.prefix}-logic-archive-${local.env_name}-${local.suffix}"
  resource_group_name                      = local.as.resource_group_name
  location                                 = coalesce(local.as.location, local.location)
  app_service_plan_id                      = local.la_plan.id
  version                                  = "~4"
  https_only                               = true
  use_extension_bundle                     = true
  bundle_version                           = "[1.*, 2.0.0)"
  public_network_access                    = local.private ? "Disabled" : "Enabled"
  virtual_network_subnet_id                = local.as.integration_subnet_id
  ftp_publish_basic_authentication_enabled = false
  scm_publish_basic_authentication_enabled = false
  storage_account_name                     = local.as.logicapps_storage.name
  storage_account_access_key               = data.azurerm_storage_account.logicapps[0].primary_access_key
  tags                                     = merge(local.tags, { service = local.svc, version = lookup(local.artifact_version, local.meta.artifact, "n/a") }, module.env[0].azure_tags)

  # Built-in (service provider) Service Bus / Blob connectors authenticate with the SYSTEM-assigned identity
  # (most built-in connectors cannot select a user-assigned identity:
  # https://learn.microsoft.com/azure/logic-apps/single-tenant-overview-compare). The user-assigned identity is
  # kept for Delinea DSV reads by our code (dsv:// app settings) and the OTel/app-settings contract.
  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [local.identity.id]
  }

  app_settings = merge(module.env[0].app_settings, {
    FUNCTIONS_WORKER_RUNTIME = "dotnet"
    WEBSITE_RUN_FROM_PACKAGE = "1"
  })

  site_config {
    min_tls_version               = "1.2"
    ftps_state                    = "Disabled"
    vnet_route_all_enabled        = true
    ip_restriction_default_action = local.private ? null : "Deny"
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
  count  = local.standard && local.private ? 1 : 0

  name                 = "${local.names.private_endpoint}-logic-archive"
  resource_group_name  = local.as.resource_group_name
  location             = coalesce(local.as.location, local.location)
  subnet_id            = var.foundation_network.subnets["private-endpoints"].id
  target_resource_id   = azurerm_logic_app_standard.archive[0].id
  subresource_names    = ["sites"]
  private_dns_zone_ids = try([var.foundation_network.private_dns_zones["webapps"].id], [])
  tags                 = local.tags
}

# ------------------------------------------------- Standard: archive data path for the system-assigned identity
# The archive container is application data owned by this deployment root (created through ARM, no data-plane keys).
resource "azurerm_storage_container" "archive" {
  #checkov:skip=CKV2_AZURE_21:Storage read logging is a diagnostic setting owned by observability (obs-diagnostics, ADR-0001 rule 4), not by this root.
  count                 = local.standard ? 1 : 0
  name                  = var.settings.archive_container
  storage_account_id    = local.as.logicapps_storage.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "archive_receiver" {
  count                = local.standard && contains(keys(local.sb.subscriptions), var.settings.archive_subscription) ? 1 : 0
  scope                = local.sb.subscriptions[var.settings.archive_subscription].id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_logic_app_standard.archive[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Logic Apps Standard built-in Service Bus trigger (system identity) on order-events/${var.settings.archive_subscription}"
}

resource "azurerm_role_assignment" "archive_writer" {
  count                = local.standard ? 1 : 0
  scope                = azurerm_storage_container.archive[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_logic_app_standard.archive[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Logic Apps Standard built-in Blob connector (system identity) writes the order archive"
}
