# Datadog Database Monitoring check configs for Azure databases + optional ACI Agent host.
# Docs (2026-10): https://docs.datadoghq.com/database_monitoring/setup_postgres/azure/ ,
# .../setup_mysql/azure/ , .../setup_sql_server/azure/ , .../guide/managed_authentication/
# instance tags from the tag policy (env / team / owner / region / ... + service of the owning application, so DBM
# matches APM's database spans and the org's existing monitors); db_key + per-database tags as extras
module "db_tags" {
  source           = "../tagging"
  for_each         = var.databases
  policy           = var.tag_policy
  identity         = merge(var.identity, { env = var.datadog.env }, each.value.service == null ? {} : { service = each.value.service })
  extra_tags       = merge(each.value.tags, { db_key = each.key })
  enforce_required = var.enforce_tag_policy
}

locals {
  default_port = { postgres = 5432, mysql = 3306, sqlserver = 1433 }
  check_dir    = { postgres = "postgres.d", mysql = "mysql.d", sqlserver = "sqlserver.d" }

  password_value = {
    for k, d in var.databases : k => d.password_ref == null ? null : (
      d.password_ref.kind == "dsv" ? "ENC[${d.password_ref.name}]" :
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
        tags     = module.db_tags[k].dd_tags_list
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

  # ACI host: the Agent resolves every ENC[dsv://...] (API key, DB passwords) itself with dsv-fetch agent-backend,
  # authenticating to Delinea DSV with the container group's user-assigned identity (IMDS). No secret values in
  # this config, the container group definition or Terraform state. (ACI init containers cannot use managed
  # identities - Microsoft Learn - so the reader runs inside the Agent container as its secret backend.)
  dsv_fetch_source = coalesce(try(var.aci.dsv_fetch_source, null), "${path.module}/../../images/dsv-fetch/dsv_fetch.py")
  aci_dsv_config = var.aci == null ? null : jsonencode(merge(
    var.aci.dsv.tenant == null ? {} : { DSV_TENANT = var.aci.dsv.tenant },
    var.aci.dsv.tld == null ? {} : { DSV_TLD = var.aci.dsv.tld },
    var.aci.dsv.base_url == null ? {} : { DSV_BASE_URL = var.aci.dsv.base_url },
    { DSV_AUTH = "azure", AZURE_CLIENT_ID = var.aci.identity_client_id, DSV_TIMEOUT_SECONDS = "10" },
  ))
  aci_datadog_yaml = var.aci == null ? null : yamlencode({
    api_key                    = "ENC[${var.aci.api_key_ref}]"
    site                       = var.datadog.site
    env                        = var.datadog.env
    hostname                   = var.aci.name
    logs_enabled               = false
    apm_config                 = { enabled = false }
    process_config             = { process_collection = { enabled = false } }
    enable_metadata_collection = true
    secret_backend_command     = "/opt/dsv-fetch/dsv-fetch"
    secret_backend_arguments   = ["agent-backend", "--config", "/eh/dsv/dsv.json"]
    secret_backend_timeout     = 30
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
    # install dsv-fetch as the secret backend (root-owned, 0500, embedded python3 - what the Agent requires), place
    # the rendered datadog.yaml + check configs, then hand over to the image entrypoint
    commands = ["/bin/sh", "-c", "python3 -I /eh/dsv/dsv_fetch.py install --dest /opt/dsv-fetch/dsv-fetch --python /opt/datadog-agent/embedded/bin/python3 && cp /eh/agent/datadog.yaml /etc/datadog-agent/datadog.yaml && for d in /eh/confd/*; do n=$(basename $d); mkdir -p /etc/datadog-agent/conf.d/$n.d && cp $d /etc/datadog-agent/conf.d/$n.d/conf.yaml; done && exec /bin/entrypoint.sh"]
    environment_variables = {
      DD_SITE     = var.datadog.site
      DD_HOSTNAME = var.aci.name
      # the image's init script requires a non-empty DD_API_KEY; an ENC[] reference is resolved by the
      # secret backend like any config value (observability/tests/transport/test_dbm_local.py)
      DD_API_KEY = "ENC[${var.aci.api_key_ref}]"
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
      name       = "dsv"
      mount_path = "/eh/dsv"
      read_only  = true
      secret = {
        "dsv_fetch.py" = base64encode(file(local.dsv_fetch_source))
        "dsv.json"     = base64encode(local.aci_dsv_config)
      }
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
      error_message = "hosting = aci requires var.aci (subnet, identity, DSV reference of the API key)."
    }
    precondition {
      condition     = alltrue([for d in values(var.databases) : d.auth != "password" || contains(["dsv", "file"], d.password_ref.kind)])
      error_message = "On ACI, DB passwords must come from Delinea DSV (password_ref.kind = dsv, name = dsv://...)."
    }
  }
}
