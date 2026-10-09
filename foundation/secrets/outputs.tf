output "dsv_desired_state" {
  description = "Desired Delinea DSV state (non-sensitive: names, identity resource ids, paths). Converged by tools/secrets/dsv_apply.py."
  value       = local.desired_state
}
