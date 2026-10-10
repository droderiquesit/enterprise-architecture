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
  obs_telemetry_transport = {
    datadog_site = "datadoghq.com"
    api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
    secrets      = { tenant = "contoso", tld = "com", base_url = "https://contoso.secretsvaultcloud.com/v1" }
  }
  artifacts = {
    "img-dsv-fetch" = { image = "ehacrdev.azurecr.io/dsv-fetch@sha256:4444444444444444444444444444444444444444444444444444444444444444" }
  }
  foundation_network = {
    subnets = {
      observability = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/observability", name = "observability" }
      aci           = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/aci", name = "aci" }
    }
  }
  foundation_identity = {
    secrets = { base_path = "eh/dev" }
    identities = {
      "obs-dbm" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-obs-dbm-dev-sec", client_id = "33333333-3333-3333-3333-333333333333", name = "eh-id-obs-dbm-dev-sec" }
    }
  }
  platform_db_postgresql = {
    dbm = { supported = true, engine = "postgres", deployment_type = "flexible_server", auth_mode = "entra-managed-identity", identity_name = "obs-dbm", identity_client_id = "33333333-3333-3333-3333-333333333333", host = "eh-psql-dev.postgres.database.azure.com", port = 5432, databases = ["catalog"] }
  }
  platform_db_mysql = {
    dbm = { supported = true, engine = "mysql", deployment_type = "flexible_server", auth_mode = "native-password", host = "eh-mysql-dev.mysql.database.azure.com", port = 3306, databases = ["adapter"], password_secret_id = "dsv://eh/dev/dbm-mysql-password#value" }
  }
  platform_db_sql = {
    dbm = { supported = true, engine = "sqlserver", deployment_type = "sql_database", auth_mode = "entra-managed-identity", identity_name = "obs-dbm", host = "eh-sql-dev.database.windows.net", port = 1433, databases = ["orders", "fulfillment"] }
  }
  platform_db_sqlvm = {
    dbm = { supported = true, engine = "sqlserver", deployment_type = "self_hosted_azure_vm", auth_mode = "sql-login", host = "10.41.1.10", port = 1433, databases = ["adapter"], password_secret_name = "dbm-sqlvm-password" }
  }
}

run "lab_dbm_from_contracts" {
  command = plan
  assert {
    condition     = output.configured["postgresql"].auth == "managed_identity" && output.configured["mysql"].password_source == "dsv"
    error_message = "Entra for PostgreSQL, DSV password for MySQL."
  }
  assert {
    condition     = strcontains(module.dbm.confd["mysql.d"], "ENC[dsv://eh/dev/dbm-mysql-password#value]") && strcontains(module.dbm.confd["sqlserver.d"], "ENC[dsv://eh/dev/dbm-sqlvm-password#value]")
    error_message = "Passwords are ENC[] DSV references (published ref, or derived from the secret name)."
  }
  assert {
    condition     = contains(keys(output.configured), "sql-orders") && contains(keys(output.configured), "sql-fulfillment") && output.configured["sqlvm"].deployment_type == "virtual_machine"
    error_message = "One instance per Azure SQL database; VM deployment type mapped."
  }
  assert {
    condition     = output.agent_container_group_id != null && var.settings.subnet_key == "aci" && output.hosting == "aci"
    error_message = "No cluster (platform-aks absent): auto -> ACI Agent in the ContainerInstance-delegated aci subnet."
  }
  assert {
    condition     = module.dbm.configured["mysql"].hosting == "aci" && length(azurerm_resource_group.this) == 1
    error_message = "ACI hosting resources only without a cluster."
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

run "cluster_present_auto_cluster_checks" {
  command = plan
  variables {
    platform_aks = { cluster_name = "eh-aks-dev-sec", cluster_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-aks-dev-sec/providers/Microsoft.ContainerService/managedClusters/eh-aks-dev-sec" }
  }
  assert {
    condition     = output.hosting == "cluster_checks" && output.agent_container_group_id == null && length(azurerm_resource_group.this) == 0
    error_message = "Cluster present: auto -> no ACI Agent (the Cluster Agent runs the checks)."
  }
  assert {
    condition     = strcontains(output.cluster_check_confd["postgres.yaml"], "cluster_check") && strcontains(output.cluster_check_confd["mysql.yaml"], "ENC[dsv://eh/dev/dbm-mysql-password#value]")
    error_message = "Cluster checks with ENC[dsv://] password references (binary secret backend of the runners)."
  }
}

run "explicit_aci_with_cluster" {
  command = plan
  variables {
    platform_aks = { cluster_name = "eh-aks-dev-sec" }
    settings     = { hosting = "aci" }
  }
  assert {
    condition     = output.hosting == "aci" && output.agent_container_group_id != null
    error_message = "Explicit hosting = aci still creates the ACI Agent (then set obs-kubernetes settings.dbm = off)."
  }
}

run "reject_bad_hosting" {
  command = plan
  variables {
    settings = { hosting = "vm" }
  }
  expect_failures = [var.settings]
}
