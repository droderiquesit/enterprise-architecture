output "contract" {
  description = "obs-kubernetes-aro v1 contract (catalog/contracts/obs-kubernetes-aro.v1.schema.json): the obs-kubernetes v2 shape with distribution = openshift; {enabled = false, status = blocked} while platform-aro is not enabled."
  # first element: the enabled contract when the release exists, else the blocked stub (tuple index keeps both shapes)
  value = concat(
    [for k in module.kubernetes : merge(k.contract, { enabled = true, status = "implemented", cluster_id = var.platform_aro.cluster_id })],
    [{ enabled = false, status = "blocked" }],
  )[0]
}
