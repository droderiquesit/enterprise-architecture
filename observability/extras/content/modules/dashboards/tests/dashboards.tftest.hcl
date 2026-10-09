mock_provider "datadog" {}

variables {
  services = {
    api = {
      env                    = "prod", team = "shop", architecture = "aca", traces_enabled = true, runbook_url = "https://rb/api"
      workflow_metric_prefix = "app"
      resources = [
        { role = "db", type = "Microsoft.Sql/servers/databases", scope = "subscription_id:s,resource_group:rg,server_name:srv,name:db" },
        { role = "bus", type = "Microsoft.ServiceBus/namespaces", scope = "subscription_id:s,resource_group:rg,name:sb" },
      ]
    }
  }
  overview = { title = "[prod] overview", env = "prod", journey = ["api"] }
}

run "renders_valid_json_with_sections" {
  command = plan

  assert {
    condition     = jsondecode(output.rendered["api"]).layout_type == "ordered"
    error_message = "service dashboard must be valid JSON"
  }
  assert {
    condition     = length(jsondecode(output.rendered["__overview__"]).widgets) == 4
    error_message = "overview has journey, databases, queues/durable and pipeline sections"
  }
  assert {
    condition     = strcontains(output.rendered["__overview__"], "server_name:srv") && strcontains(output.rendered["__overview__"], "fluentbit_output_errors_total")
    error_message = "overview contains DB and pipeline sections"
  }
  assert {
    condition     = strcontains(output.rendered["api"], "app.workflow.completed")
    error_message = "durable workflow widgets expected"
  }
}
