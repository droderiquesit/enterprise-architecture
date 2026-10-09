locals {
  burn_alerts = merge([
    for k, s in var.slos : {
      for b in s.burn_rate_alerts : "${k}/${b.severity}-${b.long_window}" => merge(b, { slo_key = k, timeframe = s.timeframe, tags = s.tags })
    }
  ]...)
}

resource "datadog_service_level_objective" "this" {
  for_each = var.slos

  name        = each.value.display_name
  description = each.value.description
  type        = each.value.type == "availability" ? "metric" : "time_slice"
  tags        = sort(distinct(each.value.tags))

  thresholds {
    timeframe = each.value.timeframe
    target    = each.value.target
    warning   = each.value.warning
  }

  dynamic "query" {
    for_each = each.value.type == "availability" ? [1] : []
    content {
      numerator   = each.value.numerator
      denominator = each.value.denominator
    }
  }

  dynamic "sli_specification" {
    for_each = each.value.type == "latency" ? [each.value.time_slice] : []
    content {
      time_slice {
        comparator = sli_specification.value.comparator
        threshold  = sli_specification.value.threshold
        query {
          formula {
            formula_expression = "query1"
          }
          query {
            metric_query {
              name        = "query1"
              data_source = "metrics"
              query       = sli_specification.value.query
            }
          }
        }
      }
    }
  }
}

# Multi-window burn-rate alerts (https://docs.datadoghq.com/service_management/service_level_objectives/burn_rate/).
resource "datadog_monitor" "burn_rate" {
  for_each = local.burn_alerts

  name     = each.value.name
  type     = "slo alert"
  query    = "burn_rate(\"${datadog_service_level_objective.this[each.value.slo_key].id}\").over(\"${each.value.timeframe}\").long_window(\"${each.value.long_window}\").short_window(\"${each.value.short_window}\") > ${each.value.threshold}"
  message  = "${each.value.message}\n\n${join(" ", distinct(flatten([for r in each.value.notify.alert : lookup(var.route_handles, r, [])])))}"
  priority = each.value.severity == "critical" ? "2" : "3"
  tags     = sort(distinct(concat(each.value.tags, ["slo_alert:burn_rate", "severity:${each.value.severity}"])))

  monitor_thresholds {
    critical = tostring(each.value.threshold)
  }

  lifecycle {
    precondition {
      condition     = alltrue([for r in each.value.notify.alert : contains(keys(var.route_handles), r)])
      error_message = "Burn-rate alert ${each.key} references an undefined route key."
    }
  }
}
