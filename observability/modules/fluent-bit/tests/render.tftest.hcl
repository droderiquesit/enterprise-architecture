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
