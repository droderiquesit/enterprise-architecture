# Datadog Agent on the lab VMs / VMSS (observability 4.0.0) through modules/host-agents:
#   VM Applications datadog-agent-linux / datadog-agent-windows in this environment's Compute Gallery, enforced by an
#   Azure Policy initiative on every VM / VMSS tagged datadog:enabled = true (platform roots set the tag). No
#   per-host Terraform, no run commands, no CustomScript. settings.mode = direct is the escape hatch for
#   environments without Azure Policy rights.
# No secret passes through this root: the Agent on each host resolves api_key: ENC[dsv://...] with the dsv-fetch
# binary (secret backend) and the per-environment DSV-reader identity foundation-identity identities["obs-host-agent"].
module "naming" {
  source          = "../../../foundation/modules/naming"
  prefix          = var.environment.name_prefix
  environment     = var.environment.name
  location        = var.environment.location
  subscription_id = var.environment.subscription_id
  workload        = "obshosts"
}

module "tags" {
  source      = "../../../foundation/modules/tags"
  environment = var.environment
  component   = "obs-hosts"
  layer       = "observability"
  service     = "host-agents"
  domain      = "observability"
}

locals {
  # Package 3.0.0+ fleet switches published by obs-telemetry-transport (contract env.fleet). A transport contract
  # without them (package 2.x) keeps the 2.x switches; on hosts the Agent collects the logs either way.
  fleet_env     = try(var.obs_telemetry_transport.env.fleet, null)
  fleet_default = yamldecode(file("${path.module}/../../config/fleet-policy.yaml"))
  fleet_policy = merge(local.fleet_default, {
    environments = merge(try(local.fleet_default.environments, {}), { (var.environment.name) = {
      log_pipeline = try(local.fleet_env.EH_LOG_PIPELINE, "fluent_bit_direct")
      apm          = { mode = try(local.fleet_env.EH_APM_MODE, "otel") }
      profiling    = { enabled = try(tobool(local.fleet_env.EH_PROFILING_ENABLED), false) }
    } })
  })
  op_logs_url = try(var.obs_telemetry_transport.aggregator.kind, "") == "observability_pipelines" ? try(var.obs_telemetry_transport.aggregator.agent_logs_url, null) : null

  agent_identity = var.foundation_identity.identities[var.settings.agent_identity_key]
  region         = module.naming.region_short
  prefix         = var.environment.name_prefix
  env            = var.environment.name

  # direct mode only: hosts from the platform contracts
  direct_hosts = var.settings.mode != "direct" ? {} : merge(
    var.platform_vm == null ? {} : { for k, v in var.platform_vm.vms : "vm-${k}" => { resource_id = v.id, os_type = lower(v.os_type), kind = "vm" } },
    var.platform_vmss == null ? {} : { for k, v in var.platform_vmss.scale_sets : "vmss-${k}" => { resource_id = v.id, os_type = lower(v.os_type), kind = "vmss" } },
    var.platform_db_sqlvm == null ? {} : { "sqlvm" = { resource_id = var.platform_db_sqlvm.vm.id, os_type = var.settings.sqlvm_os_type, kind = "vm" } },
  )
  dsv_fetch = lookup(var.artifacts, "img-dsv-fetch", null)
}

resource "azurerm_resource_group" "hosts" {
  name     = module.naming.names.resource_group
  location = var.environment.location
  tags     = module.tags.tags

  lifecycle {
    precondition {
      condition     = fileexists("${path.module}/${var.settings.dsv_fetch_release_dir}/SHA256SUMS")
      error_message = "Stage the img-dsv-fetch release (dsv-fetch-linux-amd64, dsv-fetch-linux-arm64, dsv-fetch-windows-amd64.exe, SHA256SUMS) into observability/lab/hosts/${var.settings.dsv_fetch_release_dir} before plan."
    }
    precondition {
      condition     = contains(keys(var.foundation_identity.identities), var.settings.agent_identity_key)
      error_message = "foundation-identity has no ${var.settings.agent_identity_key} identity (the per-environment DSV reader of the host Agents)."
    }
  }
}

module "hosts" {
  source = "../../modules/host-agents"
  mode   = var.settings.mode
  env    = local.env

  package = {
    # composed (known at plan: the policy scope / gallery checks need it); depends_on below orders the creation
    resource_group_id = "/subscriptions/${var.environment.subscription_id}/resourceGroups/${azurerm_resource_group.hosts.name}"
    location          = var.environment.location
    names = {
      gallery            = replace("${local.prefix}-gal-obshosts-${local.env}-${local.region}", "-", "_")
      storage_account    = module.naming.unique.storage
      publisher_identity = "${local.prefix}-id-obs-gallery-${local.env}-${local.region}"
    }
    version                 = var.settings.package_version
    retained_versions       = var.settings.retained_versions
    applications            = var.settings.applications
    dsv_fetch_release_dir   = "${path.module}/${var.settings.dsv_fetch_release_dir}"
    replica_regions         = var.settings.replica_regions
    publisher_principal_ids = var.settings.publisher_principal_ids
    network                 = var.settings.package_network
  }

  datadog = {
    site        = var.obs_telemetry_transport.datadog_site
    api_key_ref = var.obs_telemetry_transport.api_key_ref
  }
  dsv = {
    tenant   = var.obs_telemetry_transport.secrets.tenant
    tld      = var.obs_telemetry_transport.secrets.tld
    base_url = var.obs_telemetry_transport.secrets.base_url
  }
  agent_identity = { id = local.agent_identity.id, client_id = local.agent_identity.client_id }

  policy = var.settings.mode != "policy" ? null : {
    name_prefix                  = "${local.prefix}-dd-hosts-${local.env}"
    scope                        = coalesce(var.settings.scope, { type = "subscription", id = "/subscriptions/${var.environment.subscription_id}", not_scopes = [] })
    identity_resource_group_name = azurerm_resource_group.hosts.name
    enrollment_tag               = var.settings.enrollment_tag
    effect                       = var.settings.effect
    targets                      = var.settings.targets
    remediation                  = var.settings.remediation
  }
  hosts = local.direct_hosts

  fleet_policy      = local.fleet_policy
  op_agent_logs_url = local.op_logs_url
  host_logs         = var.settings.host_logs
  tags              = merge(module.tags.tags, local.dsv_fetch == null ? {} : { "dsv-fetch-version" = coalesce(local.dsv_fetch.version, "unknown") })

  depends_on = [azurerm_resource_group.hosts]
}
