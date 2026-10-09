resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  identities    = var.foundation_identity.identities
  control_plane = local.identities["aks-control-plane"]
  kubelet       = local.identities["aks-kubelet"]
  node_subnet   = local.subnets["aks-nodes"]

  # NAT gateway on the node subnet (foundation) => userAssignedNATGateway; hub firewall => UDR.
  outbound_type = var.settings.outbound_type != "auto" ? var.settings.outbound_type : (
    var.foundation_network.egress.type == "firewall" ? "userDefinedRouting" : "userAssignedNATGateway"
  )

  cluster_name        = local.names.aks
  node_resource_group = "${local.names.resource_group}-nodes"

  cluster_admins = merge(
    { for k in var.settings.cluster_admin_identities : k => local.identities[k].principal_id if contains(keys(local.identities), k) },
    { for i, p in var.settings.cluster_admin_principals : "principal-${i}" => p },
  )
  federated = { for k, v in var.settings.workload_identities : k => v if contains(keys(local.identities), k) }
}

# ---------------------------------------------------------------- platform identity RBAC
# The control-plane identity manages node-subnet IPs/route tables and assigns the kubelet identity.
resource "azurerm_role_assignment" "control_plane_network" {
  scope                = local.node_subnet.id
  role_definition_name = "Network Contributor"
  principal_id         = local.control_plane.principal_id
  principal_type       = "ServicePrincipal"
  description          = "AKS control plane: node subnet management"
}

resource "azurerm_role_assignment" "control_plane_kubelet_operator" {
  scope                = local.kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = local.control_plane.principal_id
  principal_type       = "ServicePrincipal"
  description          = "AKS control plane: assign kubelet identity to nodes"
}

# ---------------------------------------------------------------- cluster
resource "azurerm_kubernetes_cluster" "this" {
  #checkov:skip=CKV_AZURE_226:Dsv5 sizes have no local temp disk, so ephemeral OS disks are not possible at the default size.
  #checkov:skip=CKV_AZURE_117:Disk encryption sets (CMK) are not used for synthetic lab data; platform-managed keys apply.
  #checkov:skip=CKV_AZURE_232:System pool is tainted CriticalAddonsOnly whenever a user pool exists (variable-driven); single-pool lab clusters must schedule apps on it.
  #checkov:skip=CKV_AZURE_170:sku_tier is a setting (Free for the lab, Standard for enterprise).
  #checkov:skip=CKV_AZURE_227:host_encryption_enabled is a setting; it requires the EncryptionAtHost feature registration per subscription.
  #checkov:skip=CKV_AZURE_4:Cluster logs/metrics are owned by observability (Datadog agent + diagnostic settings in obs-diagnostics, ADR-0001 §3/§10).
  #checkov:skip=CKV_AZURE_116:Azure Policy add-on is a setting (azure_policy_enabled); off by default to keep the 1-2 node lab pool small.
  #checkov:skip=CKV_AZURE_115:private_cluster_enabled defaults to true (variable-driven; public API requires authorized_ip_ranges).
  name                = local.cluster_name
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  dns_prefix          = local.cluster_name
  node_resource_group = local.node_resource_group
  kubernetes_version  = var.settings.kubernetes_version
  sku_tier            = var.settings.sku_tier
  tags                = local.tags

  automatic_upgrade_channel = var.settings.automatic_upgrade_channel
  node_os_upgrade_channel   = var.settings.node_os_upgrade_channel

  # Identity & auth: Entra ID + Azure RBAC for Kubernetes; no local (certificate) accounts.
  local_account_disabled            = true
  role_based_access_control_enabled = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    tenant_id              = var.environment.tenant_id
    admin_group_object_ids = var.settings.admin_group_object_ids
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [local.control_plane.id]
  }
  kubelet_identity {
    user_assigned_identity_id = local.kubelet.id
    client_id                 = local.kubelet.client_id
    object_id                 = local.kubelet.principal_id
  }

  # API server exposure
  private_cluster_enabled             = var.settings.private_cluster_enabled
  private_dns_zone_id                 = var.settings.private_cluster_enabled ? var.settings.private_dns_zone_id : null
  private_cluster_public_fqdn_enabled = false
  run_command_enabled                 = var.settings.run_command_enabled
  dynamic "api_server_access_profile" {
    for_each = var.settings.private_cluster_enabled ? [] : [1]
    content {
      authorized_ip_ranges = var.settings.authorized_ip_ranges
    }
  }

  azure_policy_enabled  = var.settings.azure_policy_enabled
  image_cleaner_enabled = var.settings.image_cleaner_enabled
  # Weekly purge of unused images (AKS allows 24-2160 h).
  image_cleaner_interval_hours = var.settings.image_cleaner_enabled ? 168 : null

  default_node_pool {
    name                         = "system"
    vm_size                      = var.settings.system_pool.vm_size
    vnet_subnet_id               = local.node_subnet.id
    auto_scaling_enabled         = true
    min_count                    = var.settings.system_pool.min_count
    max_count                    = var.settings.system_pool.max_count
    os_sku                       = var.settings.system_pool.os_sku
    os_disk_type                 = "Managed"
    host_encryption_enabled      = var.settings.host_encryption_enabled
    max_pods                     = 110
    node_public_ip_enabled       = false
    only_critical_addons_enabled = var.settings.user_pool.enabled
    zones                        = var.settings.system_pool.zones
    temporary_name_for_rotation  = "systemtmp"
    tags                         = local.tags
    upgrade_settings {
      max_surge                     = "10%"
      drain_timeout_in_minutes      = 30
      node_soak_duration_in_minutes = 0
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = local.outbound_type
    pod_cidr            = var.settings.pod_cidr
    service_cidr        = var.settings.service_cidr
    dns_service_ip      = var.settings.dns_service_ip
  }

  node_provisioning_profile {
    mode = "Manual"
  }

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = var.settings.maintenance.duration
    day_of_week = var.settings.maintenance.day_of_week
    start_time  = var.settings.maintenance.start_time
    utc_offset  = var.settings.maintenance.utc_offset
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = var.settings.maintenance.duration
    day_of_week = var.settings.maintenance.day_of_week
    start_time  = var.settings.maintenance.start_time
    utc_offset  = var.settings.maintenance.utc_offset
  }

  dynamic "web_app_routing" {
    for_each = var.settings.app_routing.enabled ? [1] : []
    content {
      default_nginx_controller = var.settings.app_routing.default_controller
      dns_zone_ids             = var.settings.app_routing.dns_zone_ids
    }
  }

  # Secrets Store CSI driver (Azure Key Vault provider). OFF by default: lab secrets live in Delinea DSV and pods read
  # them directly with their workload identity (ADR-0001 section 14). Kept as an opt-in setting for adopters.
  dynamic "key_vault_secrets_provider" {
    for_each = var.settings.key_vault_secrets_provider_enabled ? [1] : []
    content {
      secret_rotation_enabled  = true
      secret_rotation_interval = "2m"
    }
  }

  dynamic "microsoft_defender" {
    for_each = var.settings.defender_enabled ? [1] : []
    content {
      log_analytics_workspace_id = var.platform_shared.log_analytics_workspace_id
    }
  }

  # Observability (obs-kubernetes) installs the Datadog Agent / Fluent Bit via Helm; nothing on
  # this resource is touched by it. Node count is owned by the cluster autoscaler.
  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]
  }

  depends_on = [
    azurerm_role_assignment.control_plane_network,
    azurerm_role_assignment.control_plane_kubelet_operator,
  ]
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  #checkov:skip=CKV_AZURE_227:host_encryption_enabled is a setting; requires the EncryptionAtHost feature registration.
  count = var.settings.user_pool.enabled ? 1 : 0

  name                    = "user"
  kubernetes_cluster_id   = azurerm_kubernetes_cluster.this.id
  vm_size                 = var.settings.user_pool.vm_size
  vnet_subnet_id          = local.node_subnet.id
  mode                    = "User"
  auto_scaling_enabled    = true
  min_count               = var.settings.user_pool.min_count
  max_count               = var.settings.user_pool.max_count
  os_sku                  = var.settings.user_pool.os_sku
  os_type                 = "Linux"
  max_pods                = 110
  node_public_ip_enabled  = false
  host_encryption_enabled = var.settings.host_encryption_enabled
  zones                   = var.settings.user_pool.zones
  tags                    = local.tags

  upgrade_settings {
    max_surge = "10%"
  }

  lifecycle {
    ignore_changes = [node_count]
  }
}

# ---------------------------------------------------------------- Kubernetes RBAC via Azure RBAC
resource "azurerm_role_assignment" "cluster_admin" {
  for_each = local.cluster_admins

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
  description          = "Cluster admin (deployments/observability Helm) for ${each.key}"
}

resource "azurerm_role_assignment" "cluster_user" {
  for_each = local.cluster_admins

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
  description          = "Fetch Entra kubeconfig (no local accounts) for ${each.key}"
}

# ---------------------------------------------------------------- workload identity federation
# The credential binds a foundation identity to THIS cluster's OIDC issuer, so it lives with the
# cluster (it is meaningless without the issuer and must be replaced when the cluster is).
resource "azurerm_federated_identity_credential" "workload" {
  for_each = local.federated

  name                      = "aks-${local.cluster_name}-${each.value.namespace}-${each.value.service_account}"
  user_assigned_identity_id = local.identities[each.key].id
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
  audience                  = ["api://AzureADTokenExchange"]
}
