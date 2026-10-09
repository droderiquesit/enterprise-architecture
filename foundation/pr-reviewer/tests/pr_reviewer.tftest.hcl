mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-prr-dev-sec" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-prr-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-pr-reviewer-dev"
      client_id    = "22222222-2222-2222-2222-222222222222"
      principal_id = "11111111-1111-1111-1111-111111111111"
    }
  }
  mock_resource "azurerm_storage_account" {
    defaults = {
      id                     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-prr-dev-sec/providers/Microsoft.Storage/storageAccounts/ehstprrdev12345"
      primary_blob_endpoint  = "https://ehstprrdev12345.blob.core.windows.net/"
      primary_queue_endpoint = "https://ehstprrdev12345.queue.core.windows.net/"
    }
  }
  mock_resource "azurerm_service_plan" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-prr-dev-sec/providers/Microsoft.Web/serverFarms/plan" }
  }
  mock_resource "azurerm_function_app_flex_consumption" {
    defaults = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-prr-dev-sec/providers/Microsoft.Web/sites/eh-func-pr-reviewer-dev"
      default_hostname = "eh-func-pr-reviewer-dev-12345.azurewebsites.net"
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
  foundation_identity = {
    secrets = {
      tenant        = "example"
      tld           = "eu"
      base_url      = "https://example.secretsvaultcloud.eu/v1"
      base_path     = "eh/dev"
      auth_provider = "azure-eh"
    }
  }
  settings = {
    ado = {
      project_id     = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      repository_ids = ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]
    }
  }
}

run "public_default" {
  command = plan

  assert {
    condition     = azurerm_function_app_flex_consumption.this.runtime_name == "python" && azurerm_function_app_flex_consumption.this.runtime_version == "3.13"
    error_message = "Python 3.13 on Flex Consumption expected"
  }
  assert {
    condition     = azurerm_service_plan.this.sku_name == "FC1"
    error_message = "Flex Consumption plan (FC1) expected"
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.storage_authentication_type == "UserAssignedIdentity" && azurerm_storage_account.this.shared_access_key_enabled == false
    error_message = "identity-based storage only (no shared keys)"
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.app_settings["WEBHOOK_SECRET"] == "dsv://eh/dev/pr-reviewer-webhook-secret#value"
    error_message = "webhook secret must be a DSV reference"
  }
  assert {
    condition     = !contains(keys(azurerm_function_app_flex_consumption.this.app_settings), "ANTHROPIC_API_KEY")
    error_message = "AI key only when ai_enabled"
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.app_settings["ReviewQueue__credential"] == "managedidentity" && azurerm_function_app_flex_consumption.this.app_settings["AzureWebJobsStorage__credential"] == "managedidentity"
    error_message = "identity-based host and queue connections expected"
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.site_config[0].ip_restriction_default_action == "Deny" && azurerm_function_app_flex_consumption.this.site_config[0].ip_restriction[0].service_tag == "AzureDevOps"
    error_message = "inbound restricted to the AzureDevOps service tag"
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.https_only && azurerm_function_app_flex_consumption.this.webdeploy_publish_basic_authentication_enabled == false
    error_message = "HTTPS only, no basic publishing credentials"
  }
  assert {
    condition     = length(azurerm_role_assignment.storage) == 3 && alltrue([for r in azurerm_role_assignment.storage : r.principal_id == "11111111-1111-1111-1111-111111111111"])
    error_message = "storage roles for the pr-reviewer identity only"
  }
  assert {
    condition     = length(module.storage_pe) == 0 && azurerm_function_app_flex_consumption.this.virtual_network_subnet_id == null
    error_message = "public mode has no VNet integration / private endpoints"
  }
  assert {
    condition     = output.contract.webhook_url == "https://eh-func-pr-reviewer-dev-12345.azurewebsites.net/api/ado-webhook" && output.contract.status_context == "eh-review/policy"
    error_message = "contract webhook url"
  }
  assert {
    condition     = output.contract.identity_client_id == "22222222-2222-2222-2222-222222222222" && can(regex("^dsv://", output.contract.webhook_secret_ref))
    error_message = "contract identity + secret reference (no secret values)"
  }
  assert {
    condition     = output.dsv_desired_state.policy.permissions[0].resources == ["secrets:eh:dev:pr-reviewer-webhook-secret"] && output.dsv_desired_state.marker != "managed-by:foundation-secrets"
    error_message = "DSV permission: read on exactly the reviewer's secrets, own marker"
  }
  assert {
    condition     = output.dsv_desired_state.users["eh-dev-pr-reviewer"].external_id == azurerm_user_assigned_identity.pr_reviewer.id
    error_message = "DSV user maps to the identity resource id"
  }
}

run "vnet_with_ai" {
  command = plan

  variables {
    foundation_network = {
      subnets = {
        "flex-integration"  = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke/subnets/flex-integration" }
        "private-endpoints" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/spoke/subnets/private-endpoints" }
      }
      private_dns_zones = {
        blob  = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net" }
        queue = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.queue.core.windows.net" }
      }
      egress = { public_ips = ["20.0.0.10"] }
    }
    settings = {
      network_mode = "vnet"
      ai_enabled   = true
      ado = {
        project_id     = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        repository_ids = ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]
      }
    }
  }

  assert {
    condition     = azurerm_storage_account.this.public_network_access == "Disabled" && length(module.storage_pe) == 3
    error_message = "vnet mode: private storage with blob/queue/table endpoints"
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.public_network_access_enabled == true
    error_message = "the webhook endpoint stays reachable for Azure DevOps service hooks"
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.app_settings["ANTHROPIC_API_KEY"] == "dsv://eh/dev/anthropic-api-key#value"
    error_message = "AI key is a DSV reference"
  }
  assert {
    condition     = length(output.dsv_desired_state.policy.permissions[0].resources) == 2
    error_message = "reviewer reads webhook secret + anthropic key"
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.site_config[0].ip_restriction[1].ip_address == "20.0.0.10"
    error_message = "deploy agent egress IP allowed (smoke tests)"
  }
}

run "vnet_requires_network_contract" {
  command = plan
  variables {
    settings = {
      network_mode = "vnet"
      ado = {
        project_id     = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        repository_ids = ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]
      }
    }
  }
  expect_failures = [azurerm_function_app_flex_consumption.this]
}

run "rejects_bad_settings" {
  command = plan
  variables {
    settings = {
      network_mode = "internet"
    }
  }
  expect_failures = [var.settings]
}
