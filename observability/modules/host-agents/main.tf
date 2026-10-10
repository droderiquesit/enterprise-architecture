# Datadog Agent on VMs and VM scale sets (observability 4.0.0): Azure VM Applications + Azure Policy, no per-host
# Terraform, no run commands, no CustomScript extensions.
#   modules/host-agent-package : Azure Compute Gallery, VM Applications datadog-agent-linux / datadog-agent-windows,
#                                versions = dsv-fetch binary (package) + rendered setup script (configuration)
#   modules/host-agent-policy  : (mode = policy) DeployIfNotExists initiative on VMs / VMSS tagged datadog:enabled:
#                                attaches the per-environment DSV-reader identity and the pinned application version
#   mode = direct              : escape hatch without Azure Policy rights - one gallery application assignment per VM
#                                (same application, same version); VMSS models are set by their platform root
# Secrets: the Agent on the host resolves api_key: ENC[dsv://...] with the dsv-fetch binary as secret backend
# (Linux and Windows); nothing secret in Terraform state, the gallery, the policy or the VM model (ADR-0001 §14).
module "package" {
  source = "../host-agent-package"

  resource_group_id       = var.package.resource_group_id
  location                = var.package.location
  names                   = var.package.names
  package_version         = var.package.version
  retained_versions       = var.package.retained_versions
  applications            = var.package.applications
  dsv_fetch_release_dir   = var.package.dsv_fetch_release_dir
  replica_regions         = var.package.replica_regions
  publisher_principal_ids = var.package.publisher_principal_ids
  network                 = var.package.network
  agent_msi_sha256        = var.package.agent_msi_sha256

  env                 = var.env
  datadog             = var.datadog
  dsv                 = merge(var.dsv, { identity_client_id = var.agent_identity.client_id })
  fleet_policy        = var.fleet_policy
  tag_policy          = var.tag_policy
  extra_tags          = var.extra_tags
  log_pipeline        = var.log_pipeline
  op_agent_logs_url   = var.op_agent_logs_url
  host_logs           = var.host_logs
  default_service     = var.default_service
  metadata_tag_prefix = var.metadata_tag_prefix
  tags                = var.tags
}

module "policy" {
  source = "../host-agent-policy"
  count  = var.mode == "policy" ? 1 : 0

  name_prefix                  = var.policy.name_prefix
  scope                        = var.policy.scope
  location                     = var.package.location
  identity_resource_group_name = var.policy.identity_resource_group_name
  enrollment_tag               = var.policy.enrollment_tag
  arch_tag_name                = var.policy.arch_tag_name
  agent_identity               = { id = var.agent_identity.id }
  gallery_id                   = module.package.gallery.id
  applications                 = { for k, a in module.package.applications : k => { id = a.id, version = a.version, os = a.os } }
  targets                      = var.policy.targets
  effect                       = var.policy.effect
  application_order            = var.policy.application_order
  remediation                  = var.policy.remediation
  extra_role_actions           = var.policy.extra_role_actions
  tags                         = var.tags

  # the versions must exist (replicated) before the assignment can remediate anything
  depends_on = [module.package]
}

# ---------------------------------------------------------------------------------------------- mode = direct
locals {
  app_key      = { for k, h in var.hosts : k => h.os_type == "windows" ? "windows" : (h.arch == "arm64" ? "linux_arm64" : "linux") }
  direct       = var.mode == "direct" ? var.hosts : {}
  direct_vms   = { for k, h in local.direct : k => h if h.kind == "vm" }
  direct_vmsss = { for k, h in local.direct : k => h if h.kind == "vmss" }
}

resource "azurerm_virtual_machine_gallery_application_assignment" "direct" {
  for_each                       = local.direct_vms
  virtual_machine_id             = each.value.resource_id
  gallery_application_version_id = module.package.applications[local.app_key[each.key]].version_id
  order                          = 10
  depends_on                     = [module.package] # the version must exist before a VM references it

  lifecycle {
    precondition {
      condition     = contains(keys(module.package.applications), local.app_key[each.key])
      error_message = "hosts[${each.key}] needs the ${local.app_key[each.key]} VM Application (package.applications)."
    }
  }
}

check "policy_settings" {
  assert {
    condition     = var.mode != "policy" || var.policy != null
    error_message = "mode = policy needs var.policy (scope, name_prefix, identity_resource_group_name)."
  }
}
