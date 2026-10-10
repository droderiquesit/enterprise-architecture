mock_provider "azurerm" {
  override_during = plan

  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-identity-dev-sec" }
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
  secrets = {
    provider      = "delinea-dsv"
    tenant        = "example-lab"
    tld           = "com"
    auth_provider = "azure-eh"
  }
}

run "defaults" {
  command = plan

  assert {
    condition = alltrue([for k in [
      "hello-bff", "hello-orders-api", "hello-inventory-api", "hello-catalog-api", "hello-dbadapter", "hello-worker",
      "hello-durable", "hello-functions", "hello-jobs", "hello-partner-sim", "hello-traffic", "hello-frontend",
      "obs-collector", "obs-dbm", "obs-host-agent", "aks-control-plane", "aks-kubelet", "deploy-agent"
    ] : contains(keys(azurerm_user_assigned_identity.this), k)])
    error_message = "all catalogue identities must exist"
  }
  assert {
    condition     = output.contract.secrets.provider == "delinea-dsv" && output.contract.secrets.base_url == "https://example-lab.secretsvaultcloud.com/v1" && output.contract.secrets.base_path == "eh/dev" && output.contract.secrets.auth_provider == "azure-eh"
    error_message = "DSV connection block expected"
  }
  assert {
    condition     = output.contract.secrets.refs["datadog-api-key"] == "dsv://eh/dev/datadog-api-key#value" && output.contract.secrets.refs["eventhub-fluentbit-listen"] == "dsv://eh/dev/eventhub-fluentbit-listen#value"
    error_message = "dsv:// references expected"
  }
  assert {
    condition     = contains(keys(output.contract.secrets.refs), "dbm-mysql-password") && contains(keys(output.contract.secrets.refs), "dbm-sqlvm-password") && !contains(keys(output.contract.secrets.refs), "dbm-postgres-password")
    error_message = "DBM password refs only for SQL-auth engines"
  }
  assert {
    condition     = alltrue([for k, v in output.contract.secrets.refs : startswith(v, "dsv://eh/dev/${k}#")])
    error_message = "every ref is under the env base path"
  }
  assert {
    condition     = contains(output.contract.identities["obs-collector"].secrets, "fluentbit-shared-key") && contains(output.contract.identities["obs-collector"].secrets, "eventhub-fluentbit-listen") && !contains(output.contract.identities["obs-collector"].secrets, "fault-token")
    error_message = "collector reads API key, forward shared key and the Event Hubs listen string, not the fault token"
  }
  assert {
    condition     = contains(output.contract.identities["deploy-agent"].secrets, "datadog-app-key") && !contains(output.contract.identities["hello-bff"].secrets, "datadog-app-key")
    error_message = "datadog-app-key is pipeline-only"
  }
  assert {
    condition     = length(output.contract.identities["aks-kubelet"].secrets) == 0 && jsonencode(output.contract.identities["obs-host-agent"].secrets) == jsonencode(["datadog-api-key"]) && length(output.contract.identities["hello-frontend"].secrets) == 0
    error_message = "identities without runtime secrets"
  }
  assert {
    condition     = alltrue(flatten([for k, v in output.contract.identities : [for s in v.secrets : contains(keys(output.contract.secrets.refs), s)]]))
    error_message = "every identity secret has a reference"
  }
  assert {
    condition     = alltrue([for k, v in output.contract.identities : can(regex("^/subscriptions/[^/]+/", v.id))])
    error_message = "identity ids must be ARM ids"
  }
  assert {
    condition     = length(azurerm_role_assignment.package_readers) == 0
    error_message = "no package readers without a packages container"
  }
}

run "extra_identity_and_engines" {
  command = plan
  variables {
    settings = {
      extra_identities       = { "hello-extra" = "extra test workload" }
      extra_identity_secrets = { "hello-extra" = ["fault-token"] }
      dbm_sql_auth_engines   = ["postgres"]
    }
  }
  assert {
    condition     = length(output.contract.identities["hello-extra"].secrets) == 1 && contains(output.contract.identities["hello-extra"].secrets, "fault-token")
    error_message = "extra identity secrets"
  }
  assert {
    condition     = contains(keys(output.contract.secrets.refs), "dbm-postgres-password") && !contains(keys(output.contract.secrets.refs), "dbm-mysql-password")
    error_message = "DBM refs follow dbm_sql_auth_engines"
  }
}

run "uncatalogued_secret_rejected" {
  command = plan
  variables {
    settings = { extra_identity_secrets = { "hello-bff" = ["not-in-catalogue"] } }
  }
  expect_failures = [azurerm_resource_group.identity]
}

run "wrong_tld_rejected" {
  command = plan
  variables {
    secrets = { tenant = "example-lab", tld = "org", auth_provider = "azure-eh" }
  }
  expect_failures = [var.secrets]
}
