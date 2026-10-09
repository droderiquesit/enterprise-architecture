resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  identities = var.foundation_identity.identities
  identity   = local.identities[var.settings.identity]
  pool       = var.settings.pool
  private    = !var.settings.public_network_access_enabled
  batch_zone = try([var.foundation_network.private_dns_zones["batch"].id], [])
  zones      = { for k in ["blob"] : k => var.foundation_network.private_dns_zones[k].id if contains(keys(var.foundation_network.private_dns_zones), k) }

  # Scale to zero; grow with pending tasks up to the ceiling (Microsoft sample formula).
  autoscale_formula = <<-EOT
    startingNumberOfVMs = 0;
    maxNumberofVMs = ${local.pool.max_dedicated_nodes};
    pendingTaskSamplePercent = $PendingTasks.GetSamplePercent(180 * TimeInterval_Second);
    pendingTaskSamples = pendingTaskSamplePercent < 70 ? startingNumberOfVMs : avg($PendingTasks.GetSample(180 * TimeInterval_Second));
    $TargetDedicatedNodes = min(maxNumberofVMs, pendingTaskSamples);
    $TargetLowPriorityNodes = 0;
    $NodeDeallocationOption = taskcompletion;
  EOT

  start_task = join(" && ", [
    "set -eu",
    "export DEBIAN_FRONTEND=noninteractive",
    "apt-get update",
    "apt-get install -y software-properties-common ca-certificates",
    "add-apt-repository -y ppa:deadsnakes/ppa",
    "apt-get update",
    "apt-get install -y python${local.pool.python_version} python${local.pool.python_version}-venv",
    "python${local.pool.python_version} --version",
  ])

  submitters = { for k in var.settings.job_submitter_identities : k => local.identities[k] if contains(keys(local.identities), k) }
}

# ---------------------------------------------------------------- auto-storage (identity-based)
module "auto_storage" {
  source = "../../modules/compute-runtime-storage"

  name                          = substr("${local.unique.storage}ba", 0, 24)
  resource_group_name           = azurerm_resource_group.this.name
  location                      = local.location
  replication                   = var.settings.storage_replication
  public_network_access_enabled = !local.private
  containers                    = ["jobs-packages", "jobs-output"]
  private_endpoints             = local.private ? ["blob"] : []
  private_endpoint_subnet_id    = local.subnets["private-endpoints"].id
  private_endpoint_name_prefix  = local.names.private_endpoint
  private_dns_zone_ids          = local.zones
  tags                          = local.tags
  role_assignments = {
    "${var.settings.identity}-blob" = { principal_id = local.identity.principal_id, role = "Storage Blob Data Contributor" }
  }
}

# ---------------------------------------------------------------- account
resource "azurerm_batch_account" "this" {
  #checkov:skip=CKV_AZURE_76:Customer-managed keys (Key Vault) are not used for synthetic lab data; Microsoft-managed keys apply.
  name                                = substr(replace(local.unique.globally_unique, "-", ""), 0, 24)
  resource_group_name                 = azurerm_resource_group.this.name
  location                            = local.location
  pool_allocation_mode                = "BatchService"
  public_network_access_enabled       = var.settings.public_network_access_enabled
  allowed_authentication_modes        = ["AAD"] # Entra only: no SharedKey; task tokens unsupported without public IPs
  storage_account_id                  = module.auto_storage.id
  storage_account_authentication_mode = "BatchAccountManagedIdentity"
  storage_account_node_identity       = local.identity.id
  tags                                = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity.id]
  }

  depends_on = [module.auto_storage]
}

# Simplified node communication + no public IPs require the nodeManagement endpoint; the
# batchAccount endpoint serves the Batch API (job submission) when public access is disabled.
module "private_endpoint" {
  for_each = local.private ? toset(["batchAccount", "nodeManagement"]) : toset([])
  source   = "../../../foundation/modules/private-endpoint"

  name                 = "${local.names.private_endpoint}-batch-${lower(each.key)}"
  resource_group_name  = azurerm_resource_group.this.name
  location             = local.location
  subnet_id            = local.subnets["private-endpoints"].id
  target_resource_id   = azurerm_batch_account.this.id
  subresource_names    = [each.key]
  private_dns_zone_ids = local.batch_zone # privatelink.batch.azure.com (foundation key "batch")
  tags                 = local.tags
}

# ---------------------------------------------------------------- pool
resource "azurerm_batch_pool" "this" {
  name                           = local.pool.name
  resource_group_name            = azurerm_resource_group.this.name
  account_name                   = azurerm_batch_account.this.name
  display_name                   = "hello-jobs daily aggregate"
  vm_size                        = local.pool.vm_size
  node_agent_sku_id              = local.pool.node_agent_sku_id
  max_tasks_per_node             = local.pool.max_tasks_per_node
  target_node_communication_mode = "Simplified" # classic mode retired 2026-03-31
  inter_node_communication       = "Disabled"

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity.id]
  }

  storage_image_reference {
    publisher = local.pool.image.publisher
    offer     = local.pool.image.offer
    sku       = local.pool.image.sku
    version   = local.pool.image.version
  }

  auto_scale {
    evaluation_interval = "PT5M"
    formula             = local.autoscale_formula
  }

  network_configuration {
    subnet_id                        = local.subnets["batch"].id
    public_address_provisioning_type = "NoPublicIPAddresses"
    accelerated_networking_enabled   = false
  }

  start_task {
    command_line       = "/bin/bash -c '${local.start_task}'"
    wait_for_success   = true
    task_retry_maximum = 2
    common_environment_properties = {
      HELLO_PYTHON = "python${local.pool.python_version}"
    }
    user_identity {
      auto_user {
        elevation_level = "Admin"
        scope           = "Pool"
      }
    }
  }

  depends_on = [module.private_endpoint]
}

# ---------------------------------------------------------------- RBAC
resource "azurerm_role_assignment" "job_submitter" {
  for_each = local.submitters

  scope                = azurerm_batch_account.this.id
  role_definition_name = "Azure Batch Job Submitter"
  principal_id         = each.value.principal_id
  principal_type       = "ServicePrincipal"
  description          = "Submit hello-jobs Batch jobs (${each.key})"
}
