# The Datadog API key is read EPHEMERALLY from Key Vault and written write-only into the Kubernetes
# Secret: it is never stored in plan or state.
ephemeral "azurerm_key_vault_secret" "api_key" {
  name         = var.settings.api_key_secret_name
  key_vault_id = var.foundation_identity.key_vault_id
}

module "kubernetes" {
  source       = "../../modules/kubernetes"
  cluster_name = var.platform_aks.cluster_name
  datadog = {
    site       = var.obs_telemetry_transport.datadog_site
    env        = var.environment.name
    extra_tags = { team = var.environment.team, application = "enterprise-hello", region = var.environment.location }
  }
  api_key    = { mode = "write_only" }
  api_key_wo = ephemeral.azurerm_key_vault_secret.api_key.value
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
}
