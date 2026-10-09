module "naming" {
  source          = "../modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = "identity"
}

module "tags" {
  source      = "../modules/tags"
  environment = var.environment
  component   = "foundation-identity"
  layer       = "foundation"
  domain      = "identity"
}

locals {
  names    = module.naming.names
  tags     = module.tags.tags
  location = var.environment.location

  # Workload identity catalogue. `secrets` = Key Vault secrets the identity reads at runtime.
  # Fault injection (ADR §9) is on every HTTP service and the traffic generator (chaos scenarios).
  identity_catalogue = {
    "hello-bff"           = { purpose = "BFF API (AKS/ACA)", secrets = ["fault-token"] }
    "hello-orders-api"    = { purpose = "orders API, Azure SQL", secrets = ["fault-token"] }
    "hello-inventory-api" = { purpose = "inventory API, Cosmos DB NoSQL", secrets = ["fault-token"] }
    "hello-catalog-api"   = { purpose = "catalog API, PostgreSQL + Managed Redis", secrets = ["fault-token"] }
    "hello-dbadapter"     = { purpose = "per-family DB adapters", secrets = concat(["fault-token"], local.adapter_secret_names) }
    "hello-worker"        = { purpose = "notifications worker, Table Storage", secrets = [] }
    "hello-durable"       = { purpose = "Durable Functions orchestrations", secrets = ["fault-token"] }
    "hello-functions"     = { purpose = "audit/event functions", secrets = ["fault-token"] }
    "hello-jobs"          = { purpose = "ACA jobs / Batch reconciliation", secrets = [] }
    "hello-partner-sim"   = { purpose = "simulated partner API (ACI)", secrets = ["fault-token"] }
    "hello-traffic"       = { purpose = "synthetic traffic + chaos scenarios", secrets = ["fault-token"] }
    "hello-logicapps"     = { purpose = "Logic Apps Consumption/Standard workflows (Service Bus, Blob)", secrets = [] }
    "hello-frontend"      = { purpose = "frontend hosting (SWA/nginx); RUM client token is injected at deploy time", secrets = [] }
    "obs-collector"       = { purpose = "Fluent Bit / OTel gateway", secrets = ["datadog-api-key"] }
    "obs-dbm"             = { purpose = "Datadog Agent DBM checks", secrets = concat(["datadog-api-key"], local.dbm_secret_names) }
    "aks-control-plane"   = { purpose = "AKS cluster (control plane) identity", secrets = [] }
    "aks-kubelet"         = { purpose = "AKS kubelet identity (AcrPull granted by platform-aks)", secrets = [] }
    "deploy-agent"        = { purpose = "self-hosted pipeline agents (VMSS / MDP)", secrets = [] }
  }
  identities = merge(local.identity_catalogue, { for k, p in var.settings.extra_identities : k => { purpose = p, secrets = [] } })

  # Secret *names* only. Values are set out-of-band (scripts/set-secrets.sh); Terraform never sees them.
  # Key/password-based data APIs that cannot use Entra ID (see platform/data READMEs).
  adapter_secret_names = [
    "sqlvm-dbadapter-password", "cassandra-mi-dbadapter-password", "cosmos-cassandra-password",
    "cosmos-gremlin-key", "cosmos-mongo-connection-string",
  ]
  dbm_secret_names = [for e in var.settings.dbm_sql_auth_engines : "dbm-${e}-password"]
  secret_names = concat([
    "datadog-api-key",      # agents/collectors -> Datadog intake
    "datadog-app-key",      # pipeline only (Datadog Terraform provider in observability roots)
    "fault-token",          # X-Fault-Token for POST /admin/faults
    "datadog-client-token", # browser RUM token (browser-safe, still stored centrally and injected at deploy)
  ], local.dbm_secret_names, local.adapter_secret_names)
  pipeline_secrets = ["datadog-api-key", "datadog-app-key", "datadog-client-token", "fault-token"]

  identity_name = { for k, _ in local.identities : k => "${var.environment.name_prefix}-id-${k}-${var.environment.name}-${module.naming.region_short}" }
}

resource "azurerm_resource_group" "identity" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

resource "azurerm_user_assigned_identity" "this" {
  for_each = local.identities

  name                = local.identity_name[each.key]
  resource_group_name = azurerm_resource_group.identity.name
  location            = local.location
  tags                = merge(local.tags, { purpose = each.value.purpose })
}
