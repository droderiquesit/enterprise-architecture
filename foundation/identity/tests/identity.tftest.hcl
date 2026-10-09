mock_provider "azurerm" {
  override_during = plan

  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-identity-dev-sec" }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv"
      vault_uri = "https://eh-kv-identi-dev-abcde.vault.azure.net/"
    }
  }
  mock_resource "azurerm_private_endpoint" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateEndpoints/pep-kv" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id"
      principal_id = "11111111-1111-1111-1111-111111111111"
      client_id    = "22222222-2222-2222-2222-222222222222"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
    }
  }
}

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
    subnets = {
      "private-endpoints" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/v/subnets/private-endpoints" }
    }
    private_dns_zones = {
      vault = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net" }
    }
  }
}

run "defaults" {
  command = plan

  assert {
    condition     = azurerm_key_vault.this.public_network_access_enabled == false && azurerm_key_vault.this.network_acls[0].default_action == "Deny" && azurerm_key_vault.this.network_acls[0].bypass == "AzureServices"
    error_message = "Key Vault must have public access disabled and a deny-by-default firewall"
  }
  assert {
    condition     = azurerm_key_vault.this.rbac_authorization_enabled && azurerm_key_vault.this.purge_protection_enabled && azurerm_key_vault.this.soft_delete_retention_days == 7
    error_message = "RBAC authorization, purge protection and 7-day soft delete expected"
  }
  assert {
    condition     = module.key_vault_private_endpoint.id != null
    error_message = "Key Vault private endpoint expected"
  }
  assert {
    condition = alltrue([for k in [
      "hello-bff", "hello-orders-api", "hello-inventory-api", "hello-catalog-api", "hello-dbadapter", "hello-worker",
      "hello-durable", "hello-functions", "hello-jobs", "hello-partner-sim", "hello-traffic", "hello-frontend",
      "obs-collector", "obs-dbm", "aks-control-plane", "aks-kubelet", "deploy-agent"
    ] : contains(keys(azurerm_user_assigned_identity.this), k)])
    error_message = "all catalogue identities must exist"
  }
  assert {
    condition     = contains(keys(azurerm_role_assignment.workload_secrets_user), "obs-collector") && contains(keys(azurerm_role_assignment.workload_secrets_user), "hello-orders-api") && !contains(keys(azurerm_role_assignment.workload_secrets_user), "aks-kubelet") && !contains(keys(azurerm_role_assignment.workload_secrets_user), "deploy-agent")
    error_message = "only identities that need secrets get Key Vault Secrets User"
  }
  assert {
    condition     = alltrue([for r in azurerm_role_assignment.workload_secrets_user : r.role_definition_name == "Key Vault Secrets User"])
    error_message = "workloads only get Secrets User"
  }
  assert {
    condition     = output.contract.secret_ids["datadog-api-key"] == "https://eh-kv-identi-dev-abcde.vault.azure.net/secrets/datadog-api-key" && contains(keys(output.contract.secret_ids), "dbm-mysql-password") && contains(keys(output.contract.secret_ids), "fault-token") && contains(keys(output.contract.secret_ids), "datadog-client-token")
    error_message = "versionless secret IDs expected"
  }
  assert {
    condition     = alltrue([for k, v in output.contract.identities : can(regex("^/subscriptions/[^/]+/", v.id))])
    error_message = "identity ids must be ARM ids"
  }
}

run "secret_scoped_assignments" {
  command = plan
  variables {
    settings = { secret_scoped_assignments = true }
  }
  assert {
    condition     = azurerm_role_assignment.workload_secrets_user["obs-dbm/dbm-mysql-password"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv/secrets/dbm-mysql-password"
    error_message = "secret-scoped assignment expected"
  }
  assert {
    condition     = !contains(keys(azurerm_role_assignment.workload_secrets_user), "obs-collector/fault-token")
    error_message = "collector must not read fault-token"
  }
}
