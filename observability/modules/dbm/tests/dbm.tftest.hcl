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
    fetch_image         = "ehacr.azurecr.io/dsv-fetch@sha256:5555555555555555555555555555555555555555555555555555555555555555"
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
  variables {
    hosting = "aci"
  }
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
    condition = (jsondecode(base64decode(azurerm_container_group.dbm[0].container[0].volume[2].secret["dsv.json"])).AZURE_CLIENT_ID == "22222222-2222-2222-2222-222222222222"
      && !contains(keys(azurerm_container_group.dbm[0].container[0].volume[2].secret), "dsv_fetch.py")
      && startswith(azurerm_container_group.dbm[0].container[0].commands[2], "/eh/bin/dsv-fetch install --dest /opt/dsv-fetch/dsv-fetch && ")
    && !strcontains(azurerm_container_group.dbm[0].container[0].commands[2], "python"))
    error_message = "Non-secret DSV config mounted; the static dsv-fetch binary is installed as the root-owned 0500 backend at start (no Python)."
  }
  assert {
    condition = (azurerm_container_group.dbm[0].init_container[0].image == "ehacr.azurecr.io/dsv-fetch@sha256:5555555555555555555555555555555555555555555555555555555555555555"
      && jsonencode(azurerm_container_group.dbm[0].init_container[0].commands) == jsonencode(["/opt/dsv-fetch/dsv-fetch", "install", "--dest", "/eh/bin/dsv-fetch"])
      && azurerm_container_group.dbm[0].init_container[0].volume[0].empty_dir
    && azurerm_container_group.dbm[0].container[0].volume[1].name == "dsv-bin" && azurerm_container_group.dbm[0].container[0].volume[1].empty_dir)
    error_message = "Init container copies the dsv-fetch binary from its image into the shared emptyDir (no identity needed)."
  }
  assert {
    condition     = azurerm_container_group.dbm[0].container[0].image == "gcr.io/datadoghq/agent:7.84.2"
    error_message = "ACI Agent image = fleet policy <agent.image>:<agent.version> (single pin)."
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

run "reject_non_dsv_password" {
  command = plan
  variables {
    hosting = "none"
    databases = {
      p = {
        engine          = "postgres"
        deployment_type = "flexible_server"
        host            = "p"
        password_ref    = { kind = "k8s_secret", name = "datadog/db/password" }
      }
    }
  }
  expect_failures = [var.databases]
}

run "default_hosting_is_cluster_checks" {
  command = plan
  assert {
    condition     = length(azurerm_container_group.dbm) == 0 && output.agent_container_group_id == null && length(output.cluster_check_confd) == 3
    error_message = "Default: cluster checks for the Cluster Agent; no ACI Agent."
  }
}

run "reject_aci_tag_pinned_fetch_image" {
  command = plan
  variables {
    hosting = "aci"
    aci = {
      name                = "ci-dbm-eh-dev"
      resource_group_name = "rg-obs"
      location            = "swedencentral"
      subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/aci"
      identity_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-dbm"
      identity_client_id  = "22222222-2222-2222-2222-222222222222"
      api_key_ref         = "dsv://eh/dev/datadog-api-key#value"
      fetch_image         = "ehacr.azurecr.io/dsv-fetch:2.0.0"
      dsv                 = { tenant = "contoso" }
    }
  }
  expect_failures = [var.aci]
}

run "reject_aci_without_agent_version" {
  command = plan
  variables {
    hosting      = "aci"
    fleet_policy = { apiVersion = "observability/fleet-policy/v1", kind = "FleetPolicy", agent = { remote_configuration = true } }
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
