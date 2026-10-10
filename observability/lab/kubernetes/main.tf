# The Datadog API key never passes through this root: the node Agents, the Cluster Agent and the cluster-checks runners
# resolve api_key ENC[dsv://...] at run time with the static dsv-fetch binary as secret backend (init container
# dsv-fetch-install, image = registry artifact img-dsv-fetch), and the Fluent Bit fallback reads it through a dsv-fetch
# init container - all with AKS workload identity, which this root federates with the service accounts below
# (platform-aks federates only one service account per identity). ADR-0001 section 14.
locals {
  collector = var.foundation_identity.identities[var.settings.collector_identity_key]
  # DBM (settings.dbm = auto): the platform-db contracts of this environment become cluster checks of the Cluster
  # Agent (obs-dbm then creates no ACI Agent - its settings.hosting = auto sees the same platform-aks contract)
  dbm_identity = try(var.foundation_identity.identities[var.settings.dbm_identity_key], null)
  dbm_on       = var.settings.dbm == "auto" && local.dbm_identity != null && length(module.dbm_contracts.databases) > 0
  # Datadog chart release "datadog": agents (DaemonSet) -> SA datadog, Cluster Agent -> SA datadog-cluster-agent,
  # cluster-checks runners -> SA datadog-cluster-checks (dedicated; the obs-dbm identity when DBM checks run there);
  # fluent-bit chart release "fluent-bit" (fallback collector) -> SA fluent-bit
  collector_service_accounts = merge({
    "datadog-agent"         = { namespace = "datadog", service_account = "datadog" }
    "datadog-cluster-agent" = { namespace = "datadog", service_account = "datadog-cluster-agent" }
    "fluent-bit"            = { namespace = "fluent-bit", service_account = "fluent-bit" }
    }, local.dbm_on ? {} : {
    "datadog-cluster-checks" = { namespace = "datadog", service_account = "datadog-cluster-checks" }
  })

  # Package 3.0.0 fleet switches published by obs-telemetry-transport (contract env.fleet). A transport contract
  # without them (package 2.x) keeps this root on the 2.x path: Fluent Bit direct + OpenTelemetry.
  fleet_env     = try(var.obs_telemetry_transport.env.fleet, null)
  fleet_default = yamldecode(file("${path.module}/../../config/fleet-policy.yaml"))
  fleet_policy = merge(local.fleet_default, {
    environments = merge(try(local.fleet_default.environments, {}), { (var.environment.name) = {
      log_pipeline = try(local.fleet_env.EH_LOG_PIPELINE, "fluent_bit_direct")
      apm          = { mode = try(local.fleet_env.EH_APM_MODE, "otel") }
      profiling    = { enabled = try(tobool(local.fleet_env.EH_PROFILING_ENABLED), false) }
    } })
  })
  op_logs_url = try(var.obs_telemetry_transport.aggregator.agent_logs_url, null)
  op_host     = try(var.obs_telemetry_transport.aggregator.kind, "") == "observability_pipelines" ? try(var.obs_telemetry_transport.aggregator.fqdn, null) : null
}

resource "azurerm_federated_identity_credential" "collector" {
  for_each                  = local.collector_service_accounts
  name                      = "aks-${var.platform_aks.cluster_name}-${each.value.namespace}-${each.value.service_account}"
  user_assigned_identity_id = local.collector.id
  issuer                    = var.platform_aks.oidc_issuer_url
  subject                   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
  audience                  = ["api://AzureADTokenExchange"]
}

# cluster-checks runners as the obs-dbm identity: DSV read on the DB password paths + Entra database login
resource "azurerm_federated_identity_credential" "dbm" {
  count                     = local.dbm_on ? 1 : 0
  name                      = "aks-${var.platform_aks.cluster_name}-datadog-datadog-cluster-checks"
  user_assigned_identity_id = local.dbm_identity.id
  issuer                    = var.platform_aks.oidc_issuer_url
  subject                   = "system:serviceaccount:datadog:datadog-cluster-checks"
  audience                  = ["api://AzureADTokenExchange"]
}

module "dbm_contracts" {
  source = "../../modules/dbm/contracts"
  contracts = {
    postgresql = var.platform_db_postgresql
    mysql      = var.platform_db_mysql
    sql        = var.platform_db_sql
    sqlmi      = var.platform_db_sqlmi
    sqlvm      = var.platform_db_sqlvm
  }
  base_path          = try(var.foundation_identity.secrets.base_path, "unset")
  identity_client_id = try(local.dbm_identity.client_id, "unset")
}

module "dbm" {
  source    = "../../modules/dbm"
  databases = local.dbm_on ? module.dbm_contracts.databases : {}
  hosting   = local.dbm_on ? "cluster_checks" : "none"
  datadog   = { site = var.obs_telemetry_transport.datadog_site, env = var.environment.name }
  identity = {
    team        = var.environment.team
    owner       = var.environment.owner
    application = "enterprise-hello"
    domain      = "data"
    tier        = "infrastructure"
    region      = var.environment.location
    managed_by  = "terraform"
  }
}

module "kubernetes" {
  source       = "../../modules/kubernetes"
  cluster_name = var.platform_aks.cluster_name
  datadog = {
    site       = var.obs_telemetry_transport.datadog_site
    env        = var.environment.name
    extra_tags = { team = var.environment.team, application = "enterprise-hello", region = var.environment.location }
  }
  dsv = {
    api_key_ref = var.obs_telemetry_transport.api_key_ref
    tenant      = var.obs_telemetry_transport.secrets.tenant
    tld         = var.obs_telemetry_transport.secrets.tld
    base_url    = var.obs_telemetry_transport.secrets.base_url
    # registry artifact img-dsv-fetch (digest-pinned) of this root; the transport contract's image as fallback
    fetch_image        = try(coalesce(try(var.artifacts["img-dsv-fetch"].image, null), var.obs_telemetry_transport.secrets.fetch_image), null)
    identity_client_id = local.collector.client_id
    # DBM cluster checks: the runners read the DB passwords / log in to Entra as obs-dbm
    cluster_checks_identity_client_id = local.dbm_on ? local.dbm_identity.client_id : null
  }
  charts = {
    datadog_version    = var.settings.datadog_chart_version
    fluent_bit_version = var.settings.fluent_bit_chart_version
  }
  features = {
    process_collection    = var.settings.process_collection
    cluster_checks_runner = var.settings.cluster_checks_runner
    kubelet_tls_mode      = var.settings.kubelet_tls_mode
    is_aks                = true
  }
  cluster_checks = module.dbm.cluster_check_confd
  # per-cluster chart values (YAML documents), applied after the module's base + fleet layers
  values_overrides = var.settings.values_overrides
  # package 3.0.0: fleet policy (log pipeline / SSI / profiling) from the transport contract, canonical tags of the
  # cluster infrastructure (modules/tagging)
  fleet_policy = local.fleet_policy
  op_logs_url  = local.op_logs_url
  identity = {
    team        = var.environment.team
    owner       = var.environment.owner
    application = "enterprise-hello"
    domain      = "platform"
    tier        = "infrastructure"
    region      = var.environment.location
    managed_by  = "terraform"
    cost_center = try(var.environment.cost_center, null)
  }
  apm        = { namespaces = var.settings.ssi_namespaces }
  fluent_bit = { exclude_namespaces = var.settings.exclude_namespaces }

  depends_on = [azurerm_federated_identity_credential.collector, azurerm_federated_identity_credential.dbm]
}
