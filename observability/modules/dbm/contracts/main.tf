# Pure function (no providers): platform-db-* contracts (their `dbm` block, catalog/contracts/platform-db-*.v1 $defs/dbm)
# -> modules/dbm `databases`. Shared by the lab roots that host DBM checks (obs-kubernetes: cluster checks on the
# Cluster Agent; obs-dbm: ACI Agent when there is no cluster) so both render identical instances.
#
# Each contract's `dbm` block: supported, engine, deployment_type, auth_mode, identity_client_id, identity_name, host,
# port, resource_id, databases, password_ref | password_secret_id | password_secret_name. Passwords are Delinea DSV
# references: the block's dsv:// password_ref when published, else the ADR-0001 section 14 path
# dsv://<base_path>/<secret name>#value (legacy password_secret_id: its last segment names the secret).
locals {
  dbm_blocks = {
    for k, c in var.contracts : k => c.dbm if c != null && try(c.dbm.supported, false)
  }
  deployment_type_map = { self_hosted_azure_vm = "virtual_machine" }

  # one DBM instance per database for Azure SQL Database, one per server otherwise
  flat = merge([
    for k, d in local.dbm_blocks : (
      d.engine == "sqlserver" && d.deployment_type == "sql_database" ? {
        for db in try(d.databases, []) : "${k}-${db}" => merge(d, { database = db })
      } : { (k) = merge(d, { database = try(d.databases[0], null) }) }
    )
  ]...)

  databases = { for k, d in local.flat : k => {
    engine                     = d.engine
    deployment_type            = lookup(local.deployment_type_map, d.deployment_type, d.deployment_type)
    host                       = d.host
    port                       = try(d.port, null)
    database                   = d.database
    username                   = d.auth_mode == "entra-managed-identity" ? try(d.identity_name, var.entra_username) : "datadog"
    auth                       = d.auth_mode == "entra-managed-identity" ? "managed_identity" : "password"
    managed_identity_client_id = d.auth_mode == "entra-managed-identity" ? coalesce(try(d.identity_client_id, null), var.identity_client_id) : null
    password_ref = d.auth_mode == "entra-managed-identity" ? null : {
      kind = "dsv"
      # platform contracts keep the field name password_secret_id; its value is a dsv:// reference
      name = startswith(try(d.password_ref, ""), "dsv://") ? d.password_ref : startswith(try(d.password_secret_id, ""), "dsv://") ? d.password_secret_id : "dsv://${var.base_path}/${coalesce(try(d.password_secret_name, null), try(element(split("/", d.password_secret_id), length(split("/", d.password_secret_id)) - 1), null), "dbm-${k}-password")}#value"
    }
    resource_id = try(d.resource_id, null)
    tags        = { platform_contract = k }
  } }
}
