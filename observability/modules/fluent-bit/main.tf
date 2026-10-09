locals {
  dir = "${path.module}/../../config/fluent-bit"

  main_file = {
    sidecar              = "sidecar.yaml"
    "sidecar-forward"    = "sidecar-forward.yaml"
    aggregator           = "aggregator.yaml"
    "aggregator-forward" = "aggregator-forward.yaml"
    "k8s-daemonset"      = "k8s-daemonset.yaml"
    "linux-host"         = "linux-host.yaml"
    "windows-host"       = "windows-host.yaml"
  }[var.role]

  is_host = contains(["linux-host", "windows-host"], var.role)

  extra_include = var.role == "linux-host" && var.systemd_unit != null ? file("${local.dir}/linux-host-systemd.yaml") : (
    var.role == "windows-host" && var.windows_event_log ? file("${local.dir}/windows-host-winevtlog.yaml") : file("${local.dir}/inputs-extra.yaml")
  )

  # files keyed by their path relative to the config directory (the main config is always fluent-bit.yaml)
  files = merge(
    {
      "fluent-bit.yaml"          = file("${local.dir}/${local.main_file}")
      "parsers.yaml"             = file("${local.dir}/parsers.yaml")
      "lua/enterprise_hello.lua" = file("${local.dir}/lua/enterprise_hello.lua")
    },
    local.is_host ? { "inputs-extra.yaml" = local.extra_include } : {},
  )

  default_state_dir = {
    sidecar              = "/var/log/app/.flb"
    "sidecar-forward"    = "/var/log/app/.flb"
    aggregator           = "/var/fluent-bit/state"
    "aggregator-forward" = "/var/fluent-bit/state"
    "k8s-daemonset"      = "/var/fluent-bit/state"
    "linux-host"         = "/var/lib/fluent-bit-eh"
    "windows-host"       = "C:\\ProgramData\\fluent-bit-eh\\state"
  }[var.role]

  tags_string = join(",", [for k in sort(keys(var.static_tags)) : "${k}:${var.static_tags[k]}"])

  env = merge(
    {
      FLB_STATE_DIR = coalesce(var.state_dir, local.default_state_dir)
      FLB_DD_HOST   = "http-intake.logs.${var.datadog_site}"
      FLB_DD_PORT   = "443"
      FLB_DD_TLS    = var.tls ? "on" : "off"
      FLB_DD_TAGS   = local.tags_string
    },
    var.dd_source != null ? { FLB_DD_SOURCE = var.dd_source } : {},
    var.dd_service != null ? { FLB_DD_SERVICE = var.dd_service } : {},
    contains(["aggregator", "aggregator-forward", "k8s-daemonset", "linux-host", "windows-host"], var.role) ? { FLB_CANARY_INTERVAL_SEC = tostring(var.canary_interval_seconds) } : {},
    # self-metrics pushed over OTLP/HTTP to the node/host Agent (k8s: DD_AGENT_HOST from status.hostIP)
    contains(["k8s-daemonset", "linux-host", "windows-host"], var.role) ? {
      FLB_METRICS_INTERVAL_SEC = "60"
      FLB_OTLP_HOST            = var.role == "k8s-daemonset" ? "$(DD_AGENT_HOST)" : "127.0.0.1"
      FLB_ENV                  = lookup(var.static_tags, "env", "unknown")
    } : {},
    local.is_host ? { FLB_LOG_PATHS = join(",", var.log_paths) } : {},
    var.role == "aggregator" ? { FLB_ACA_CONSOLE_ALLOW = join(",", var.aca_console_allow) } : {},
    var.role == "linux-host" && var.systemd_unit != null ? { FLB_SYSTEMD_UNIT = var.systemd_unit } : {},
    var.role == "k8s-daemonset" ? {
      FLB_EXCLUDE_PATHS = join(",", [for ns in var.exclude_namespaces : "/var/log/containers/*_${ns}_*.log"])
      FLB_THROTTLE_RATE = tostring(var.throttle_rate)
    } : {},
  )

  # Secret env vars: written by dsv-fetch (Delinea DSV) into the env-yaml file the config includes
  # (never container env / platform secrets). Path per role (container roles share /dsv-secrets).
  secrets_env_file = {
    "linux-host"   = "/run/fluent-bit-eh/fluentbit-env.yaml"
    "windows-host" = "C:/ProgramData/fluent-bit-eh/secrets/fluentbit-env.yaml"
  }
  secrets_file = lookup(local.secrets_env_file, var.role, "/dsv-secrets/fluentbit-env.yaml")

  secret_env = concat(
    contains(["sidecar-forward"], var.role) ? ["FLB_FORWARD_SHARED_KEY"] : ["DD_API_KEY"],
    contains(["aggregator", "aggregator-forward"], var.role) ? ["FLB_FORWARD_SHARED_KEY"] : [],
    var.role == "aggregator" ? ["EVENTHUB_CONNECTION_STRING"] : [],
  )
}
