locals {
  dir = "${path.module}/../../config/otel"

  configs = merge(
    { OTELCOL_CONFIG_BASE = file("${local.dir}/gateway.yaml") },
    var.bearer_auth ? { OTELCOL_CONFIG_AUTH = file("${local.dir}/gateway-auth.yaml") } : {},
    var.sampling == "tail" ? { OTELCOL_CONFIG_TAIL = file("${local.dir}/gateway-tail-sampling.yaml") } : {},
    var.fluentbit_metrics_target != null ? { OTELCOL_CONFIG_SCRAPE_FLB = file("${local.dir}/gateway-scrape-fluentbit.yaml") } : {},
    var.otlp_logs == "forward" ? { OTELCOL_CONFIG_LOGS_FORWARD = file("${local.dir}/gateway-logs-forward.yaml") } : {},
    local.tag_statements_any ? { OTELCOL_CONFIG_TAGS = yamlencode(local.tags_overlay) } : {},
  )

  # ------------------------------------------------------------------ tag policy overlay (transform/eh_tag_policy)
  default_stmts = [for k in sort(keys(var.default_attributes)) :
  "set(attributes[\"${k}\"], \"${replace(var.default_attributes[k], "\"", "")}\") where attributes[\"${k}\"] == nil"]
  service_stmts = flatten([for svc in sort(keys(var.service_attributes)) : [
    for k in sort(keys(var.service_attributes[svc])) :
    "set(attributes[\"${k}\"], \"${replace(var.service_attributes[svc][k], "\"", "")}\") where attributes[\"service.name\"] == \"${svc}\" and attributes[\"${k}\"] == nil"
  ]])
  resource_stmts = concat(local.default_stmts, local.service_stmts)
  datapoint_stmts = [for k in var.metric_attribute_keys :
  "set(attributes[\"${k}\"], resource.attributes[\"${k}\"]) where resource.attributes[\"${k}\"] != nil and attributes[\"${k}\"] == nil"]
  tag_statements_any = length(local.resource_stmts) + length(local.datapoint_stmts) > 0
  tags_overlay = {
    processors = {
      "transform/eh_tag_policy" = {
        error_mode       = "ignore"
        trace_statements = [{ context = "resource", statements = length(local.resource_stmts) > 0 ? local.resource_stmts : ["delete_key(attributes, \"eh.tag_policy.placeholder\")"] }]
        metric_statements = concat(
          [{ context = "resource", statements = length(local.resource_stmts) > 0 ? local.resource_stmts : ["delete_key(attributes, \"eh.tag_policy.placeholder\")"] }],
          length(local.datapoint_stmts) > 0 ? [{ context = "datapoint", statements = local.datapoint_stmts }] : [],
        )
        log_statements = [{ context = "resource", statements = length(local.resource_stmts) > 0 ? local.resource_stmts : ["delete_key(attributes, \"eh.tag_policy.placeholder\")"] }]
      }
    }
  }
  order = concat(["OTELCOL_CONFIG_BASE"], sort([for k in keys(local.configs) : k if k != "OTELCOL_CONFIG_BASE"]))
  args  = concat(var.distribution == "ddot" ? ["run"] : [], [for k in local.order : "--config=env:${k}"])

  env = merge(
    {
      DD_SITE                   = var.datadog_site
      DD_ENV                    = var.env
      DD_HOSTNAME               = var.hostname
      TRACE_SAMPLING_PERCENTAGE = tostring(var.sampling == "none" ? 100 : var.sampling_percentage)
      GATEWAY_MEMORY_LIMIT_MIB  = tostring(floor(var.memory_mib * 0.8))
      GATEWAY_MEMORY_SPIKE_MIB  = tostring(floor(var.memory_mib * 0.2))
      OTEL_RESOURCE_ATTRIBUTES  = "service.name=otel-gateway,deployment.environment.name=${var.env}"
    },
    var.fluentbit_metrics_target != null ? { FLUENTBIT_METRICS_TARGET = var.fluentbit_metrics_target } : {},
  )
  # secret FILES read by the config (${file:...}); dsv-fetch init --format files writes them from Delinea DSV
  secret_files = concat(["dd-api-key"], var.bearer_auth ? ["otlp-bearer-token"] : [])
  secrets_dir  = "/dsv-secrets"
  image        = var.distribution == "ddot" ? var.images.ddot : var.images.upstream
}

check "ddot_has_no_bearertokenauth" {
  assert {
    condition     = !(var.distribution == "ddot" && var.bearer_auth)
    error_message = "DDOT does not include the bearertokenauth extension; use distribution = upstream for OTLP auth."
  }
}
