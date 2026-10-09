run "renders_commands" {
  command = plan
  variables {
    services     = { api = { env = "prod", team = "shop" } }
    datadog_site = "datadoghq.eu"
  }
  assert {
    condition     = strcontains(output.commands["api"], "--site datadoghq.eu --service api --env prod --team shop")
    error_message = "command must carry site/service/env/team"
  }
}
