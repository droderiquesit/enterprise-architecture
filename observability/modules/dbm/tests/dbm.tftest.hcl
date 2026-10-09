mock_provider "azurerm" {
  override_during = plan
}

variables {
  datadog = { site = "datadoghq.eu", env = "dev" }
  aci = {
    name                = "ci-dbm-eh-dev"
    resource_group_name = "rg-obs"
    location            = "swedencentral"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/aci"
    identity_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-dbm"
    identity_client_id  = "22222222-2222-2222-2222-222222222222"
    key_vault_uri       = "https://kv-obs.vault.azure.net/"
  }
  databases = {
    catalog = {
      engine          = "postgres"
      deployment_type = "flexible_server"
      host            = "psql-eh-dev.postgres.database.azure.com"
      database        = "catalog"
      password_ref    = { kind = "key_vault", name = "dbm-postgres-password" }
    }
    orders = {
      engine                     = "sqlserver"
      deployment_type            = "sql_database"
      host                       = "sql-eh-dev.database.windows.net"
      database                   = "orders"
      auth                       = "managed_identity"
      managed_identity_client_id = "22222222-2222-2222-2222-222222222222"
    }
    adapter_mysql = {
      engine          = "mysql"
      deployment_type = "flexible_server"
      host            = "mysql-eh-dev.mysql.database.azure.com"
      password_ref    = { kind = "key_vault", name = "dbm-mysql-password" }
    }
  }
}

run "aci_hosting" {
  command = plan
  assert {
    condition     = yamldecode(output.confd["postgres.d"]).instances[0].password == "ENC[dbm-postgres-password]" && yamldecode(output.confd["postgres.d"]).instances[0].azure.deployment_type == "flexible_server"
    error_message = "Postgres: ENC[] Key Vault reference + Azure metadata."
  }
  assert {
    condition     = yamldecode(output.confd["sqlserver.d"]).instances[0].managed_identity.client_id == "22222222-2222-2222-2222-222222222222" && !can(yamldecode(output.confd["sqlserver.d"]).instances[0].password)
    error_message = "SQL Database with managed identity: no password at all."
  }
  assert {
    condition     = yamldecode(output.confd["sqlserver.d"]).instances[0].host == "sql-eh-dev.database.windows.net,1433" && yamldecode(output.confd["sqlserver.d"]).instances[0].database == "orders"
    error_message = "SQL Server host,port + database."
  }
  assert {
    condition     = alltrue([for f, c in output.confd : yamldecode(c).instances[0].dbm == true])
    error_message = "dbm: true everywhere."
  }
  assert {
    condition     = azurerm_container_group.dbm[0].ip_address_type == "Private" && length(azurerm_container_group.dbm[0].subnet_ids) == 1
    error_message = "DBM agent runs privately in the subnet."
  }
  assert {
    condition     = yamldecode(base64decode(azurerm_container_group.dbm[0].container[0].volume[0].secret["datadog.yaml"])).secret_backend_type == "azure.keyvault" && yamldecode(base64decode(azurerm_container_group.dbm[0].container[0].volume[0].secret["datadog.yaml"])).api_key == "ENC[datadog-api-key]"
    error_message = "Agent reads API key + passwords from Key Vault via its managed identity."
  }
  assert {
    condition     = azurerm_container_group.dbm[0].container[0].environment_variables["DD_API_KEY"] == "ENC[datadog-api-key]" && try(length(azurerm_container_group.dbm[0].container[0].secure_environment_variables), 0) == 0
    error_message = "No secret values in the container group definition."
  }
  assert {
    condition     = output.configured["orders"].setup_sql == "${path.module}/sql/sqlserver-sql-database-entra.sql" || endswith(output.configured["orders"].setup_sql, "sql/sqlserver-sql-database-entra.sql")
    error_message = "Setup script pointer."
  }
}

run "cluster_checks_hosting" {
  command = plan
  variables {
    hosting = "cluster_checks"
    aci     = null
  }
  assert {
    condition     = length(azurerm_container_group.dbm) == 0 && yamldecode(output.cluster_check_confd["postgres.yaml"]).cluster_check == true
    error_message = "Cluster-check rendering without ACI."
  }
  assert {
    condition     = strcontains(output.helm_values_snippet, "clusterChecksRunner")
    error_message = "Helm values snippet."
  }
}

run "reject_unsupported_engine" {
  command = plan
  variables {
    hosting = "none"
    databases = {
      cosmos = {
        engine          = "cosmosdb"
        deployment_type = "flexible_server"
        host            = "x.documents.azure.com"
        password_ref    = { kind = "key_vault", name = "x" }
      }
    }
  }
  expect_failures = [var.databases]
}

run "reject_mysql_managed_identity" {
  command = plan
  variables {
    hosting = "none"
    databases = {
      m = {
        engine                     = "mysql"
        deployment_type            = "flexible_server"
        host                       = "m"
        auth                       = "managed_identity"
        managed_identity_client_id = "x"
      }
    }
  }
  expect_failures = [var.databases]
}

run "reject_password_without_reference" {
  command = plan
  variables {
    hosting = "none"
    databases = {
      p = {
        engine          = "postgres"
        deployment_type = "flexible_server"
        host            = "p"
      }
    }
  }
  expect_failures = [var.databases]
}

run "reject_env_password_on_aci" {
  command = plan
  variables {
    databases = {
      p = {
        engine          = "postgres"
        deployment_type = "flexible_server"
        host            = "p"
        password_ref    = { kind = "env", name = "PG_PW" }
      }
    }
  }
  expect_failures = [azurerm_container_group.dbm]
}
