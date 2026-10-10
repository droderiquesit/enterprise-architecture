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
    api_key_ref         = "dsv://eh/dev/datadog-api-key#value"
    dsv                 = { tenant = "contoso" }
  }
  databases = {
    catalog = {
      engine          = "postgres"
      deployment_type = "flexible_server"
      host            = "psql-eh-dev.postgres.database.azure.com"
      database        = "catalog"
      password_ref    = { kind = "dsv", name = "dsv://eh/dev/dbm-postgres-password#value" }
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
      password_ref    = { kind = "dsv", name = "dsv://eh/dev/dbm-mysql-password#value" }
    }
  }
}

run "aci_hosting" {
  command = plan
  assert {
    condition     = yamldecode(output.confd["postgres.d"]).instances[0].password == "ENC[dsv://eh/dev/dbm-postgres-password#value]" && yamldecode(output.confd["postgres.d"]).instances[0].azure.deployment_type == "flexible_server"
    error_message = "Postgres: ENC[] DSV reference + Azure metadata."
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
    condition     = yamldecode(base64decode(azurerm_container_group.dbm[0].container[0].volume[0].secret["datadog.yaml"])).secret_backend_command == "/opt/dsv-fetch/dsv-fetch" && yamldecode(base64decode(azurerm_container_group.dbm[0].container[0].volume[0].secret["datadog.yaml"])).api_key == "ENC[dsv://eh/dev/datadog-api-key#value]" && jsonencode(yamldecode(base64decode(azurerm_container_group.dbm[0].container[0].volume[0].secret["datadog.yaml"])).secret_backend_arguments) == jsonencode(["agent-backend", "--config", "/eh/dsv/dsv.json"])
    error_message = "Agent resolves API key + passwords from DSV with dsv-fetch agent-backend."
  }
  assert {
    condition     = jsondecode(base64decode(azurerm_container_group.dbm[0].container[0].volume[1].secret["dsv.json"])).AZURE_CLIENT_ID == "22222222-2222-2222-2222-222222222222" && strcontains(base64decode(azurerm_container_group.dbm[0].container[0].volume[1].secret["dsv_fetch.py"]), "def cmd_agent_backend") && strcontains(azurerm_container_group.dbm[0].container[0].commands[2], "dsv_fetch.py install --dest /opt/dsv-fetch/dsv-fetch")
    error_message = "dsv-fetch + non-secret DSV config mounted; installed as the root-owned 0500 backend at start."
  }
  assert {
    condition     = azurerm_container_group.dbm[0].container[0].environment_variables["DD_API_KEY"] == "ENC[dsv://eh/dev/datadog-api-key#value]" && try(length(azurerm_container_group.dbm[0].container[0].secure_environment_variables), 0) == 0 && length(azurerm_container_group.dbm[0].init_container) == 0
    error_message = "No secret values in the container group definition (and no init container: ACI init containers have no managed identity)."
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
        password_ref    = { kind = "dsv", name = "dsv://eh/dev/x" }
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

run "instance_tags_from_tag_policy" {
  command = plan
  variables {
    hosting  = "cluster_checks"
    aci      = null
    identity = { team = "data-platform", owner = "data@example.com", region = "swedencentral", application = "enterprise-hello", domain = "data", tier = "high" }
    databases = {
      catalog = {
        engine          = "postgres"
        deployment_type = "flexible_server"
        host            = "psql-eh-dev.postgres.database.azure.com"
        password_ref    = { kind = "dsv", name = "dsv://eh/dev/dbm-postgres-password#value" }
        service         = "hello-catalog-api"
        tags            = { platform_contract = "postgresql" }
      }
    }
    enforce_tag_policy = true
  }
  assert {
    condition = alltrue([for t in ["env:dev", "service:hello-catalog-api", "team:data-platform", "owner:data_example.com", "region:swedencentral", "db_key:catalog", "platform_contract:postgresql", "managed_by:terraform"] :
    contains(yamldecode(output.cluster_check_confd["postgres.yaml"]).instances[0].tags, t)])
    error_message = "DBM instance tags carry the policy tag set (service of the owning app, normalised owner) + db extras"
  }
}
