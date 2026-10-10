# The RUM client token is the credential Datadog designs for end-user facing (browser) apps: "end user facing
# applications use client tokens to send data to Datadog", whereas API keys "cannot be used to send data from a
# browser ... as they would be exposed client-side" (https://docs.datadoghq.com/account_management/api-app-keys/#client-tokens).
# Every visitor of the frontend downloads it in config.json, so it is output non-sensitive and may appear in the
# obs-prereqs contract. Rotation = recreate the RUM application (or a client token) and redeploy the frontend.
# API keys and application keys are never handled by this module.
output "applications" {
  description = "Key -> {application_id, client_token, name, type, mode}."
  value       = local.apps
}

output "browser_config" {
  description = "Key -> Datadog Browser RUM SDK init (datadogRum.init options + globalContext) for the frontend's runtime config."
  value       = local.browser_config
}
