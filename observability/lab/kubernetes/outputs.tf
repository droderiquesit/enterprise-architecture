output "contract" {
  description = "obs-kubernetes v1 contract (catalog/contracts/obs-kubernetes.v1.schema.json)."
  value       = merge(module.kubernetes.contract, { cluster_id = var.platform_aks.cluster_id })
}
