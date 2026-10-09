# One hello-dbadapter instance per DB family whose platform contract is present (optional producers),
# with family-specific configuration (applications/services/dbadapter/src/hello_dbadapter/drivers/*.py).
locals {

  sql    = var.platform_db_sql
  sqlmi  = var.platform_db_sqlmi
  sqlvm  = var.platform_db_sqlvm
  pg     = var.platform_db_postgresql
  mysql  = var.platform_db_mysql
  cnosql = var.platform_db_cosmos_nosql
  cmongo = var.platform_db_cosmos_mongo
  ccass  = var.platform_db_cosmos_cassandra
  cgrem  = var.platform_db_cosmos_gremlin
  ctable = var.platform_db_cosmos_table
  docdb  = var.platform_db_documentdb
  cassmi = var.platform_db_cassandra_mi
  redis  = var.platform_db_redis
  tbl    = var.platform_db_table_storage
  ledger = var.platform_db_ledger
  hzdb   = var.platform_db_horizondb
  da     = var.platform_data_analytics

  region_names = { swedencentral = "Sweden Central", westeurope = "West Europe", northeurope = "North Europe", eastus = "East US", eastus2 = "East US 2", westus2 = "West US 2", uksouth = "UK South", germanywestcentral = "Germany West Central", francecentral = "France Central" }
  region_dn    = coalesce(var.settings.region_display_name, lookup(local.region_names, local.location, local.location))

  # family => {available, hosting (matrix default), short name, env, secret_env (name -> dsv:// reference)}
  catalog = {
    "sql" = {
      available = local.sql != null && try(local.sql.databases["adapter"] != null, false)
      hosting   = "aca"
      short     = "sql"
      env       = local.sql == null ? {} : { SQL_SERVER = "${local.sql.server.fqdn},${local.sql.server.port}", SQL_DATABASE = try(local.sql.databases["adapter"].name, "adapter"), SQL_AUTH = "entra" }
      secrets   = {}
    }
    "sqlmi" = {
      available = local.sqlmi != null && try(local.sqlmi.enabled && local.sqlmi.server != null, false)
      hosting   = "aca-dedicated"
      short     = "sqlmi"
      env       = try({ SQL_SERVER = "${local.sqlmi.server.fqdn},${local.sqlmi.server.port}", SQL_DATABASE = try(local.sqlmi.databases["adapter"].name, "adapter"), SQL_AUTH = "entra" }, {})
      secrets   = {}
    }
    "sqlvm" = {
      available = local.sqlvm != null
      hosting   = "vmss"
      short     = "sqlvm"
      env = local.sqlvm == null ? {} : {
        SQL_SERVER                   = "${local.sqlvm.server.fqdn},${local.sqlvm.server.port}"
        SQL_DATABASE                 = try(local.sqlvm.databases["adapter"].name, "adapter")
        SQL_AUTH                     = "password"
        SQL_USER                     = try(coalesce(local.sqlvm.databases["adapter"].login, "dbadapter"), "dbadapter")
        SQL_TRUST_SERVER_CERTIFICATE = "yes" # self-signed SQL Server certificate on the VM (private network only)
      }
      secrets = try(local.sqlvm.databases["adapter"].password_secret_id, null) == null ? {} : { SQL_PASSWORD = local.sqlvm.databases["adapter"].password_secret_id }
    }
    "postgresql" = {
      available = local.pg != null && try(local.pg.databases["adapter"] != null, false)
      hosting   = "aca"
      short     = "pg"
      env       = local.pg == null ? {} : { PG_HOST = local.pg.server.fqdn, PG_PORT = tostring(local.pg.server.port), PG_DATABASE = try(local.pg.databases["adapter"].name, "adapter"), PG_USER = "hello-dbadapter", PG_AUTH = "entra" }
      secrets   = {}
    }
    "postgresql-elastic" = {
      available = try(local.pg.elastic_cluster != null, false)
      hosting   = "aca"
      short     = "pgel"
      env       = try({ PG_HOST = local.pg.elastic_cluster.fqdn, PG_PORT = tostring(local.pg.elastic_cluster.port), PG_DATABASE = local.pg.elastic_cluster.database, PG_USER = "hello-dbadapter", PG_AUTH = "entra" }, {})
      secrets   = {}
    }
    "horizondb" = {
      available = try(local.hzdb.enabled && local.hzdb.cluster.fqdn != null, false)
      hosting   = "aca"
      short     = "hzdb"
      env       = try({ PG_HOST = local.hzdb.cluster.fqdn, PG_PORT = tostring(local.hzdb.cluster.port), PG_DATABASE = "adapter", PG_USER = "hello-dbadapter", PG_AUTH = "entra" }, {})
      secrets   = {}
    }
    "mysql" = {
      available = local.mysql != null && try(local.mysql.databases["adapter"] != null, false)
      hosting   = "appservice"
      short     = "mysql"
      env       = local.mysql == null ? {} : { MYSQL_HOST = local.mysql.server.fqdn, MYSQL_PORT = tostring(local.mysql.server.port), MYSQL_DATABASE = try(local.mysql.databases["adapter"].name, "adapter"), MYSQL_USER = "hello-dbadapter", MYSQL_AUTH = "entra", MYSQL_SSL = "true" }
      secrets   = {}
    }
    "cosmos-nosql" = {
      available = local.cnosql != null && try(local.cnosql.databases["adapter"] != null, false)
      hosting   = "aca"
      short     = "cnosql"
      env       = local.cnosql == null ? {} : { COSMOS_ENDPOINT = local.cnosql.account.endpoint, COSMOS_DATABASE = "adapter", COSMOS_CONTAINER = "records", COSMOS_AUTH = "entra" }
      secrets   = {}
    }
    "cosmos-mongo" = {
      available = local.cmongo != null && try(local.cmongo.key_secret_id != null, false)
      hosting   = "aca"
      short     = "cmongo"
      env       = { MONGO_AUTH = "connection_string", MONGO_DATABASE = "adapter", MONGO_COLLECTION = "records" }
      secrets   = try({ MONGO_URI = local.cmongo.key_secret_id }, {}) # connection string held in Delinea DSV (no Entra data plane)
    }
    "documentdb" = {
      available = local.docdb != null
      hosting   = "aca"
      short     = "docdb"
      env = local.docdb == null ? {} : {
        MONGO_URI        = "mongodb+srv://${local.docdb.cluster.host}/?tls=true&authMechanism=MONGODB-OIDC&retrywrites=false&maxIdleTimeMS=120000"
        MONGO_AUTH       = "entra"
        MONGO_DATABASE   = "adapter"
        MONGO_COLLECTION = "records"
      }
      secrets = {}
    }
    "cosmos-cassandra" = {
      available = local.ccass != null && try(local.ccass.key_secret_id != null, false)
      hosting   = "aca"
      short     = "ccass"
      env = local.ccass == null ? {} : {
        CASSANDRA_CONTACT_POINTS  = coalesce(local.ccass.account.host, "${local.ccass.account.name}.cassandra.cosmos.azure.com")
        CASSANDRA_PORT            = tostring(coalesce(local.ccass.account.port, 10350))
        CASSANDRA_USERNAME        = coalesce(local.ccass.account.username, local.ccass.account.name)
        CASSANDRA_LOCAL_DC        = local.region_dn
        CASSANDRA_TLS             = "true"
        CASSANDRA_KEYSPACE        = "adapter"
        CASSANDRA_CREATE_KEYSPACE = "false"
      }
      secrets = try({ CASSANDRA_PASSWORD = local.ccass.key_secret_id }, {})
    }
    "cassandra-mi" = {
      available = try(local.cassmi.enabled && local.cassmi.cluster != null, false)
      hosting   = "aca"
      short     = "cassmi"
      env = try({
        CASSANDRA_CONTACT_POINTS = join(",", local.cassmi.cluster.seed_node_ip_addresses)
        CASSANDRA_PORT           = tostring(local.cassmi.cluster.port)
        CASSANDRA_USERNAME       = coalesce(local.cassmi.databases["adapter"].login, "dbadapter")
        CASSANDRA_LOCAL_DC       = local.cassmi.cluster.datacenter
        CASSANDRA_TLS            = "true"
        CASSANDRA_KEYSPACE       = "adapter"
      }, {})
      secrets = try({ CASSANDRA_PASSWORD = local.cassmi.databases["adapter"].password_secret_id }, {})
    }
    "cosmos-gremlin" = {
      available = local.cgrem != null && try(local.cgrem.key_secret_id != null, false)
      hosting   = "aca"
      short     = "cgrem"
      env       = local.cgrem == null ? {} : { GREMLIN_ENDPOINT = "wss://${local.cgrem.account.name}.gremlin.cosmos.azure.com:443/", GREMLIN_DATABASE = "adapter", GREMLIN_GRAPH = "records" }
      secrets   = try({ GREMLIN_KEY = local.cgrem.key_secret_id }, {})
    }
    "cosmos-table" = {
      available = local.ctable != null
      hosting   = "aca"
      short     = "ctable"
      env       = local.ctable == null ? {} : { TABLES_ENDPOINT = local.ctable.account.endpoint, TABLES_AUTH = "entra", TABLES_TABLE = "adapterrecords" }
      secrets   = {}
    }
    "table-storage" = {
      available = local.tbl != null && try(local.tbl.databases["adapterrecords"] != null, false)
      hosting   = "aca"
      short     = "tbl"
      env       = local.tbl == null ? {} : { TABLES_ENDPOINT = local.tbl.account.endpoint, TABLES_AUTH = "entra", TABLES_TABLE = "adapterrecords" }
      secrets   = {}
    }
    "redis" = {
      available = local.redis != null
      hosting   = "aca-dedicated"
      short     = "redis"
      env       = local.redis == null ? {} : { REDIS_HOST = local.redis.cache.hostname, REDIS_PORT = tostring(local.redis.cache.port), REDIS_TLS = "true", REDIS_AUTH = "entra", REDIS_PREFIX = "adapter:" }
      secrets   = {}
    }
    "ledger" = {
      available = local.ledger != null
      hosting   = "aca"
      short     = "ledger"
      env       = local.ledger == null ? {} : merge({ LEDGER_ENDPOINT = local.ledger.ledger.ledger_endpoint, LEDGER_COLLECTION = "adapter" }, local.ledger.ledger.identity_service_endpoint == null ? {} : { LEDGER_IDENTITY_URL = local.ledger.ledger.identity_service_endpoint })
      secrets   = {}
    }
    "blob" = {
      available = try(local.da.blob != null, false)
      hosting   = "aca"
      short     = "blob"
      env       = try({ BLOB_ACCOUNT_URL = local.da.blob.endpoint, BLOB_AUTH = "entra", BLOB_CONTAINER = local.da.blob.container }, {})
      secrets   = {}
    }
    "adls" = {
      available = try(local.da.adls != null, false)
      hosting   = "aca"
      short     = "adls"
      env       = try({ ADLS_ACCOUNT_URL = local.da.adls.endpoint, ADLS_AUTH = "entra", ADLS_FILESYSTEM = local.da.adls.filesystem }, {})
      secrets   = {}
    }
    "search" = {
      available = try(local.da.search != null, false)
      hosting   = "aca"
      short     = "srch"
      env       = try({ SEARCH_ENDPOINT = local.da.search.endpoint, SEARCH_AUTH = "entra", SEARCH_INDEX = local.da.search.index }, {})
      secrets   = {}
    }
    "adx" = {
      available = try(local.da.data_explorer != null, false)
      hosting   = "aca"
      short     = "adx"
      env       = try({ ADX_CLUSTER_URI = local.da.data_explorer.uri, ADX_DATABASE = local.da.data_explorer.database, ADX_TABLE = local.da.data_explorer.table }, {})
      secrets   = {}
    }
  }

  # Effective hosting after settings overrides and fallbacks (dedicated profile / App Service plan / VMSS absent).
  dedicated_profile = try(var.platform_containerapps.dedicated_profile_name, null)
  linux_plan        = try(var.platform_appservice.plans["linux"], null)
  uniform_vmss      = try(var.platform_vmss.scale_sets["uniform"], null)

  requested = { for f, c in local.catalog : f => coalesce(try(var.settings.families[f].hosting, null), c.hosting) }
  hosting = { for f, h in local.requested : f => (
    h == "aca-dedicated" && local.dedicated_profile == null ? "aca" :
    h == "appservice" && local.linux_plan == null ? "aca" :
    h == "vmss" && local.uniform_vmss == null ? "none" : h
  ) }

  enabled = { for f, c in local.catalog : f => c if c.available && try(var.settings.families[f].enabled, true) && local.hosting[f] != "none" }
  skipped = { for f, c in local.catalog : f => (
    !c.available ? "platform contract absent or family disabled in the platform" :
    !try(var.settings.families[f].enabled, true) ? "disabled in settings" : "no host for ${local.requested[f]} (platform-vmss uniform scale set absent)"
  ) if !contains(keys(local.enabled), f) }

  aca_families  = { for f, c in local.enabled : f => c if contains(["aca", "aca-dedicated"], local.hosting[f]) }
  appsvc_family = { for f, c in local.enabled : f => c if local.hosting[f] == "appservice" }
  vmss_family   = { for f, c in local.enabled : f => c if local.hosting[f] == "vmss" }
}
