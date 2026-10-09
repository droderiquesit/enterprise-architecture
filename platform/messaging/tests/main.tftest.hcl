mock_provider "azurerm" {
  override_during = plan

  mock_resource "azurerm_servicebus_namespace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-msg-dev-sec/providers/Microsoft.ServiceBus/namespaces/eh-sbns-msg-dev-sec-abcde"
    }
  }
  mock_resource "azurerm_servicebus_topic" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-msg-dev-sec/providers/Microsoft.ServiceBus/namespaces/eh-sbns-msg-dev-sec-abcde/topics/order-events"
    }
  }
  mock_resource "azurerm_servicebus_subscription" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-msg-dev-sec/providers/Microsoft.ServiceBus/namespaces/eh-sbns-msg-dev-sec-abcde/topics/order-events/subscriptions/sub"
    }
  }
  mock_resource "azurerm_servicebus_queue" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-msg-dev-sec/providers/Microsoft.ServiceBus/namespaces/eh-sbns-msg-dev-sec-abcde/queues/batch-items"
    }
  }
}

# BEGIN FIXTURE (generated): upstream contract shapes with valid Azure IDs.
variables {
  environment = {
    name            = "dev"
    location        = "swedencentral"
    subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id       = "00000000-0000-0000-0000-000000000000"
    name_prefix     = "eh"
    owner           = "platform-team@example.com"
    team            = "platform-engineering"
    cost_center     = "lab-0001"
    expires_on      = "2026-12-31"
    tags            = {}
  }
  foundation_network = {
    resource_group_name = "rg-net"
    location            = "swedencentral"
    subnets = {
      "compute" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-compute", name = "snet-compute", address_prefix = "10.41.0.0/24" }
      "aks-nodes" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aks-nodes", name = "snet-aks-nodes", address_prefix = "10.41.1.0/24" }
      "aca-infra" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca-infra", name = "snet-aca-infra", address_prefix = "10.41.2.0/24" }
      "appsvc-integration" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-appsvc-integration", name = "snet-appsvc-integration", address_prefix = "10.41.3.0/24" }
      "flex-integration" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-flex-integration", name = "snet-flex-integration", address_prefix = "10.41.4.0/24" }
      "aci" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aci", name = "snet-aci", address_prefix = "10.41.5.0/24" }
      "private-endpoints" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-private-endpoints", name = "snet-private-endpoints", address_prefix = "10.41.6.0/24" }
      "postgres" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-postgres", name = "snet-postgres", address_prefix = "10.41.7.0/24" }
      "mysql" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-mysql", name = "snet-mysql", address_prefix = "10.41.8.0/24" }
      "sqlmi" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-sqlmi", name = "snet-sqlmi", address_prefix = "10.41.9.0/24" }
      "cassandra-mi" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-cassandra-mi", name = "snet-cassandra-mi", address_prefix = "10.41.10.0/24" }
      "batch" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-batch", name = "snet-batch", address_prefix = "10.41.11.0/24" }
      "deploy-agents" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-deploy-agents", name = "snet-deploy-agents", address_prefix = "10.41.12.0/24" }
      "observability" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-observability", name = "snet-observability", address_prefix = "10.41.13.0/24" }
      "sfmc" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-sfmc", name = "snet-sfmc", address_prefix = "10.41.14.0/24" }
      "aro-master" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aro-master", name = "snet-aro-master", address_prefix = "10.41.15.0/24" }
      "aro-worker" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aro-worker", name = "snet-aro-worker", address_prefix = "10.41.16.0/24" }
    }
    private_dns_zones = {
      blob = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net", name = "privatelink.blob.core.windows.net" }
      file = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net", name = "privatelink.file.core.windows.net" }
      queue = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.queue.core.windows.net", name = "privatelink.queue.core.windows.net" }
      table = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.table.core.windows.net", name = "privatelink.table.core.windows.net" }
      dfs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.dfs.core.windows.net", name = "privatelink.dfs.core.windows.net" }
      vault = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net", name = "privatelink.vaultcore.azure.net" }
      servicebus = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net", name = "privatelink.servicebus.windows.net" }
      acr = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io", name = "privatelink.azurecr.io" }
      sites = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net", name = "privatelink.azurewebsites.net" }
      aca = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.swedencentral.azurecontainerapps.io", name = "privatelink.swedencentral.azurecontainerapps.io" }
    }
    egress = { type = "nat-gateway", public_ips = ["20.0.0.1"] }
  }
  foundation_identity = {
    identities = {
      "hello-bff" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-bff", principal_id = "00000000-0000-0000-0001-000000000000", client_id = "00000000-0000-0000-0002-000000000000", name = "id-hello-bff" }
      "hello-orders-api" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-orders-api", principal_id = "00000000-0000-0000-0001-000000000001", client_id = "00000000-0000-0000-0002-000000000001", name = "id-hello-orders-api" }
      "hello-inventory-api" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-inventory-api", principal_id = "00000000-0000-0000-0001-000000000002", client_id = "00000000-0000-0000-0002-000000000002", name = "id-hello-inventory-api" }
      "hello-catalog-api" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-catalog-api", principal_id = "00000000-0000-0000-0001-000000000003", client_id = "00000000-0000-0000-0002-000000000003", name = "id-hello-catalog-api" }
      "hello-dbadapter" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-dbadapter", principal_id = "00000000-0000-0000-0001-000000000004", client_id = "00000000-0000-0000-0002-000000000004", name = "id-hello-dbadapter" }
      "hello-worker" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-worker", principal_id = "00000000-0000-0000-0001-000000000005", client_id = "00000000-0000-0000-0002-000000000005", name = "id-hello-worker" }
      "hello-durable" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-durable", principal_id = "00000000-0000-0000-0001-000000000006", client_id = "00000000-0000-0000-0002-000000000006", name = "id-hello-durable" }
      "hello-functions" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-functions", principal_id = "00000000-0000-0000-0001-000000000007", client_id = "00000000-0000-0000-0002-000000000007", name = "id-hello-functions" }
      "hello-jobs" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-jobs", principal_id = "00000000-0000-0000-0001-000000000008", client_id = "00000000-0000-0000-0002-000000000008", name = "id-hello-jobs" }
      "hello-partner-sim" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-partner-sim", principal_id = "00000000-0000-0000-0001-000000000009", client_id = "00000000-0000-0000-0002-000000000009", name = "id-hello-partner-sim" }
      "hello-traffic" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-traffic", principal_id = "00000000-0000-0000-0001-000000000010", client_id = "00000000-0000-0000-0002-000000000010", name = "id-hello-traffic" }
      "hello-frontend" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-frontend", principal_id = "00000000-0000-0000-0001-000000000011", client_id = "00000000-0000-0000-0002-000000000011", name = "id-hello-frontend" }
      "obs-collector" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-collector", principal_id = "00000000-0000-0000-0001-000000000012", client_id = "00000000-0000-0000-0002-000000000012", name = "id-obs-collector" }
      "obs-dbm" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-dbm", principal_id = "00000000-0000-0000-0001-000000000013", client_id = "00000000-0000-0000-0002-000000000013", name = "id-obs-dbm" }
      "aks-control-plane" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-control-plane", principal_id = "00000000-0000-0000-0001-000000000014", client_id = "00000000-0000-0000-0002-000000000014", name = "id-aks-control-plane" }
      "aks-kubelet" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-kubelet", principal_id = "00000000-0000-0000-0001-000000000015", client_id = "00000000-0000-0000-0002-000000000015", name = "id-aks-kubelet" }
      "deploy-agent" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-deploy-agent", principal_id = "00000000-0000-0000-0001-000000000016", client_id = "00000000-0000-0000-0002-000000000016", name = "id-deploy-agent" }
    }
  }
}
# END FIXTURE

run "standard_defaults" {
  command = plan

  assert {
    condition     = azurerm_servicebus_namespace.this.sku == "Standard" && azurerm_servicebus_namespace.this.local_auth_enabled == false
    error_message = "Standard namespace with local (SAS) auth disabled by default."
  }
  assert {
    condition     = azurerm_servicebus_namespace.this.minimum_tls_version == "1.2"
    error_message = "TLS 1.2 minimum."
  }
  assert {
    condition     = length(module.private_endpoint) == 0
    error_message = "Standard cannot use Private Link: no private endpoint."
  }
  assert {
    condition     = toset(keys(azurerm_servicebus_subscription.this)) == toset(["fulfillment", "notifications", "audit"])
    error_message = "order-events must have fulfillment, notifications and audit subscriptions."
  }
  assert {
    condition     = alltrue([for s in azurerm_servicebus_subscription.this : s.dead_lettering_on_message_expiration && s.max_delivery_count == 10])
    error_message = "subscriptions dead-letter on expiry with max delivery 10."
  }
  assert {
    condition     = azurerm_servicebus_queue.batch_items.name == "batch-items" && azurerm_servicebus_queue.batch_items.max_delivery_count == 5
    error_message = "batch-items queue."
  }
  assert {
    condition     = azurerm_role_assignment.data["topic-send-hello-orders-api"].role_definition_name == "Azure Service Bus Data Sender"
    error_message = "orders-api sends to order-events."
  }
  assert {
    condition     = azurerm_role_assignment.data["sub-recv-fulfillment-hello-durable"].role_definition_name == "Azure Service Bus Data Receiver"
    error_message = "durable receives fulfillment."
  }
  assert {
    condition     = alltrue([for k in ["sub-recv-notifications-hello-worker", "sub-recv-audit-hello-functions", "queue-recv-hello-jobs", "queue-send-hello-durable", "queue-scaler-hello-jobs"] : contains(keys(azurerm_role_assignment.data), k)])
    error_message = "consumer grants missing."
  }
  assert {
    condition     = tolist(output.contract.skipped_grants) == tolist(["queue-send-hello-logicapps"])
    error_message = "logic app identity absent from contract must be reported as skipped."
  }
  assert {
    condition     = output.contract.fqdn == "${azurerm_servicebus_namespace.this.name}.servicebus.windows.net" && can(regex("^/subscriptions/", output.contract.namespace_id))
    error_message = "contract exposes fqdn and namespace id."
  }
}

run "premium_private" {
  command = plan
  variables {
    settings = { sku = "Premium" }
  }
  assert {
    condition     = azurerm_servicebus_namespace.this.public_network_access_enabled == false && length(module.private_endpoint) == 1
    error_message = "Premium is private (PE, public access disabled) by default."
  }
  assert {
    condition     = azurerm_servicebus_namespace.this.network_rule_set[0].default_action == "Deny"
    error_message = "Premium network rules deny by default."
  }
}

run "standard_ip_firewall" {
  command = plan
  variables {
    settings = { allowed_ip_ranges = ["203.0.113.0/24"], allow_egress_ips = true }
  }
  assert {
    condition     = toset(azurerm_servicebus_namespace.this.network_rule_set[0].ip_rules) == toset(["203.0.113.0/24", "20.0.0.1"])
    error_message = "IP firewall includes configured ranges and egress IPs."
  }
}
