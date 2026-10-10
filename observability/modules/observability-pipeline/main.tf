# Datadog Observability Pipelines: the central, Datadog-managed log pipeline of the package (fleet policy
# log_pipeline = observability_pipelines). The pipeline DEFINITION is a Datadog object (datadog_observability_pipeline);
# the Worker that runs it is deployed by modules/telemetry-transport (Container Apps) or modules/kubernetes (Helm) with
# the env contract output here. Graph:
#   fluent_bit (24224) + datadog_agent (8282) [+ opentelemetry] -> group "app": normalise JSON, redact, tag policy
#   eventhub (Kafka 9093)                                        -> group "azure": unwrap batch, split records,
#                                                                   Datadog-forwarder shape, drop duplicates/foreign
#                                                                   categories, dedupe, sample, quota, tag policy
#   both groups -> datadog_logs (disk buffer) [+ azure_storage archive]
locals {
  dir = "${path.module}/../../config/observability-pipelines"
  eh  = try(var.sources.eventhub, null) != null ? try(var.sources.eventhub.enabled, true) : false

  policy    = [for p in [var.tag_policy, yamldecode(file("${path.module}/../../config/tag-policy.yaml"))] : p if p != null][0]
  pkeys     = local.policy.keys
  aliases   = { for k, s in local.pkeys : try(tostring(s.key), k) => try(tolist(s.aliases), []) if length(try(tolist(s.aliases), [])) > 0 }
  value_map = { for k, s in local.pkeys : try(tostring(s.key), k) => { for f, t in try(s.value_map, {}) : lower(f) => tostring(t) } if length(try(s.value_map, {})) > 0 }
  azure_tag_key_map = merge(concat([{}], [for k, s in local.pkeys : {
    for az in distinct([for a in try(tolist(s.azure_tag_keys), [try(tostring(s.key), k)]) : lower(a)]) : az => distinct(concat([try(tostring(s.key), k)], try(tolist(s.aliases), [])))
  }])...)

  defaults = merge({ env = var.env }, var.default_tags)
  cfg_tags = jsonencode({
    defaults     = local.defaults
    aliases      = local.aliases
    value_map    = local.value_map
    pipeline_tag = "telemetry.pipeline:observability-pipelines"
  })
  cfg_azure = jsonencode({
    app_topic         = try(var.sources.eventhub.app_topic, "app-logs")
    azure_service     = var.azure.service
    aca_allow         = var.azure.aca_console_allow
    tag_key_map       = local.azure_tag_key_map
    scope_tags        = { for k, v in var.azure.scope_tags : lower(trimsuffix(k, "/")) => v }
    static_tags       = var.azure.static_tags
    max_message_bytes = var.azure.max_message_bytes
    forwarder         = "observability-pipelines"
  })
  vrl = {
    app          = "cfg = {}\n${file("${local.dir}/app.vrl")}"
    tags         = "cfg = ${local.cfg_tags}\n${file("${local.dir}/tags.vrl")}"
    azure_unwrap = "cfg = {}\n${file("${local.dir}/azure_unwrap.vrl")}"
    azure_shape  = "cfg = ${local.cfg_azure}\n${file("${local.dir}/azure_shape.vrl")}"
  }

  # eh_redact equivalents (keys and free text); RE2-compatible, case-insensitive
  redaction_patterns = merge({
    "secret-key-value" = "(?i)(password|passwd|pwd|secret|token|api[_-]?key|accountkey|sharedaccesskey|sharedaccesssignature|connectionstring|connection_string|client_secret)[\"']?\\s*[=:]\\s*[\"']?[^\\s,;\"'&]+"
    "bearer-token"     = "(?i)bearer\\s+[A-Za-z0-9._~+/=-]+"
    "sas-signature"    = "(?i)sig=[A-Za-z0-9%+/=]+"
    "storage-key"      = "(?i)accountkey=[A-Za-z0-9+/=]+"
  }, var.redaction.extra_patterns)

  app_inputs = concat(
    var.sources.fluent_bit ? ["fluent"] : [],
    var.sources.datadog_agent ? ["agent"] : [],
    var.sources.opentelemetry ? ["otlp"] : [],
  )
  dest_inputs = concat(length(local.app_inputs) > 0 ? ["app"] : [], local.eh ? ["azure"] : [])

  worker_script = join("; ", [
    "set -eu",
    "f=/dsv-secrets/opw.env",
    "i=0",
    "while [ ! -s \"$f\" ]; do i=$((i+1)); if [ $i -gt 60 ]; then echo 'opw: dsv-fetch secrets file missing - refusing to start' >&2; exit 1; fi; sleep 2; done",
    "set -a",
    ". \"$f\"",
    "set +a",
    "h=$${HOSTNAME:-opw}",
    "export VECTOR_HOSTNAME=\"$h\"",
    "d=\"$${DD_OP_DATA_DIR_BASE:-/var/lib/observability-pipelines-worker}/$h\"",
    "mkdir -p \"$d\"",
    "export DD_OP_DATA_DIR=\"$d\"",
    "exec /usr/bin/observability-pipelines-worker run",
  ])
}

resource "datadog_observability_pipeline" "this" {
  name = var.name

  config {
    pipeline_type = "logs"

    # ------------------------------------------------------------------ sources
    dynamic "source" {
      for_each = var.sources.fluent_bit ? [1] : []
      content {
        id = "fluent"
        fluent_bit {
          address_key = "DD_OP_SOURCE_FLUENT_ADDRESS"
          dynamic "tls" {
            for_each = var.fluent_tls == null ? [] : [var.fluent_tls]
            content {
              crt_file = tls.value.crt_file
              key_file = tls.value.key_file
              ca_file  = tls.value.ca_file
            }
          }
        }
      }
    }
    dynamic "source" {
      for_each = var.sources.datadog_agent ? [1] : []
      content {
        id = "agent"
        datadog_agent {
          address_key = "DD_OP_SOURCE_DATADOG_AGENT_ADDRESS"
        }
      }
    }
    dynamic "source" {
      for_each = var.sources.opentelemetry ? [1] : []
      content {
        id = "otlp"
        opentelemetry {
          grpc_address_key = "DD_OP_SOURCE_OTEL_GRPC_ADDRESS"
          http_address_key = "DD_OP_SOURCE_OTEL_HTTP_ADDRESS"
        }
      }
    }
    dynamic "source" {
      for_each = local.eh ? [var.sources.eventhub] : []
      content {
        id = "eventhubs"
        kafka {
          bootstrap_servers_key = "DD_OP_SOURCE_KAFKA_BOOTSTRAP_SERVERS"
          group_id              = source.value.group_id
          topics                = source.value.topics
          sasl {
            mechanism    = "PLAIN"
            username_key = "DD_OP_SOURCE_KAFKA_SASL_USERNAME"
            password_key = "DD_OP_SOURCE_KAFKA_SASL_PASSWORD"
          }
          # Event Hubs Kafka endpoint: SASL_SSL with the server certificate only (no client certificate)
          librdkafka_option {
            name  = "security.protocol"
            value = "sasl_ssl"
          }
          librdkafka_option {
            name  = "session.timeout.ms"
            value = "30000"
          }
        }
      }
    }

    # ------------------------------------------------------------------ application logs
    dynamic "processor_group" {
      for_each = length(local.app_inputs) > 0 ? [1] : []
      content {
        id           = "app"
        display_name = "Application logs: normalise, redact, tag policy"
        enabled      = true
        include      = "*"
        inputs       = local.app_inputs

        processor {
          id      = "app-normalise"
          enabled = true
          include = "*"
          custom_processor {
            remap {
              name          = "normalise"
              enabled       = true
              include       = "*"
              drop_on_error = false
              source        = local.vrl.app
            }
          }
        }
        dynamic "processor" {
          for_each = var.redaction.enabled ? [1] : []
          content {
            id      = "app-redact"
            enabled = true
            include = "*"
            sensitive_data_scanner {
              dynamic "rule" {
                for_each = local.redaction_patterns
                content {
                  name = rule.key
                  tags = ["redaction:${rule.key}"]
                  pattern {
                    custom {
                      rule        = rule.value
                      description = "eh_redact equivalent: ${rule.key}"
                    }
                  }
                  scope {
                    all = true
                  }
                  on_match {
                    redact {
                      replace = "[REDACTED]"
                    }
                  }
                }
              }
            }
          }
        }
        processor {
          id      = "app-tags"
          enabled = true
          include = "*"
          custom_processor {
            remap {
              name          = "tag-policy"
              enabled       = true
              include       = "*"
              drop_on_error = false
              source        = local.vrl.tags
            }
          }
        }
      }
    }

    # ------------------------------------------------------------------ Azure Event Hubs (platform / activity / console)
    dynamic "processor_group" {
      for_each = local.eh ? [1] : []
      content {
        id           = "azure"
        display_name = "Azure platform logs: Datadog Azure forwarder shape"
        enabled      = true
        include      = "*"
        inputs       = ["eventhubs"]

        processor {
          id      = "azure-unwrap"
          enabled = true
          include = "*"
          custom_processor {
            remap {
              name          = "unwrap-batch"
              enabled       = true
              include       = "*"
              drop_on_error = false
              source        = local.vrl.azure_unwrap
            }
          }
        }
        processor {
          id      = "azure-split"
          enabled = true
          include = "*"
          split_array {
            array {
              field   = "records"
              include = "*"
            }
          }
        }
        processor {
          id      = "azure-shape"
          enabled = true
          include = "*"
          custom_processor {
            remap {
              name          = "forwarder-shape"
              enabled       = true
              include       = "*"
              drop_on_error = false
              source        = local.vrl.azure_shape
            }
          }
        }
        # application categories on a non-app hub and sidecar-collected Container Apps console lines
        processor {
          id      = "azure-drop-duplicates"
          enabled = true
          include = "-@eh_drop:true"
          filter {}
        }
        # Event Hubs is at-least-once: redeliveries after a rebalance carry the same identity
        dynamic "processor" {
          for_each = var.azure.dedupe ? [1] : []
          content {
            id      = "azure-dedupe"
            enabled = true
            include = "@correlationId:*"
            dedupe {
              fields = ["time", "resourceId", "category", "operationName", "resultType", "correlationId", "properties.eventDataId", "properties.id"]
              mode   = "match"
            }
          }
        }
        dynamic "processor" {
          for_each = var.azure.sample_categories
          content {
            id      = "azure-sample-${lower(replace(processor.key, "/[^A-Za-z0-9]/", "-"))}"
            enabled = true
            include = "@category:${processor.key}"
            sample {
              percentage = processor.value
            }
          }
        }
        dynamic "processor" {
          for_each = var.azure.daily_quota_bytes > 0 ? [1] : []
          content {
            id      = "azure-quota"
            enabled = true
            include = "*"
            quota {
              name                           = "azure-category-daily"
              overflow_action                = "drop"
              partition_fields               = ["category"]
              ignore_when_missing_partitions = true
              limit {
                enforce = "bytes"
                limit   = var.azure.daily_quota_bytes
              }
            }
          }
        }
        processor {
          id      = "azure-tags"
          enabled = true
          include = "*"
          custom_processor {
            remap {
              name          = "tag-policy"
              enabled       = true
              include       = "*"
              drop_on_error = false
              source        = local.vrl.tags
            }
          }
        }
      }
    }

    # ------------------------------------------------------------------ destinations
    destination {
      id     = "datadog-logs"
      inputs = local.dest_inputs
      datadog_logs {
        buffer {
          disk {
            max_size  = var.buffer.disk_max_bytes
            when_full = var.buffer.when_full
          }
        }
      }
    }
    dynamic "destination" {
      for_each = var.archive.enabled ? [1] : []
      content {
        id     = "azure-archive"
        inputs = local.dest_inputs
        azure_storage {
          container_name        = var.archive.container_name
          blob_prefix           = var.archive.blob_prefix
          connection_string_key = "DD_OP_DESTINATION_DATADOG_ARCHIVES_AZURE_BLOB_CONNECTION_STRING"
          buffer {
            disk {
              max_size  = var.buffer.disk_max_bytes
              when_full = var.buffer.when_full
            }
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.dest_inputs) > 0
      error_message = "The pipeline needs at least one source (fluent_bit, datadog_agent, opentelemetry or eventhub)."
    }
    precondition {
      condition     = !local.eh || var.eventhub_bootstrap != null
      error_message = "sources.eventhub needs eventhub_bootstrap (<namespace>.servicebus.windows.net:9093)."
    }
    precondition {
      condition     = !local.eh || try(var.secret_refs.eventhub_connection_string, null) != null
      error_message = "sources.eventhub needs secret_refs.eventhub_connection_string (Event Hubs Listen connection string in DSV)."
    }
    precondition {
      condition     = !var.archive.enabled || try(var.secret_refs.archive_connection_string, null) != null
      error_message = "archive.enabled needs secret_refs.archive_connection_string."
    }
  }
}
