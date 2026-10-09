locals {
  enabled = var.settings.enabled
  sub     = "/subscriptions/${var.environment.subscription_id}/providers/Microsoft.Authorization/roleDefinitions"
  master  = try(local.subnets["aro-master"].id, null)
  worker  = try(local.subnets["aro-worker"].id, null)
  vnet_id = var.foundation_network.spoke_vnet_id

  # Platform workload identities (operator name => role definition GUID + scope kind), per
  # https://learn.microsoft.com/azure/openshift/howto-create-openshift-cluster (managed identities).
  operators = {
    "cloud-controller-manager" = { role = "a1f96423-95ce-4224-ab27-4e3dc72facd4", scope = "subnets" }
    "ingress"                  = { role = "0336e1d3-7a87-462b-b6db-342b63f7802c", scope = "subnets" }
    "machine-api"              = { role = "0358943c-7e01-48ba-8889-02cc51d78637", scope = "subnets" }
    "disk-csi-driver"          = { role = null, scope = "none" }
    "cloud-network-config"     = { role = "be7a6435-15ae-4171-8f30-4a343eff9e8f", scope = "vnet" }
    "image-registry"           = { role = "8b32b316-c2f5-4ddf-b05b-83dacd2d08b5", scope = "vnet" }
    "file-csi-driver"          = { role = "0d7aedc0-15fd-4a67-a412-efad370c947e", scope = "vnet" }
    "aro-operator"             = { role = "4436bae4-7702-4c84-919b-c4069ff25ee2", scope = "subnets" }
  }
  federated_credential_role = "ef318e2a-8334-4a05-9e4a-295a196c6a6e" # cluster identity over operator identities
  aro_rp_network_role       = "42f3c60f-e7b1-46d7-ba56-6de681664342" # ARO RP over the VNet

  subnet_scopes = compact(concat([local.master, local.worker], var.settings.extra_network_resource_ids))
  operator_grants = local.enabled ? merge([
    for op, cfg in local.operators : (
      cfg.scope == "subnets" ? { for i, s in local.subnet_scopes : "${op}-${i}" => { op = op, role = cfg.role, scope = s } } :
      cfg.scope == "vnet" ? { "${op}-vnet" = { op = op, role = cfg.role, scope = local.vnet_id } } : {}
    )
  ]...) : {}

  pull_secret_name = var.settings.pull_secret_secret_id == null ? null : regex("/secrets/([^/]+)", var.settings.pull_secret_secret_id)[0]
  domain           = coalesce(var.settings.domain, "${var.environment.name_prefix}${var.environment.name}${module.naming.suffix}")
}

resource "azurerm_resource_group" "this" {
  count    = local.enabled ? 1 : 0
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

# ---------------------------------------------------------------- managed identities
# Cluster + operator identities are internal to the ARO platform (not workload identities), so
# they live with the cluster rather than in foundation-identity.
resource "azurerm_user_assigned_identity" "cluster" {
  count               = local.enabled ? 1 : 0
  name                = "${local.names.user_assigned_identity}-cluster"
  resource_group_name = azurerm_resource_group.this[0].name
  location            = local.location
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "operator" {
  for_each            = local.enabled ? local.operators : {}
  name                = "${local.names.user_assigned_identity}-${each.key}"
  resource_group_name = azurerm_resource_group.this[0].name
  location            = local.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "cluster_federation" {
  for_each           = local.enabled ? local.operators : {}
  scope              = azurerm_user_assigned_identity.operator[each.key].id
  role_definition_id = "${local.sub}/${local.federated_credential_role}"
  principal_id       = azurerm_user_assigned_identity.cluster[0].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "operator_network" {
  for_each           = local.operator_grants
  scope              = each.value.scope
  role_definition_id = "${local.sub}/${each.value.role}"
  principal_id       = azurerm_user_assigned_identity.operator[each.value.op].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "aro_rp" {
  count              = local.enabled ? 1 : 0
  scope              = local.vnet_id
  role_definition_id = "${local.sub}/${local.aro_rp_network_role}"
  principal_id       = var.settings.aro_rp_principal_id
  principal_type     = "ServicePrincipal"
}

data "azurerm_key_vault_secret" "pull_secret" {
  count        = local.enabled && local.pull_secret_name != null ? 1 : 0
  name         = local.pull_secret_name
  key_vault_id = var.foundation_identity.key_vault_id
}

# ---------------------------------------------------------------- cluster
resource "azurerm_redhat_openshift_cluster" "this" {
  count = local.enabled ? 1 : 0

  name                = local.names.aro
  resource_group_name = azurerm_resource_group.this[0].name
  location            = local.location
  tags                = local.tags

  cluster_profile {
    domain                      = local.domain
    version                     = var.settings.version
    managed_resource_group_name = "${local.names.resource_group}-managed"
    fips_enabled                = var.settings.fips_enabled
    pull_secret                 = try(data.azurerm_key_vault_secret.pull_secret[0].value, null)
  }

  network_profile {
    pod_cidr      = var.settings.pod_cidr
    service_cidr  = var.settings.service_cidr
    outbound_type = var.settings.outbound_type
  }

  main_profile {
    vm_size   = var.settings.master_vm_size
    subnet_id = local.master
  }

  worker_profile {
    vm_size      = var.settings.worker_vm_size
    disk_size_gb = var.settings.worker_disk_size_gb
    node_count   = var.settings.worker_count
    subnet_id    = local.worker
  }

  api_server_profile {
    visibility = var.settings.api_visibility
  }

  ingress_profile {
    visibility = var.settings.ingress_visibility
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster[0].id]
  }

  platform_workload_identity_profile {
    dynamic "platform_workload_identity" {
      for_each = azurerm_user_assigned_identity.operator
      content {
        name        = platform_workload_identity.key
        identity_id = platform_workload_identity.value.id
      }
    }
  }

  lifecycle {
    precondition {
      condition     = local.master != null && local.worker != null
      error_message = "foundation-network must publish the aro-master and aro-worker subnets."
    }
  }

  depends_on = [
    azurerm_role_assignment.cluster_federation,
    azurerm_role_assignment.operator_network,
    azurerm_role_assignment.aro_rp,
  ]
}
