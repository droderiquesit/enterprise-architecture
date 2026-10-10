# obs-dbm publishes no contract; outputs are evidence + the cluster-check snippet for obs-kubernetes.
output "configured" {
  description = "Databases configured for Database Monitoring (modules/dbm configured)."
  value       = module.dbm.configured
}

output "cluster_check_confd" {
  description = "The DBM cluster checks (evidence; obs-kubernetes renders the same from the platform-db contracts)."
  value       = module.dbm.cluster_check_confd
}

output "hosting" {
  description = "Effective DBM hosting: cluster_checks (cluster present) | aci | none."
  value       = length(local.module_databases) == 0 ? "none" : local.hosting
}

output "agent_container_group_id" {
  description = "Id of the ACI DBM Agent container group (null with cluster checks or hosting = none)."
  value       = module.dbm.agent_container_group_id
}
