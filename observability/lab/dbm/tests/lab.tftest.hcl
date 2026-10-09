mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_container_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obs-dbm-dev-sec/providers/Microsoft.ContainerInstance/containerGroups/eh-ci-obs-dbm-dev-sec" }
  }
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obs-dbm-dev-sec" }
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
  obs_telemetry_transport = { datadog_site = "datadoghq.com" }
  foundation_network = {
    subnets = {
      observability = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/observability", name = "observability" }
      aci           = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/aci", name = "aci" }
    }
  }
  foundation_identity = {
    key_vault_uri = "https://eh-kv-ident-dev-abcde.vault.azure.net/"
    identities = {
      "obs-dbm" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-obs-dbm-dev-sec", client_id = "33333333-3333-3333-3333-333333333333", name = "eh-id-obs-dbm-dev-sec" }
    }
  }
  platform_db_postgresql = {
    dbm = { supported = true, engine = "postgres", deployment_type = "flexible_server", auth_mode = "entra-managed-identity", identity_name = "obs-dbm", identity_client_id = "33333333-3333-3333-3333-333333333333", host = "eh-psql-dev.postgres.database.azure.com", port = 5432, databases = ["catalog"] }
  }
  platform_db_mysql = {
    dbm = { supported = true, engine = "mysql", deployment_type = "flexible_server", auth_mode = "native-password", host = "eh-mysql-dev.mysql.database.azure.com", port = 3306, databases = ["adapter"], password_secret_id = "https://eh-kv-ident-dev-abcde.vault.azure.net/secrets/dbm-mysql-password" }
  }
  platform_db_sql = {
    dbm = { supported = true, engine = "sqlserver", deployment_type = "sql_database", auth_mode = "entra-managed-identity", identity_name = "obs-dbm", host = "eh-sql-dev.database.windows.net", port = 1433, databases = ["orders", "fulfillment"] }
  }
  platform_db_sqlvm = {
    dbm = { supported = true, engine = "sqlserver", deployment_type = "self_hosted_azure_vm", auth_mode = "sql-login", host = "10.41.1.10", port = 1433, databases = ["adapter"], password_secret_id = "https://eh-kv-ident-dev-abcde.vault.azure.net/secrets/dbm-sqlvm-password" }
  }
}

run "lab_dbm_from_contracts" {
  command = plan
  assert {
    condition     = output.configured["postgresql"].auth == "managed_identity" && output.configured["mysql"].password_source == "key_vault"
    error_message = "Entra for PostgreSQL, Key Vault password for MySQL."
  }
  assert {
    condition     = contains(keys(output.configured), "sql-orders") && contains(keys(output.configured), "sql-fulfillment") && output.configured["sqlvm"].deployment_type == "virtual_machine"
    error_message = "One instance per Azure SQL database; VM deployment type mapped."
  }
  assert {
    condition     = output.agent_container_group_id != null && var.settings.subnet_key == "aci"
    error_message = "ACI Agent in the ContainerInstance-delegated aci subnet."
  }
}

run "unsupported_and_absent_contracts" {
  command = plan
  variables {
    platform_db_postgresql = { dbm = { supported = false, reason = "elastic cluster" } }
    platform_db_mysql      = null
    platform_db_sql        = null
    platform_db_sqlvm      = null
  }
  assert {
    condition     = length(output.configured) == 0 && output.agent_container_group_id == null
    error_message = "No supported database -> nothing deployed."
  }
}

run "cluster_checks_hosting" {
  command = plan
  variables {
    settings = { hosting = "cluster_checks" }
  }
  assert {
    condition     = output.agent_container_group_id == null && strcontains(output.cluster_check_confd["postgres.yaml"], "cluster_check")
    error_message = "Cluster-check rendering for obs-kubernetes."
  }
}

run "reject_bad_hosting" {
  command = plan
  variables {
    settings = { hosting = "vm" }
  }
  expect_failures = [var.settings]
}
