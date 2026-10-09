output "contract" {
  description = "obs-telemetry-transport v1 (catalog/contracts/obs-telemetry-transport.v1.schema.json)."
  value       = merge(module.transport.contract, { batch_log_setup = local.batch_log_setup })
}
