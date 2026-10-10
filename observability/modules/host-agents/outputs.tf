output "mode" {
  description = "policy | direct."
  value       = var.mode
}

output "gallery" {
  description = "Azure Compute Gallery {id, name, resource_group_name}."
  value       = module.package.gallery
}

output "applications" {
  description = "VM Applications (linux | windows | linux_arm64) -> {id, name, os, version, version_id} of the version this environment pins."
  value       = module.package.applications
}

output "agent_version" {
  description = "Datadog Agent version of the pinned package version."
  value       = module.package.agent_version
}

output "enrollment_tag" {
  description = "Azure tag platform owners set on VMs / VMSS to enrol them (policy mode)."
  value       = var.mode == "policy" ? module.policy[0].enrollment_tag : null
}

output "policy" {
  description = "policy mode: {assignment_id, policy_set_definition_id, remediation_identity, remediations}; null in direct mode."
  value = var.mode == "policy" ? {
    assignment_id            = module.policy[0].assignment_id
    policy_set_definition_id = module.policy[0].policy_set_definition_id
    remediation_identity     = module.policy[0].remediation_identity
    remediations             = module.policy[0].remediations
  } : null
}

output "assignments" {
  description = "direct mode: VM key -> gallery application assignment id."
  value       = { for k, a in azurerm_virtual_machine_gallery_application_assignment.direct : k => a.id }
}

output "vmss_gallery_applications" {
  description = <<-EOT
    direct mode: VMSS key -> the gallery_application block its PLATFORM root sets on the scale set
    (azurerm_*_virtual_machine_scale_set gallery_application { version_id, order }); azurerm has no separate
    assignment resource for scale sets. Empty in policy mode (the policy updates the scale set model).
  EOT
  value = { for k, h in local.direct_vmsss : k => {
    version_id = module.package.applications[local.app_key[k]].version_id
    order      = 10
  } }
}

output "installers" {
  description = "Rendered setup scripts per application (no secrets) for golden images."
  value       = module.package.installers
}

output "otlp_endpoint" {
  description = "OTLP endpoint apps on enrolled hosts use (Agent receiver on localhost)."
  value       = module.package.otlp_endpoint
}
