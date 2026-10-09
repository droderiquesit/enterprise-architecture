# Datadog Database Monitoring check configs for Azure databases + optional ACI Agent host.
# Docs (2026-10): https://docs.datadoghq.com/database_monitoring/setup_postgres/azure/ ,
# .../setup_mysql/azure/ , .../setup_sql_server/azure/ , .../guide/managed_authentication/
locals {
  default_port = { postgres = 5432, mysql = 3306, sqlserver = 1433 }
  check_dir    = { postgres = "postgres.d", mysql = "mysql.d", sqlserver = "sqlserver.d" }

  password_value = {
    for k, d in var.databases : k => d.password_ref == null ? null : (
      d.password_ref.kind == "key_vault" ? "ENC[${d.password_ref.name}]" :
      d.password_ref.kind == "k8s_secret" ? "ENC[k8s_secret@${d.password_ref.name}]" :
      d.password_ref.kind == "file" ? "ENC[file@${d.password_ref.name}]" :
      "%%env_${d.password_ref.name}%%"
    )
  }

  instance = {
    for k, d in var.databases : k => merge(
      {
        dbm      = true
        host     = d.engine == "sqlserver" ? "${d.host},${coalesce(d.port, 1433)}" : d.host
        username = d.username
        tags     = [for t in sort(keys(merge({ env = var.datadog.env, db_key = k }, d.tags))) : "${t}:${merge({ env = var.datadog.env, db_key = k }, d.tags)[t]}"]
        azure = merge(
          {
            deployment_type             = d.deployment_type
            fully_qualified_domain_name = d.host
          },
          merge([for _ in(d.engine == "postgres" && d.auth == "managed_identity" ? [1] : []) : {
            managed_authentication = {
              enabled        = true
              client_id      = d.managed_identity_client_id
              identity_scope = "https://ossrdbms-aad.database.windows.net/.default"
            }
          }]...),
        )
      },
      # merge([for _ in (cond ? [1] : []) : {...}]...) = conditional object without type unification
      merge([for _ in(d.engine != "sqlserver" ? [1] : []) : { port = coalesce(d.port, local.default_port[d.engine]) }]...),
      merge([for _ in(d.auth == "password" ? [1] : []) : { password = local.password_value[k] }]...),
      merge([for _ in(d.engine == "postgres" ? [1] : []) : {
        ssl                    = "require"
        dbname                 = coalesce(d.database, "postgres")
        database_autodiscovery = { enabled = true }
        collect_schemas        = { enabled = true }
      }]...),
      merge([for _ in(d.engine == "mysql" ? [1] : []) : {
        ssl = { ca = "/etc/ssl/certs/ca-certificates.crt" }
      }]...),
      merge([for _ in(d.engine == "sqlserver" ? [1] : []) : {
        connector         = "odbc"
        driver            = var.sqlserver_driver
        connection_string = "TrustServerCertificate=no;Encrypt=yes;"
      }]...),
      merge([for _ in(d.engine == "sqlserver" && d.database != null ? [1] : []) : { database = d.database }]...),
      merge([for _ in(d.engine == "sqlserver" && d.auth == "managed_identity" ? [1] : []) : { managed_identity = { client_id = d.managed_identity_client_id } }]...),
    )
  }

  engines = toset([for d in values(var.databases) : d.engine])

  # one conf.yaml per check, all instances of that engine
  confd = {
    for e in local.engines : local.check_dir[e] => yamlencode({
      init_config = {}
      instances   = [for k in sort(keys(var.databases)) : local.instance[k] if var.databases[k].engine == e]
    })
  }

  # cluster checks: dispatched by the Cluster Agent (file name -> content) for modules/kubernetes
  cluster_check_confd = {
    for e in local.engines : "${trimsuffix(local.check_dir[e], ".d")}.yaml" => yamlencode({
      cluster_check = true
      init_config   = {}
      instances     = [for k in sort(keys(var.databases)) : local.instance[k] if var.databases[k].engine == e]
    })
  }

  # Agent main config for the ACI host: no secret values, only ENC[] references resolved from Key Vault
  aci_datadog_yaml = var.aci == null ? null : yamlencode({
    api_key                    = "ENC[${var.aci.api_key_secret_name}]"
    site                       = var.datadog.site
    env                        = var.datadog.env
    hostname                   = var.aci.name
    logs_enabled               = false
    apm_config                 = { enabled = false }
    process_config             = { process_collection = { enabled = false } }
    enable_metadata_collection = true
    secret_backend_type        = "azure.keyvault"
    secret_backend_config = {
      keyvaulturl   = var.aci.key_vault_uri
      azure_session = { azure_client_id = var.aci.identity_client_id }
    }
  })
}

resource "azurerm_container_group" "dbm" {
  count               = var.hosting == "aci" ? 1 : 0
  name                = var.aci.name
  resource_group_name = var.aci.resource_group_name
  location            = var.aci.location
  os_type             = "Linux"
  ip_address_type     = "Private"
  subnet_ids          = [var.aci.subnet_id]
  restart_policy      = "Always"
  tags                = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.aci.identity_id]
  }

  container {
    name   = "datadog-agent"
    image  = var.aci.image
    cpu    = var.aci.cpu
    memory = var.aci.memory_gb
    # place the rendered datadog.yaml + check configs, then hand over to the image entrypoint
    commands = ["/bin/sh", "-c", "cp /eh/agent/datadog.yaml /etc/datadog-agent/datadog.yaml && for d in /eh/confd/*; do n=$(basename $d); mkdir -p /etc/datadog-agent/conf.d/$n.d && cp $d /etc/datadog-agent/conf.d/$n.d/conf.yaml; done && exec /bin/entrypoint.sh"]
    environment_variables = {
      DD_SITE     = var.datadog.site
      DD_HOSTNAME = var.aci.name
      # the image's init script requires a non-empty DD_API_KEY; an ENC[] reference is resolved by the
      # secret backend like any config value (verified locally with Agent 7.84.2, file backend)
      DD_API_KEY = "ENC[${var.aci.api_key_secret_name}]"
    }

    ports {
      port     = 5002
      protocol = "TCP"
    }

    volume {
      name       = "agent-config"
      mount_path = "/eh/agent"
      read_only  = true
      secret     = { "datadog.yaml" = base64encode(local.aci_datadog_yaml) }
    }

    volume {
      name       = "check-config"
      mount_path = "/eh/confd"
      read_only  = true
      secret     = { for f, c in local.confd : trimsuffix(f, ".d") => base64encode(c) }
    }

    liveness_probe {
      exec                  = ["agent", "health"]
      initial_delay_seconds = 60
      period_seconds        = 30
      failure_threshold     = 5
    }
  }

  lifecycle {
    precondition {
      condition     = var.aci != null
      error_message = "hosting = aci requires var.aci (subnet, identity, Key Vault URI)."
    }
    precondition {
      condition     = alltrue([for d in values(var.databases) : d.auth != "password" || contains(["key_vault", "file"], d.password_ref.kind)])
      error_message = "On ACI, DB passwords must come from Key Vault (password_ref.kind = key_vault)."
    }
  }
}
