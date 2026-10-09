# The Datadog API key never passes through this root: the Agents resolve api_key ENC[dsv://...] at run time with
# the dsv-fetch secret backend, and Fluent Bit reads it through a dsv-fetch init container - both with AKS workload
# identity of the obs-collector identity, which this root federates with the three service accounts below
# (platform-aks federates only one service account per identity). ADR-0001 section 14.
locals {
  collector = var.foundation_identity.identities[var.settings.collector_identity_key]
  # Datadog chart release "datadog": agents (DaemonSet) -> SA datadog, cluster-checks runners -> SA
  # datadog-cluster-checks (dedicated); fluent-bit chart release "fluent-bit" -> SA fluent-bit
  workload_service_accounts = var.settings.api_key_mode == "dsv_secret_backend" ? {
    "datadog-agent"          = { namespace = "datadog", service_account = "datadog" }
    "datadog-cluster-checks" = { namespace = "datadog", service_account = "datadog-cluster-checks" }
    "fluent-bit"             = { namespace = "fluent-bit", service_account = "fluent-bit" }
  } : {}
}

resource "azurerm_federated_identity_credential" "collector" {
  for_each                  = local.workload_service_accounts
  name                      = "aks-${var.platform_aks.cluster_name}-${each.value.namespace}-${each.value.service_account}"
  user_assigned_identity_id = local.collector.id
  issuer                    = var.platform_aks.oidc_issuer_url
  subject                   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
  audience                  = ["api://AzureADTokenExchange"]
}

module "kubernetes" {
  source       = "../../modules/kubernetes"
  cluster_name = var.platform_aks.cluster_name
  datadog = {
    site       = var.obs_telemetry_transport.datadog_site
    env        = var.environment.name
    extra_tags = { team = var.environment.team, application = "enterprise-hello", region = var.environment.location }
  }
  api_key = {
    mode                      = var.settings.api_key_mode
    secret_name               = var.settings.synced_secret_name
    cluster_agent_secret_name = var.settings.cluster_agent_secret_name
  }
  dsv = {
    api_key_ref        = var.obs_telemetry_transport.api_key_ref
    tenant             = var.obs_telemetry_transport.secrets.tenant
    tld                = var.obs_telemetry_transport.secrets.tld
    base_url           = var.obs_telemetry_transport.secrets.base_url
    fetch_image        = var.obs_telemetry_transport.secrets.fetch_image
    identity_client_id = local.collector.client_id
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
  cluster_checks = var.settings.dbm_cluster_checks
  fluent_bit     = { exclude_namespaces = var.settings.exclude_namespaces }

  depends_on = [azurerm_federated_identity_credential.collector]
}
