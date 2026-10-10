run "k8s_daemonset" {
  command = plan
  variables {
    role         = "k8s-daemonset"
    datadog_site = "us5.datadoghq.com"
    static_tags  = { env = "dev", kube_cluster_name = "aks-eh-dev" }
  }
  assert {
    condition     = output.env["FLB_EXCLUDE_PATHS"] == "/var/log/containers/*_kube-system_*.log,/var/log/containers/*_datadog_*.log,/var/log/containers/*_fluent-bit_*.log,/var/log/containers/*_gatekeeper-system_*.log,/var/log/containers/*_calico-system_*.log,/var/log/containers/*_tigera-operator_*.log"
    error_message = "Excluded namespaces become tail exclude_path globs."
  }
  assert {
    condition     = output.env["FLB_DD_HOST"] == "http-intake.logs.us5.datadoghq.com" && output.env["FLB_DD_TLS"] == "on" && output.env["FLB_DD_TAGS"] == "env:dev,kube_cluster_name:aks-eh-dev"
    error_message = "Site intake, TLS and tags."
  }
  assert {
    condition     = strcontains(output.main_config, "/var/log/containers/*.log") && contains(keys(output.files), "lua/enterprise_hello.lua")
    error_message = "Daemonset config and lua shipped."
  }
}

run "linux_host_with_journald" {
  command = plan
  variables {
    role         = "linux-host"
    log_paths    = ["/var/log/enterprise-hello/*.log"]
    systemd_unit = "hello-worker.service"
  }
  assert {
    condition     = strcontains(output.files["inputs-extra.yaml"], "name: systemd") && output.env["FLB_LOG_PATHS"] == "/var/log/enterprise-hello/*.log"
    error_message = "journald add-on installed as inputs-extra.yaml."
  }
}

run "windows_host_default" {
  command = plan
  variables {
    role      = "windows-host"
    log_paths = ["C:\\ProgramData\\enterprise-hello\\logs\\*.log"]
  }
  assert {
    condition     = strcontains(output.files["inputs-extra.yaml"], "inputs: []") && output.env["FLB_STATE_DIR"] == "C:\\ProgramData\\fluent-bit-eh\\state"
    error_message = "Windows default: no winevtlog, Windows state dir."
  }
}

run "aggregator_secrets" {
  command = plan
  variables {
    role = "aggregator"
  }
  assert {
    condition     = contains(output.secret_env_names, "EVENTHUB_CONNECTION_STRING") && contains(output.secret_env_names, "DD_API_KEY")
    error_message = "Aggregator secret env names."
  }
  assert {
    condition     = output.secrets_env_file == "/dsv-secrets/fluentbit-env.yaml" && strcontains(output.main_config, "- /dsv-secrets/fluentbit-env.yaml") && strcontains(output.main_config, "apikey: $${DD_API_KEY}")
    error_message = "Aggregator config includes the dsv-fetch env file and keeps $${DD_API_KEY}."
  }
}

run "host_secret_files" {
  command = plan
  variables {
    role      = "linux-host"
    log_paths = ["/var/log/app/*.log"]
  }
  assert {
    condition     = output.secrets_env_file == "/run/fluent-bit-eh/fluentbit-env.yaml" && strcontains(output.main_config, "- /run/fluent-bit-eh/fluentbit-env.yaml")
    error_message = "Linux hosts include the tmpfs env file written by ExecStartPre."
  }
}

run "reject_tls_off" {
  command = plan
  variables {
    role = "sidecar"
    tls  = false
  }
  expect_failures = [var.tls]
}

run "reject_unknown_role" {
  command = plan
  variables {
    role = "lambda"
  }
  expect_failures = [var.role]
}

run "sidecar_to_observability_pipelines" {
  command = plan
  variables {
    role            = "sidecar"
    log_destination = "observability_pipelines"
    op_endpoint     = { host = "eh-obs-dev-opw", port = 24224 }
    static_tags     = { env = "dev", service = "hello-orders-api", team = "orders" }
  }
  assert {
    condition     = strcontains(output.main_config, "- name: forward") && !strcontains(output.main_config, "- name: datadog") && !strcontains(output.main_config, "apikey")
    error_message = "datadog output replaced by the Worker forward output"
  }
  assert {
    condition     = !strcontains(output.main_config, "  - /dsv-secrets/fluentbit-env.yaml") && strcontains(output.main_config, "  - parsers.yaml") && length(output.secret_env_names) == 0
    error_message = "no secret on the edge: dsv-fetch include removed"
  }
  assert {
    condition     = output.env["FLB_FORWARD_HOST"] == "eh-obs-dev-opw" && output.env["FLB_FORWARD_PORT"] == "24224" && output.env["FLB_DD_TAGS"] == "env:dev,service:hello-orders-api,team:orders"
    error_message = "forward endpoint env + policy tags"
  }
  assert {
    condition     = strcontains(output.main_config, "require_ack_response: true") && strcontains(output.main_config, "retry_limit: no_limits")
    error_message = "acknowledged delivery, no retry limit (filesystem buffered)"
  }
}

run "daemonset_label_map_and_aggregator_azure_maps" {
  command = plan
  variables {
    role           = "k8s-daemonset"
    k8s_label_tags = { team = "team", "cost_center" = "cost_center" }
  }
  assert {
    condition     = output.env["FLB_K8S_LABEL_TAGS"] == "cost_center=cost_center,team=team"
    error_message = "pod label -> tag map from the policy"
  }
}

run "aggregator_azure_tag_and_scope_maps" {
  command = plan
  variables {
    role              = "aggregator"
    azure_tag_key_map = { environment = ["env"], costcenter = ["cost_center"] }
    azure_scope_tags  = { "/subscriptions/00000000-0000-0000-0000-000000000000" = { env = "dev", team = "platform" } }
  }
  assert {
    condition     = output.env["FLB_AZURE_TAG_MAP"] == "costcenter=cost_center,environment=env" && output.env["FLB_AZURE_SCOPE_TAGS"] == "/subscriptions/00000000-0000-0000-0000-000000000000=env:dev;team:platform"
    error_message = "Azure tag key map and scope tags env"
  }
}
