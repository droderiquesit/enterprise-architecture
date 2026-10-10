run "upstream_default" {
  command = plan
  variables {
    env = "dev"
  }
  assert {
    condition     = output.image == "otel/opentelemetry-collector-contrib:0.162.0" && jsonencode(output.args) == jsonencode(["--config=env:OTELCOL_CONFIG_BASE"])
    error_message = "Upstream image with the base config only."
  }
  assert {
    condition     = output.env["GATEWAY_MEMORY_LIMIT_MIB"] == "819" && output.env["TRACE_SAMPLING_PERCENTAGE"] == "100"
    error_message = "Memory limiter derived from container memory."
  }
  assert {
    condition     = strcontains(output.config_env["OTELCOL_CONFIG_BASE"], "exporters: [nop]") && !contains(keys(output.config_env), "OTELCOL_CONFIG_LOGS_FORWARD")
    error_message = "OTLP logs are accepted and dropped by default (app logs only via Fluent Bit)."
  }
}

run "ddot_tail_scrape" {
  command = plan
  variables {
    env                      = "dev"
    distribution             = "ddot"
    sampling                 = "tail"
    sampling_percentage      = 10
    fluentbit_metrics_target = "ca-flb:2020"
  }
  assert {
    condition     = jsonencode(output.args) == jsonencode(["run", "--config=env:OTELCOL_CONFIG_BASE", "--config=env:OTELCOL_CONFIG_SCRAPE_FLB", "--config=env:OTELCOL_CONFIG_TAIL"])
    error_message = "DDOT run sub-command with deterministic overlay order."
  }
}

run "ddot_with_auth_is_flagged" {
  command = plan
  variables {
    env          = "dev"
    distribution = "ddot"
    bearer_auth  = true
  }
  expect_failures = [check.ddot_has_no_bearertokenauth]
}

run "logs_forward_opt_in" {
  command = plan
  variables {
    env       = "dev"
    otlp_logs = "forward"
  }
  assert {
    condition     = contains(output.args, "--config=env:OTELCOL_CONFIG_LOGS_FORWARD")
    error_message = "Forward overlay only when opted in."
  }
}

run "reject_bad_logs_mode" {
  command = plan
  variables {
    env       = "dev"
    otlp_logs = "keep"
  }
  expect_failures = [var.otlp_logs]
}

run "tag_policy_overlay" {
  command = plan
  variables {
    default_attributes    = { "deployment.environment.name" = "dev", region = "swedencentral" }
    service_attributes    = { "hello-inventory-api" = { team = "orders", owner = "orders_example.com" } }
    metric_attribute_keys = ["team", "region"]
  }
  assert {
    condition     = contains(output.config_env_order, "OTELCOL_CONFIG_TAGS") && strcontains(output.config_env["OTELCOL_CONFIG_TAGS"], "where attributes[\\\"service.name\\\"] == \\\"hello-inventory-api\\\" and attributes[\\\"team\\\"] == nil")
    error_message = "per-service tag insertion without overwriting client values"
  }
  assert {
    condition     = strcontains(output.config_env["OTELCOL_CONFIG_TAGS"], "context\": \"datapoint\"") && strcontains(output.config_env["OTELCOL_CONFIG_TAGS"], "set(attributes[\\\"region\\\"], resource.attributes[\\\"region\\\"])")
    error_message = "policy keys copied to metric data points"
  }
}
