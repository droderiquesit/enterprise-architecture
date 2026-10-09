output "contract" {
  description = "obs-telemetry-transport v2 (catalog/contracts/obs-telemetry-transport.v2.schema.json). DSV references only."
  value       = merge(module.transport.contract, { batch_log_setup = local.batch_log_setup })
}

output "generated_secrets" {
  description = <<-EOT
    Secret values Azure generated in this apply that belong in Delinea DSV: {"eventhub-fluentbit-listen" = <Listen
    connection string>}. SENSITIVE; consumed only by tools/secrets/publish.py (writes them to
    dsv://<base_path>/<name>), never published in the contract. Empty unless settings.event_hub_mode = create.
  EOT
  sensitive   = true
  value       = module.transport.generated_secrets
}
