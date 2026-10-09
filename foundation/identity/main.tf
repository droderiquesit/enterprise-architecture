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

  # DSV secret catalogue (names + metadata, never values): secrets.yaml. ADR-0001 section 14.
  catalogue = yamldecode(file("${path.module}/secrets.yaml")).secrets

  # Workload identity catalogue. `secrets` = DSV secret names the identity reads at runtime (foundation-secrets
  # turns each list into one DSV user + read permission on exactly those paths).
  # Fault injection (ADR §9) is on every HTTP service and the traffic generator (chaos scenarios).
  identity_catalogue = {
    # datadog-api-key: read by the identity's own Fluent Bit (ACA sidecar in sidecar_mode = datadog, the default;
    # VM/VMSS host installer of obs-hosts; Batch job preparation task of deploy-jobs). See README table.
    "hello-bff"           = { purpose = "BFF API (AKS/ACA)", secrets = ["fault-token", "datadog-api-key"] }
    "hello-orders-api"    = { purpose = "orders API, Azure SQL", secrets = ["fault-token", "datadog-api-key"] }
    "hello-inventory-api" = { purpose = "inventory API, Cosmos DB NoSQL", secrets = ["fault-token", "datadog-api-key"] }
    "hello-catalog-api"   = { purpose = "catalog API, PostgreSQL + Managed Redis", secrets = ["fault-token", "datadog-api-key"] }
    "hello-dbadapter"     = { purpose = "per-family DB adapters", secrets = concat(["fault-token", "datadog-api-key"], local.adapter_secret_names) }
    "hello-worker"        = { purpose = "notifications worker, Table Storage", secrets = ["datadog-api-key"] }
    "hello-durable"       = { purpose = "Durable Functions orchestrations", secrets = ["fault-token"] }
    "hello-functions"     = { purpose = "audit/event functions", secrets = ["fault-token", "datadog-api-key"] }
    "hello-jobs"          = { purpose = "ACA jobs / Batch reconciliation", secrets = ["datadog-api-key"] }
    "hello-partner-sim"   = { purpose = "simulated partner API (ACI)", secrets = ["fault-token", "datadog-api-key"] }
    "hello-traffic"       = { purpose = "synthetic traffic + chaos scenarios", secrets = ["fault-token"] }
    "hello-logicapps"     = { purpose = "Logic Apps Consumption/Standard workflows (Service Bus, Blob)", secrets = [] }
    "hello-frontend"      = { purpose = "frontend hosting (SWA/nginx); RUM client token is injected at deploy time", secrets = [] }
    "obs-collector"       = { purpose = "Fluent Bit / OTel gateway", secrets = ["datadog-api-key", "fluentbit-shared-key", "eventhub-fluentbit-listen"] }
    "obs-dbm"             = { purpose = "Datadog Agent DBM checks", secrets = concat(["datadog-api-key"], local.dbm_secret_names) }
    "aks-control-plane"   = { purpose = "AKS cluster (control plane) identity", secrets = [] }
    "aks-kubelet"         = { purpose = "AKS kubelet identity (AcrPull granted by platform-aks)", secrets = [] }
    # Pipeline: reads pipeline secrets (Datadog provider keys, smoke fault token, RUM token) and the platform apply
    # inputs (tools/secrets/fetch.py), and publishes Azure-generated values (tools/secrets/publish.py).
    "deploy-agent" = { purpose = "self-hosted pipeline agents (VMSS / MDP)", secrets = local.pipeline_secrets }
  }
  identities = merge(
    { for k, v in local.identity_catalogue : k => {
      purpose = v.purpose
      secrets = distinct(concat(v.secrets, lookup(var.settings.extra_identity_secrets, k, [])))
    } },
    { for k, p in var.settings.extra_identities : k => { purpose = p, secrets = lookup(var.settings.extra_identity_secrets, k, []) } },
  )

  # Key/password-based data APIs that cannot use Entra ID (see platform/data READMEs).
  adapter_secret_names = [
    "sqlvm-dbadapter-password", "cassandra-mi-dbadapter-password", "cosmos-cassandra-password",
    "cosmos-gremlin-key", "cosmos-mongo-connection-string",
  ]
  dbm_secret_names = [for e in var.settings.dbm_sql_auth_engines : "dbm-${e}-password"]
  # Every catalogue secret except DBM passwords of engines that use managed-identity auth.
  secret_names = sort([for name, s in local.catalogue : name if try(s.dbm_engine, null) == null || contains(var.settings.dbm_sql_auth_engines, try(s.dbm_engine, ""))])
  pipeline_secrets = [
    "datadog-api-key", "datadog-app-key", "datadog-client-token", "fault-token",
    "sqlvm-admin-password", "sqlvm-dbadapter-password", "documentdb-admin-password", "cassandra-mi-admin-password",
    "mysql-admin-password", "appgw-tls-pfx", "aro-pull-secret",
  ]

  dsv_tld      = var.secrets.tld
  dsv_tenant   = var.secrets.tenant
  dsv_base_url = coalesce(var.secrets.base_url, "https://${var.secrets.tenant}.secretsvaultcloud.${var.secrets.tld}/v1")
  base_path    = "${var.environment.name_prefix}/${var.environment.name}"

  identity_name = { for k, _ in local.identities : k => "${var.environment.name_prefix}-id-${k}-${var.environment.name}-${module.naming.region_short}" }
}

resource "azurerm_resource_group" "identity" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags

  lifecycle {
    precondition {
      condition     = alltrue(flatten([for k, v in local.identities : [for s in v.secrets : contains(keys(local.catalogue), s)]]))
      error_message = "Every identity secret must be listed in foundation/identity/secrets.yaml."
    }
    precondition {
      condition     = alltrue([for name, s in local.catalogue : contains(["operator", "generated"], s.source)])
      error_message = "secrets.yaml: source must be operator or generated."
    }
  }
}

resource "azurerm_user_assigned_identity" "this" {
  for_each = local.identities

  name                = local.identity_name[each.key]
  resource_group_name = azurerm_resource_group.identity.name
  location            = local.location
  tags                = merge(local.tags, { purpose = each.value.purpose })
}

# Read access to immutable app packages in the bootstrap `packages` container (no SAS tokens anywhere).
resource "azurerm_role_assignment" "package_readers" {
  for_each = var.settings.packages_container_id == null ? toset([]) : toset([for i in var.settings.package_reader_identities : i if contains(keys(local.identities), i)])

  scope                = var.settings.packages_container_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.this[each.value].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Read app packages (managed-identity download) for ${each.value}"
}

