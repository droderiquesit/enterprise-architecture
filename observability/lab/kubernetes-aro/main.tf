# Datadog Agent (Helm chart via modules/kubernetes, distribution = "openshift") on the lab Azure Red Hat OpenShift
# cluster: node Agent DaemonSet (container logs -> Observability Pipelines Worker, metrics, APM host port 8126, OTLP,
# Single Step Instrumentation), Cluster Agent and cluster-checks runners - the same chart, layers, post-renderer and
# secret path as obs-kubernetes on AKS (no copy of the module).
#
# The Datadog API key never passes through this root (ADR-0001 section 14): the three Agent components resolve
# api_key ENC[dsv://...] at run time with the static dsv-fetch binary as secret backend, authenticating to Delinea DSV
# with Microsoft Entra workload identity: platform-aro is a managed-identity cluster whose managed OIDC issuer
# (contract oidc_issuer_url) this root federates with the obs-collector identity for the Datadog service accounts.
# No Kubernetes Secret holds the key, no Key Vault, nothing secret in state (cluster credentials: providers.tf).
locals {
  enabled   = try(var.platform_aro.enabled, false) && try(var.platform_aro.cluster_id, null) != null
  collector = var.foundation_identity.identities[var.settings.collector_identity_key]
  issuer    = try(var.platform_aro.oidc_issuer_url, null)
  # Datadog chart release "datadog": agents (DaemonSet) -> SA datadog, Cluster Agent -> SA datadog-cluster-agent,
  # cluster-checks runners -> SA datadog-cluster-checks (dedicated). No Fluent Bit / OP Worker on OpenShift.
  collector_service_accounts = local.enabled ? merge({
    "datadog-agent"         = { namespace = "datadog", service_account = "datadog" }
    "datadog-cluster-agent" = { namespace = "datadog", service_account = "datadog-cluster-agent" }
    }, var.settings.cluster_checks_runner ? {
    "datadog-cluster-checks" = { namespace = "datadog", service_account = "datadog-cluster-checks" }
  } : {}) : {}

  # fleet switches published by obs-telemetry-transport (contract env.fleet), as in obs-kubernetes. On OpenShift the
  # node Agent is the only log collector (no Fluent Bit fallback DaemonSet), so a transport without the switches
  # (package 2.x) defaults to observability_pipelines here and needs aggregator.agent_logs_url (module precondition);
  # EH_LOG_PIPELINE = fluent_bit_direct is rejected by the module on OpenShift.
  fleet_env     = try(var.obs_telemetry_transport.env.fleet, null)
  fleet_default = yamldecode(file("${path.module}/../../config/fleet-policy.yaml"))
  op_logs_url   = try(var.obs_telemetry_transport.aggregator.agent_logs_url, null)
  fleet_policy = merge(local.fleet_default, {
    environments = merge(try(local.fleet_default.environments, {}), { (var.environment.name) = {
      log_pipeline = try(local.fleet_env.EH_LOG_PIPELINE, "observability_pipelines")
      apm          = { mode = try(local.fleet_env.EH_APM_MODE, "otel") }
      profiling    = { enabled = try(tobool(local.fleet_env.EH_PROFILING_ENABLED), false) }
    } })
  })
}

resource "azurerm_federated_identity_credential" "collector" {
  for_each                  = local.collector_service_accounts
  name                      = "aro-${var.platform_aro.cluster_name}-${each.value.namespace}-${each.value.service_account}"
  user_assigned_identity_id = local.collector.id
  issuer                    = local.issuer
  subject                   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
  audience                  = ["api://AzureADTokenExchange"]

  lifecycle {
    precondition {
      condition     = local.issuer != null && can(regex("^https://", coalesce(local.issuer, "x")))
      error_message = "platform-aro publishes no oidc_issuer_url: the ARO cluster must be a managed-identity (workload identity) cluster - the Datadog Agents authenticate to Delinea DSV with Entra workload identity only."
    }
  }
}

module "kubernetes" {
  source       = "../../modules/kubernetes"
  count        = local.enabled ? 1 : 0
  distribution = "openshift"
  cluster_name = lower(var.platform_aro.cluster_name)
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
  }
  charts = { datadog_version = var.settings.datadog_chart_version }
  features = {
    process_collection    = var.settings.process_collection
    cluster_checks_runner = var.settings.cluster_checks_runner
  }
  values_overrides = var.settings.values_overrides
  fleet_policy     = local.fleet_policy
  op_logs_url      = local.op_logs_url
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

  depends_on = [azurerm_federated_identity_credential.collector]
}
