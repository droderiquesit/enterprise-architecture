# Datadog credentials come from the environment (DD_API_KEY / DD_APP_KEY), exported by tools/secrets/fetch.py from
# Delinea DSV in the pipeline job (environment.yaml datadog.api_key_secret_name / app_key_secret_name). Never in tfvars.
provider "datadog" {
  api_url = "https://api.${var.settings.datadog_site}/"
}
