# foundation-pr-reviewer: the TRUSTED automated PR reviewer (eh-pr-reviewer, applications/services/pr-reviewer).
# It is lab governance tooling, not a workload: it owns its identity, runtime storage, Flex Consumption plan and
# function app in one root so the trust boundary (deployed only from main, identity used only here) stays in one
# place. The app package is deployed by the pipeline from main only (never from a PR build).
module "naming" {
  source          = "../modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = "prr"
}

module "tags" {
  source    = "../modules/tags"
  component = "foundation-pr-reviewer"
  layer     = "foundation"
  domain    = "governance"
  service   = "eh-pr-reviewer"
  environment = {
    name        = var.environment.name
    location    = var.environment.location
    owner       = var.environment.owner
    team        = var.environment.team
    cost_center = var.environment.cost_center
    expires_on  = var.environment.expires_on
    tags        = var.environment.tags
  }
}

locals {
  s        = var.settings
  tags     = module.tags.tags
  names    = module.naming.names
  location = var.environment.location
  vnet     = local.s.network_mode == "vnet"
  dsv      = var.foundation_identity.secrets
  base     = local.dsv.base_path
  app_name = "${var.environment.name_prefix}-func-pr-reviewer-${var.environment.name}-${module.naming.suffix}"
  # ADO display name of the managed identity once it is added to the organization (author/bot checks).
  identity_name = "${var.environment.name_prefix}-id-pr-reviewer-${var.environment.name}"

  webhook_ref   = "dsv://${local.base}/${local.s.webhook_secret_name}#value"
  anthropic_ref = "dsv://${local.base}/${local.s.anthropic_api_key_name}#value"
  secret_names  = concat([local.s.webhook_secret_name], local.s.ai_enabled ? [local.s.anthropic_api_key_name] : [])

  allowed_ranges = distinct(concat(local.s.allowed_ip_ranges,
  local.s.allow_deploy_agent_egress && var.foundation_network != null ? try(var.foundation_network.egress.public_ips, []) : []))
  host_roles = {
    blob  = "Storage Blob Data Owner"
    queue = "Storage Queue Data Contributor"
    table = "Storage Table Data Contributor"
  }
}

resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

# The reviewer's identity: added to the Azure DevOps organization as a user (Basic) with Read + Contribute to pull
# requests on the lab repository only (tools/review/ado_setup.py), and mapped to a DSV user (dsv_desired_state).
resource "azurerm_user_assigned_identity" "pr_reviewer" {
  name                = local.identity_name
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  tags                = local.tags
}

# ------------------------------------------------------------------------------------------- runtime storage
resource "azurerm_storage_account" "this" {
  #checkov:skip=CKV_AZURE_59:public mode is Entra-only (shared keys off); vnet mode disables public access - checkov cannot evaluate the variable.
  #checkov:skip=CKV_AZURE_35:network_rules default_action is Deny in vnet mode (variable-driven).
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys are sufficient (queue messages hold PR ids only, no source code or secrets).
  #checkov:skip=CKV_AZURE_206:LRS is the low-cost lab default (settings.storage_replication).
  #checkov:skip=CKV2_AZURE_33:Private endpoints are created in vnet mode.
  #checkov:skip=CKV_AZURE_33:Queue service logging is a diagnostic setting owned by observability (ADR-0001 section 3 rule 4).
  #checkov:skip=CKV2_AZURE_21:Blob service logging is a diagnostic setting owned by observability (ADR-0001 section 3 rule 4).
  name                             = substr("${module.naming.unique.storage}", 0, 24)
  resource_group_name              = azurerm_resource_group.this.name
  location                         = local.location
  account_tier                     = "Standard"
  account_kind                     = "StorageV2"
  account_replication_type         = local.s.storage_replication
  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  shared_access_key_enabled        = false
  default_to_oauth_authentication  = true
  allow_nested_items_to_be_public  = false
  public_network_access            = local.vnet ? "Disabled" : "Enabled"
  local_user_enabled               = false
  sftp_enabled                     = false
  cross_tenant_replication_enabled = false
  tags                             = local.tags

  network_rules {
    default_action = local.vnet ? "Deny" : "Allow"
    bypass         = ["AzureServices"]
  }

  blob_properties {
    delete_retention_policy {
      days = local.s.blob_retention_days
    }
    container_delete_retention_policy {
      days = local.s.blob_retention_days
    }
  }

  sas_policy {
    expiration_period = "01.00:00:00"
    expiration_action = "Log"
  }
}

resource "azurerm_storage_container" "deploy" {
  #checkov:skip=CKV2_AZURE_21:Blob logging is a diagnostic setting owned by observability.
  name                  = "deploy"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "locks" {
  #checkov:skip=CKV2_AZURE_21:Blob logging is a diagnostic setting owned by observability.
  name                  = "locks"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_queue" "jobs" {
  name               = local.s.queue_name
  storage_account_id = azurerm_storage_account.this.id
}

resource "azurerm_role_assignment" "storage" {
  for_each = local.host_roles

  scope                = azurerm_storage_account.this.id
  role_definition_name = each.value
  principal_id         = azurerm_user_assigned_identity.pr_reviewer.principal_id
  principal_type       = "ServicePrincipal"
  description          = "eh-pr-reviewer host/queue/lease storage (${each.key})"
}

module "storage_pe" {
  source   = "../modules/private-endpoint"
  for_each = local.vnet && var.foundation_network != null ? toset(["blob", "queue", "table"]) : toset([])

  name                 = "${local.names.private_endpoint}-st-${each.key}"
  resource_group_name  = azurerm_resource_group.this.name
  location             = local.location
  subnet_id            = try(var.foundation_network.subnets["private-endpoints"].id, null)
  target_resource_id   = azurerm_storage_account.this.id
  subresource_names    = [each.key]
  private_dns_zone_ids = try([var.foundation_network.private_dns_zones[each.key].id], [])
  tags                 = local.tags
}

# ------------------------------------------------------------------------------------------- Flex Consumption app
resource "azurerm_service_plan" "this" {
  #checkov:skip=CKV_AZURE_225:Serverless Flex Consumption plan in a single-zone lab; zone redundancy not required.
  #checkov:skip=CKV_AZURE_212:Serverless plan scales automatically; no fixed minimum instance count.
  name                = "${local.names.app_service_plan}-flex"
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = local.tags
}

# ownership:allow OWN007 trusted PR reviewer: governance tooling whose identity, storage and app form one trust boundary (docs/guides/automated-pr-review.md)
resource "azurerm_function_app_flex_consumption" "this" {
  #checkov:skip=CKV_AZURE_221:Azure DevOps service hooks need a public HTTPS endpoint; inbound is restricted to the AzureDevOps service tag and requests are authenticated with the DSV webhook secret.
  #checkov:skip=CKV_AZURE_56:App Service authentication is not used; Azure DevOps authenticates with HTTP Basic (webhook secret) validated in constant time by the app.
  name                = local.app_name
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  service_plan_id     = azurerm_service_plan.this.id
  tags                = local.tags

  runtime_name           = "python"
  runtime_version        = "3.13"
  maximum_instance_count = local.s.maximum_instance_count
  instance_memory_in_mb  = local.s.instance_memory_in_mb

  storage_container_type            = "blobContainer"
  storage_container_endpoint        = "${azurerm_storage_account.this.primary_blob_endpoint}${azurerm_storage_container.deploy.name}"
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = azurerm_user_assigned_identity.pr_reviewer.id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.pr_reviewer.id]
  }

  https_only                                     = true
  public_network_access_enabled                  = true
  virtual_network_subnet_id                      = local.vnet ? try(var.foundation_network.subnets["flex-integration"].id, null) : null
  webdeploy_publish_basic_authentication_enabled = false
  client_certificate_mode                        = "Optional"

  # ownership:allow OWN007 the reviewer's settings live with its trust boundary; secrets are dsv:// references only
  app_settings = merge({
    AzureWebJobsStorage__accountName = azurerm_storage_account.this.name
    AzureWebJobsStorage__credential  = "managedidentity"
    AzureWebJobsStorage__clientId    = azurerm_user_assigned_identity.pr_reviewer.client_id
    ReviewQueue__queueServiceUri     = azurerm_storage_account.this.primary_queue_endpoint
    ReviewQueue__credential          = "managedidentity"
    ReviewQueue__clientId            = azurerm_user_assigned_identity.pr_reviewer.client_id
    REVIEW_QUEUE_NAME                = azurerm_storage_queue.jobs.name
    REVIEW_LOCK_CONTAINER_URI        = "${azurerm_storage_account.this.primary_blob_endpoint}${azurerm_storage_container.locks.name}"
    AZURE_CLIENT_ID                  = azurerm_user_assigned_identity.pr_reviewer.client_id
    ADO_ORGANIZATION                 = local.s.ado.organization
    ADO_PROJECT                      = local.s.ado.project
    ADO_PROJECT_ID                   = lower(local.s.ado.project_id)
    ADO_REPOSITORY_IDS               = join(",", [for r in local.s.ado.repository_ids : lower(r)])
    ADO_ACCOUNT_IDS                  = join(",", local.s.ado.account_ids)
    ADO_REVIEWER_ID                  = local.s.ado.reviewer_id
    WEBHOOK_USERNAME                 = local.s.webhook_username
    WEBHOOK_SECRET                   = local.webhook_ref
    DSV_TENANT                       = local.dsv.tenant
    DSV_TLD                          = local.dsv.tld
    DSV_BASE_URL                     = local.dsv.base_url
    DD_ENV                           = var.environment.name
    DD_SERVICE                       = "eh-pr-reviewer"
    OTEL_SERVICE_NAME                = "eh-pr-reviewer"
    PYTHON_ENABLE_OPENTELEMETRY      = "true"
    }, local.s.ai_enabled ? { ANTHROPIC_API_KEY = local.anthropic_ref } : {},
    local.s.otlp_endpoint != "" ? { OTEL_EXPORTER_OTLP_ENDPOINT = local.s.otlp_endpoint, OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf" } : {},
  )

  site_config {
    minimum_tls_version               = "1.2"
    http2_enabled                     = true
    health_check_path                 = "/api/healthz"
    health_check_eviction_time_in_min = 10
    ip_restriction_default_action     = local.s.restrict_to_azure_devops ? "Deny" : "Allow"

    dynamic "ip_restriction" {
      for_each = local.s.restrict_to_azure_devops ? [1] : []
      content {
        name        = "azure-devops-service-hooks"
        action      = "Allow"
        service_tag = "AzureDevOps"
        priority    = 100
      }
    }
    dynamic "ip_restriction" {
      for_each = local.s.restrict_to_azure_devops ? local.allowed_ranges : []
      content {
        name       = "allow-${ip_restriction.key}"
        action     = "Allow"
        ip_address = ip_restriction.value
        priority   = 200 + ip_restriction.key
      }
    }
  }

  depends_on = [azurerm_role_assignment.storage]

  lifecycle {
    precondition {
      condition     = !local.vnet || (var.foundation_network != null && contains(keys(try(var.foundation_network.subnets, {})), "flex-integration") && contains(keys(try(var.foundation_network.subnets, {})), "private-endpoints"))
      error_message = "network_mode = vnet needs the foundation_network contract with flex-integration and private-endpoints subnets."
    }
  }
}

# ------------------------------------------------------------------------------------------- Delinea DSV access
# Same desired-state format as foundation-secrets (tools/secrets/dsv_apply.py), with its own marker: one DSV user
# for this identity (externalId = identity resource id) and one permission granting `read` on exactly its secrets.
locals {
  path_prefix = "secrets:${replace(local.base, "/", ":")}"
  dsv_user    = "${var.environment.name_prefix}-${var.environment.name}-pr-reviewer"
  dsv_desired_state = {
    schema_version = 1
    marker         = local.s.dsv_marker
    environment    = var.environment.name
    base_url       = local.dsv.base_url
    base_path      = local.base
    auth_provider  = { name = local.dsv.auth_provider, type = "azure", tenant_id = var.environment.tenant_id }
    users = {
      (local.dsv_user) = {
        username     = local.dsv_user
        qualified    = "${local.dsv.auth_provider}:${local.dsv_user}"
        provider     = local.dsv.auth_provider
        external_id  = azurerm_user_assigned_identity.pr_reviewer.id
        identity     = "pr-reviewer"
        display_name = "${local.s.dsv_marker} ${local.base} pr-reviewer"
      }
    }
    policy = {
      path = local.path_prefix
      permissions = [{
        key         = "read:pr-reviewer"
        description = "${local.s.dsv_marker} ${local.base} read pr-reviewer"
        subjects    = ["users:<${local.dsv.auth_provider}:${local.dsv_user}>"]
        effect      = "allow"
        actions     = ["read"]
        resources   = [for n in sort(local.secret_names) : "${local.path_prefix}:${n}"]
      }]
    }
    secrets = { for n in local.secret_names : n => { path = "${local.base}/${n}", ref = "dsv://${local.base}/${n}#value", source = "operator", publisher = null, readers = ["pr-reviewer"] } }
  }
}
