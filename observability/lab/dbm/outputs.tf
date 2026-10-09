# obs-dbm publishes no contract; outputs are evidence + the cluster-check snippet for obs-kubernetes.
output "configured" {
  value = module.dbm.configured
}

output "cluster_check_confd" {
  description = "Copy into obs-kubernetes settings.dbm_cluster_checks when settings.hosting = cluster_checks."
  value       = module.dbm.cluster_check_confd
}

output "agent_container_group_id" {
  value = module.dbm.agent_container_group_id
}
