output "commands" {
  description = "Service -> command line for send_deployment_event.py (expects DD_API_KEY, VERSION, COMMIT_SHA, DEPLOY_STARTED_AT in the environment)."
  value       = local.commands
}
