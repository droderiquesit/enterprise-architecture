output "confd" {
  description = "conf.d directory -> conf.yaml content (host Agent / ACI)."
  value       = local.confd
}

output "cluster_check_confd" {
  description = "Cluster Agent confd (file -> content) for modules/kubernetes var.cluster_checks."
  value       = local.cluster_check_confd
}

output "helm_values_snippet" {
  description = "Datadog Helm chart values snippet enabling these DBM cluster checks."
  value = yamlencode({
    datadog             = { clusterChecks = { enabled = true } }
    clusterAgent        = { confd = local.cluster_check_confd }
    clusterChecksRunner = { enabled = true }
  })
}

output "configured" {
  description = "What was configured per database (no secrets)."
  value = { for k, d in var.databases : k => {
    engine          = d.engine
    deployment_type = d.deployment_type
    host            = d.host
    auth            = d.auth
    password_source = d.password_ref == null ? null : d.password_ref.kind
    hosting         = var.hosting
    setup_sql       = "${path.module}/sql/${d.engine == "sqlserver" ? "sqlserver-${replace(d.deployment_type, "_", "-")}" : "${d.engine}-flexible"}${d.auth == "managed_identity" ? "-entra" : ""}.sql"
  } }
}

output "agent_container_group_id" {
  value = var.hosting == "aci" ? azurerm_container_group.dbm[0].id : null
}
