# ids are composed (known at plan) so that the policy parameters are plannable; they equal the created resources' ids
output "gallery" {
  description = "Azure Compute Gallery {id, name, resource_group_name}."
  value       = { id = local.gallery_id, name = var.names.gallery, resource_group_name = local.rg_name }
}

output "applications" {
  description = "Application key (linux | windows | linux_arm64) -> {id, name, os, version, version_id}: the version this apply published (var.package_version)."
  value = { for k, a in local.apps : k => {
    id         = "${local.gallery_id}/applications/${a.name}"
    name       = a.name
    os         = a.os
    version    = var.package_version
    version_id = "${local.gallery_id}/applications/${a.name}/versions/${var.package_version}"
  } }
}

output "versions" {
  description = "Every published version per application (current + retained)."
  value       = { for k in keys(local.apps) : k => sort([for vk, v in local.version_keys : v.version if v.app == k]) }
}

output "agent_version" {
  description = "Datadog Agent version installed by the current package version (fleet policy agent.version)."
  value       = local.agent_version
}

output "content_sha256" {
  description = "Application key -> hash of everything the current version is made of (installer, binary, commands)."
  value       = local.content_sha256
}

output "installers" {
  description = "Rendered setup scripts (no secrets). Golden images can bake them: run `<script> install` next to the dsv-fetch binary."
  value       = local.installers
}

output "otlp_endpoint" {
  description = "OTLP endpoint for apps on enrolled hosts (Agent receiver on localhost)."
  value       = { grpc = "http://localhost:4317", http = "http://localhost:4318" }
}

output "storage" {
  description = "Package storage {account_id, container_id}."
  value       = { account_id = azurerm_storage_account.packages.id, container_id = azurerm_storage_container.packages.id }
}
