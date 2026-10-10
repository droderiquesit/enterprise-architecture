output "contract" {
  description = "obs-kubernetes v2 contract (catalog/contracts/obs-kubernetes.v2.schema.json)."
  value       = merge(module.kubernetes.contract, { cluster_id = var.platform_aks.cluster_id })
}
