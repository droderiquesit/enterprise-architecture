mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-tfstate-dev-sec" }
  }
  mock_resource "azurerm_storage_account" {
    defaults = {
      id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/ehsttfstatedevabcde"
      primary_blob_endpoint = "https://ehsttfstatedevabcde.blob.core.windows.net/"
    }
  }
  mock_resource "azurerm_storage_container" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st/blobServices/default/containers/c" }
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

mock_provider "azuread" {
  override_during = plan
  mock_resource "azuread_application" {
    defaults = {
      id        = "/applications/44444444-4444-4444-4444-444444444444"
      client_id = "55555555-5555-5555-5555-555555555555"
    }
  }
  mock_resource "azuread_service_principal" {
    defaults = { object_id = "66666666-6666-6666-6666-666666666666" }
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
}

run "state_storage_hardening" {
  command = plan

  assert {
    condition = (azurerm_storage_account.state.account_replication_type == "ZRS" && azurerm_storage_account.state.shared_access_key_enabled == false &&
      azurerm_storage_account.state.default_to_oauth_authentication == true && azurerm_storage_account.state.min_tls_version == "TLS1_2" &&
    azurerm_storage_account.state.infrastructure_encryption_enabled == true && azurerm_storage_account.state.allow_nested_items_to_be_public == false)
    error_message = "state account must be ZRS, keyless, OAuth-default, TLS1.2, infra-encrypted, no public blobs"
  }
  assert {
    condition = (azurerm_storage_account.state.blob_properties[0].versioning_enabled && azurerm_storage_account.state.blob_properties[0].change_feed_enabled &&
      azurerm_storage_account.state.blob_properties[0].delete_retention_policy[0].days == 30 &&
    azurerm_storage_account.state.blob_properties[0].container_delete_retention_policy[0].days == 30)
    error_message = "versioning, change feed, blob + container soft delete expected"
  }
  assert {
    condition     = azurerm_storage_account.state.network_rules[0].default_action == "Deny"
    error_message = "storage firewall must deny by default"
  }
  assert {
    condition     = toset(keys(azurerm_storage_container.this)) == toset(["tfstate", "contracts", "plans", "deployments", "evidence"])
    error_message = "ADR containers expected"
  }
  assert {
    condition     = azurerm_management_lock.state[0].lock_level == "CanNotDelete"
    error_message = "CanNotDelete lock expected"
  }
  assert {
    condition     = length(module.state_private_endpoint) == 0
    error_message = "private endpoint is phase 2"
  }
}

run "pipeline_identity_least_privilege" {
  command = plan

  assert {
    condition     = toset(keys(azurerm_user_assigned_identity.pipeline)) == toset(["plan", "apply", "validate"])
    error_message = "plan/apply/validate identities expected"
  }
  assert {
    condition     = length([for k, r in azurerm_role_assignment.pipeline : k if startswith(k, "validate/")]) == 0
    error_message = "validate identity must have no Azure role assignments"
  }
  assert {
    condition     = toset([for k, r in azurerm_role_assignment.pipeline : k if startswith(k, "plan/")]) == toset(["plan/subscription/Reader", "plan/tfstate/Storage Blob Data Contributor", "plan/contracts/Storage Blob Data Reader", "plan/deployments/Storage Blob Data Reader", "plan/plans/Storage Blob Data Contributor"])
    error_message = "plan identity: Reader + state lock + contracts read + plans write only"
  }
  assert {
    condition     = !contains(keys(azurerm_role_assignment.pipeline), "plan/subscription/Contributor") && !contains(keys(azurerm_role_assignment.pipeline), "plan/evidence/Storage Blob Data Contributor")
    error_message = "plan identity must not write Azure resources or evidence"
  }
  assert {
    condition     = strcontains(azurerm_role_assignment.pipeline["apply/subscription/Role Based Access Control Administrator"].condition, "GuidNotEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, f58310d9-a9f6-439a-9e8d-f62e7b41a168}") && azurerm_role_assignment.pipeline["apply/subscription/Role Based Access Control Administrator"].condition_version == "2.0"
    error_message = "apply RBAC Administrator must be constrained by an ABAC condition excluding privileged roles"
  }
  assert {
    condition     = !contains([for r in azurerm_role_assignment.pipeline : r.role_definition_name], "Owner") && !contains([for r in azurerm_role_assignment.pipeline : r.role_definition_name], "User Access Administrator")
    error_message = "no Owner / unconstrained UAA"
  }
  assert {
    condition     = length(azuread_application.datadog) == 0 && length(azurerm_role_assignment.datadog_monitoring_reader) == 0
    error_message = "Datadog app registration is optional and off by default"
  }
}

run "federated_credentials" {
  command = plan
  variables {
    settings = {
      federated_credentials = [{
        identity = "apply"
        name     = "ado-apply"
        issuer   = "https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0"
        subject  = "eid1/c/pub/t/abc/a/def/sc/77777777-7777-7777-7777-777777777777/88888888-8888-8888-8888-888888888888"
      }]
      azure_devops_legacy = {
        organization_name   = "contoso"
        organization_id     = "99999999-9999-9999-9999-999999999999"
        project             = "enterprise-hello"
        service_connections = { plan = "sc-eh-dev-plan" }
      }
    }
  }
  assert {
    condition     = azurerm_federated_identity_credential.pipeline["plan/ado-legacy-sc-eh-dev-plan"].issuer == "https://vstoken.dev.azure.com/99999999-9999-9999-9999-999999999999" && azurerm_federated_identity_credential.pipeline["plan/ado-legacy-sc-eh-dev-plan"].subject == "sc://contoso/enterprise-hello/sc-eh-dev-plan"
    error_message = "legacy Azure DevOps issuer/subject format"
  }
  assert {
    condition     = tolist(azurerm_federated_identity_credential.pipeline["apply/ado-apply"].audience) == tolist(["api://AzureADTokenExchange"])
    error_message = "federated credential audience"
  }
}

run "datadog_secretless_app_registration" {
  command = plan
  variables {
    settings = {
      datadog_integration = {
        enabled           = true
        federated_issuer  = "https://example-datadog-oidc-issuer.invalid/"
        federated_subject = "datadog-subject-from-integration-tile"
      }
    }
  }
  assert {
    condition     = length(azuread_application_federated_identity_credential.datadog) == 1 && azurerm_role_assignment.datadog_monitoring_reader["00000000-0000-0000-0000-000000000000"].role_definition_name == "Monitoring Reader"
    error_message = "secretless federated credential + Monitoring Reader expected"
  }
  assert {
    condition     = output.contract.datadog_integration.secretless_auth && output.contract.datadog_integration.client_id == "55555555-5555-5555-5555-555555555555"
    error_message = "contract exposes client id, never a secret"
  }
}

run "phase2_private_endpoint" {
  command = plan
  variables {
    settings = {
      public_network_access = "Disabled"
      private_endpoint = {
        subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke/subnets/private-endpoints"
        private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
      }
    }
  }
  assert {
    condition     = azurerm_storage_account.state.public_network_access == "Disabled" && length(module.state_private_endpoint) == 1
    error_message = "phase 2: public access off, private endpoint on"
  }
}

run "disabling_public_access_without_private_endpoint_rejected" {
  command = plan
  variables {
    settings = { public_network_access = "Disabled" }
  }
  expect_failures = [var.settings]
}
