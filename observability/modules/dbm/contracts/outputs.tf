output "databases" {
  description = "modules/dbm `databases` input (no secrets: passwords are dsv:// references)."
  value       = local.databases
}
