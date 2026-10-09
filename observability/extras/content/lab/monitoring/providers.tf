# Datadog credentials from DD_API_KEY / DD_APP_KEY (pipeline: Key Vault -> environment). Never in tfvars.
provider "datadog" {
  api_url = "https://api.${var.obs_prereqs.datadog_site}/"
}
