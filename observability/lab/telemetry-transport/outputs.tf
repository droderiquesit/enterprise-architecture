output "contract" {
  description = "obs-telemetry-transport v3 (catalog/contracts/obs-telemetry-transport.v3.schema.json). DSV references only."
  value       = merge(module.transport.contract, { batch_log_setup = local.batch_log_setup })
  precondition {
    condition     = !local.batch_needs_key || (local.batch_dsv_fetch.url != null && can(regex("^[a-f0-9]{64}$", coalesce(local.batch_dsv_fetch.sha256, "x"))))
    error_message = "Batch log setup with log_pipeline = fluent_bit_direct needs the dsv-fetch release zip on the nodes: artifacts[\"img-dsv-fetch\"].package_url + package_sha256 (tools/deploy/artifacts.py tfvars)."
  }
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
