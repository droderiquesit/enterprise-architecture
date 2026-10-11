locals {
  enabled = var.settings.enabled
  nt      = var.settings.node_type
  sfrp    = var.settings.sf_resource_provider_principal_id
  # BYO VNet: explicit settings.byo_vnet, else (backward compatible) whenever the SF resource provider principal is set
  byovnet = coalesce(var.settings.byo_vnet, local.sfrp != null)

  # Datadog Agent enrolment (ADR-0001 §3 rule 3): node types change only through the node type API, so the obs-hosts
  # policy cannot enrol them. This root attaches the DSV-reader identity (vmManagedIdentity) and tags the node type;
  # obs-hosts owns properties.vmApplications, which this root never sends (ignore_body_changes).
  dd_enabled     = local.enabled && var.settings.datadog.enabled
  dd_identity_id = local.dd_enabled ? try(var.foundation_identity.identities[var.settings.datadog.identity_key].id, null) : null
  dd_tags        = local.dd_enabled ? { (var.settings.datadog.tag_name) = "true" } : {}

  ports = {
    app       = split("-", local.nt.application_ports)
    ephemeral = split("-", local.nt.ephemeral_ports)
  }
}

resource "azurerm_resource_group" "this" {
  count    = local.enabled ? 1 : 0
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

resource "random_password" "admin" {
  count            = local.enabled ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_role_assignment" "sfrp_subnet" {
  count                = local.enabled && local.byovnet ? 1 : 0
  scope                = local.subnets["sfmc"].id
  role_definition_name = "Network Contributor"
  principal_id         = local.sfrp
  description          = "Service Fabric Resource Provider: BYO VNet for the managed cluster"
}

# The Service Fabric RP needs Managed Identity Operator on an identity before a node type can reference it.
resource "azurerm_role_assignment" "sfrp_dd_identity" {
  count                = local.dd_enabled ? 1 : 0
  scope                = local.dd_identity_id
  role_definition_name = "Managed Identity Operator"
  principal_id         = local.sfrp
  description          = "Service Fabric Resource Provider assigns the obs-host-agent DSV-reader identity to the node type VMSS"

  lifecycle {
    precondition {
      condition     = local.dd_identity_id != null
      error_message = "settings.datadog: foundation-identity has no ${var.settings.datadog.identity_key} identity (the DSV reader of the host Agents)."
    }
  }
}

# Provider gap (catalog/provider-gaps.yaml): azurerm_service_fabric_managed_cluster lacks node type
# vmManagedIdentity/vmApplications and re-PUTs node types without them, so cluster and node type are azapi resources.
resource "azapi_resource" "cluster" {
  count     = local.enabled ? 1 : 0
  type      = "Microsoft.ServiceFabric/managedClusters@2026-02-01"
  name      = local.names.service_fabric
  parent_id = azurerm_resource_group.this[0].id
  location  = local.location
  tags      = local.tags

  body = {
    sku = { name = var.settings.sku }
    properties = {
      dnsName                   = local.names.service_fabric
      adminUserName             = "sfadmin"
      clientConnectionPort      = 19000
      httpGatewayConnectionPort = 19080
      clusterUpgradeCadence     = "Wave0"
      loadBalancingRules = [{
        frontendPort     = var.settings.app_port
        backendPort      = var.settings.app_port
        protocol         = "tcp"
        probeProtocol    = "http"
        probeRequestPath = "/healthz"
      }]
      clients = var.settings.client_certificate_thumbprint == null ? [] : [{
        isAdmin    = true
        thumbprint = var.settings.client_certificate_thumbprint
        commonName = var.settings.client_certificate_common_name
      }]
      subnetId = local.byovnet ? local.subnets["sfmc"].id : null
      azureActiveDirectory = var.settings.entra_cluster_application_id == null ? null : {
        tenantId           = var.environment.tenant_id
        clusterApplication = var.settings.entra_cluster_application_id
        clientApplication  = var.settings.entra_client_application_id
      }
    }
  }
  ignore_null_property = true # optional properties above are null when unset (not sent)
  # write-only: the node RDP password is not stored in this resource's state (random_password still holds it)
  sensitive_body         = { properties = { adminPassword = random_password.admin[0].result } }
  sensitive_body_version = { "properties.adminPassword" = "1" }

  response_export_values = ["properties.fqdn", "properties.clusterId"]
  depends_on             = [azurerm_role_assignment.sfrp_subnet]
}

resource "azapi_resource" "node_type" {
  count     = local.enabled ? 1 : 0
  type      = "Microsoft.ServiceFabric/managedClusters/nodeTypes@2026-02-01"
  name      = local.nt.name
  parent_id = azapi_resource.cluster[0].id
  tags      = merge(local.tags, local.nt.tags, local.dd_tags)

  body = {
    properties = {
      isPrimary           = true
      vmSize              = local.nt.vm_size
      vmInstanceCount     = local.nt.instance_count
      vmImagePublisher    = "MicrosoftWindowsServer"
      vmImageOffer        = "WindowsServer"
      vmImageSku          = local.nt.image_sku
      vmImageVersion      = "latest"
      dataDiskSizeGB      = local.nt.data_disk_size_gb
      dataDiskType        = local.nt.data_disk_type
      applicationPorts    = { startPort = tonumber(local.ports.app[0]), endPort = tonumber(local.ports.app[1]) }
      ephemeralPorts      = { startPort = tonumber(local.ports.ephemeral[0]), endPort = tonumber(local.ports.ephemeral[1]) }
      placementProperties = local.nt.placement_properties
      vmManagedIdentity   = local.dd_identity_id == null ? null : { userAssignedIdentities = [local.dd_identity_id] }
    }
  }
  ignore_null_property = true # vmManagedIdentity is not sent without the Datadog identity
  # properties.vmApplications is owned by obs-hosts (Datadog Agent VM Application): on update azapi GETs the node type
  # and sends the remote value at this path, so a platform apply never removes (= uninstalls) the Agent.
  ignore_body_changes = ["properties.vmApplications"]

  depends_on = [azurerm_role_assignment.sfrp_dd_identity]
}
