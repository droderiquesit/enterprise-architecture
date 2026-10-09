# Dashboards are rendered from JSON templates (templates/*.json.tftpl) with widget lists built here, and
# applied with datadog_dashboard_json. Widget queries use only metric names documented in tests/content
# fixtures (Azure integration, trace metrics, collector/Fluent Bit metrics).
locals {
  # Azure resource type -> widgets (title, query with [[scope]]).
  resource_widgets = {
    "microsoft.sql/servers/databases" = [
      { title = "SQL CPU %", q = "avg:azure.sql_servers_databases.cpu_percent{[[scope]]}" },
      { title = "SQL failed connections", q = "sum:azure.sql_servers_databases.connection_failed{[[scope]]}.as_count()" },
      { title = "SQL deadlocks", q = "sum:azure.sql_servers_databases.deadlock{[[scope]]}.as_count()" },
    ]
    "microsoft.sql/managedinstances" = [
      { title = "SQL MI CPU %", q = "avg:azure.sql_managedinstances.avg_cpu_percent{[[scope]]}" },
    ]
    "microsoft.dbforpostgresql/flexibleservers" = [
      { title = "PostgreSQL CPU %", q = "avg:azure.dbforpostgresql_flexibleservers.cpu_percent{[[scope]]}" },
      { title = "PostgreSQL active connections", q = "avg:azure.dbforpostgresql_flexibleservers.active_connections{[[scope]]}" },
      { title = "PostgreSQL failed connections", q = "sum:azure.dbforpostgresql_flexibleservers.connections_failed{[[scope]]}.as_count()" },
    ]
    "microsoft.dbformysql/flexibleservers" = [
      { title = "MySQL CPU %", q = "avg:azure.dbformysql_flexibleservers.cpu_percent{[[scope]]}" },
      { title = "MySQL active connections", q = "avg:azure.dbformysql_flexibleservers.active_connections{[[scope]]}" },
    ]
    "microsoft.documentdb/databaseaccounts" = [
      { title = "Cosmos normalized RU %", q = "max:azure.cosmosdb.normalized_ru_consumption{[[scope]]}" },
      { title = "Cosmos requests", q = "sum:azure.cosmosdb.total_requests{[[scope]]}.as_count()" },
    ]
    "microsoft.servicebus/namespaces" = [
      { title = "Service Bus active messages (subscriptions)", q = "max:azure.servicebus_namespaces.count_of_active_messages_in_a_topic_subscription{[[scope]]} by {entityname}" },
      { title = "Service Bus dead-lettered (subscriptions)", q = "max:azure.servicebus_namespaces.count_of_dead_lettered_messages_in_a_topic_subscription{[[scope]]} by {entityname}" },
      { title = "Service Bus active messages (queues)", q = "max:azure.servicebus_namespaces.count_of_active_messages_in_a_queue_topic{[[scope]]} by {entityname}" },
      { title = "Service Bus incoming vs outgoing", q = "sum:azure.servicebus_namespaces.incoming_messages{[[scope]]}.as_count(), sum:azure.servicebus_namespaces.outgoing_messages{[[scope]]}.as_count()" },
    ]
    "microsoft.eventhub/namespaces" = [
      { title = "Event Hubs incoming/outgoing", q = "sum:azure.eventhub_namespaces.incoming_messages{[[scope]]}.as_count(), sum:azure.eventhub_namespaces.outgoing_messages{[[scope]]}.as_count()" },
      { title = "Event Hubs throttled", q = "sum:azure.eventhub_namespaces.throttled_requests{[[scope]]}.as_count()" },
    ]
    "microsoft.cache/redisenterprise" = [
      { title = "Managed Redis server load %", q = "avg:azure.cache_redisenterprise.server_load{[[scope]]}" },
      { title = "Managed Redis memory %", q = "avg:azure.cache_redisenterprise.usedmemorypercentage{[[scope]]}" },
      { title = "Managed Redis hits/misses", q = "sum:azure.cache_redisenterprise.cachehits{[[scope]]}.as_count(), sum:azure.cache_redisenterprise.cachemisses{[[scope]]}.as_count()" },
    ]
    "microsoft.cache/redis" = [
      { title = "Redis server load %", q = "avg:azure.cache_redis.server_load{[[scope]]}" },
      { title = "Redis memory %", q = "avg:azure.cache_redis.usedmemorypercentage{[[scope]]}" },
    ]
    "microsoft.app/containerapps" = [
      { title = "Container App requests by status", q = "sum:azure.app_containerapps.requests{[[scope]]} by {statuscodecategory}.as_count()" },
      { title = "Container App replicas", q = "avg:azure.app_containerapps.replicas{[[scope]]}" },
      { title = "Container App restarts", q = "sum:azure.app_containerapps.restart_count{[[scope]]}.as_count()" },
    ]
    "microsoft.web/sites" = [
      { title = "App Service requests / 5xx", q = "sum:azure.app_services.requests{[[scope]]}.as_count(), sum:azure.app_services.http5xx{[[scope]]}.as_count()" },
      { title = "App Service response time (s)", q = "avg:azure.app_services.response_time{[[scope]]}" },
    ]
    "microsoft.web/sites#functions" = [
      { title = "Function executions", q = "sum:azure.functions.function_execution_count{[[scope]]}.as_count()" },
      { title = "Function HTTP 5xx", q = "sum:azure.functions.http5xx{[[scope]]}.as_count()" },
    ]
    "microsoft.containerinstance/containergroups" = [
      { title = "Container group CPU", q = "avg:azure.containerinstance_containergroups.cpu_usage{[[scope]]}" },
      { title = "Container group memory", q = "avg:azure.containerinstance_containergroups.memory_usage{[[scope]]}" },
    ]
    "microsoft.storage/storageaccounts" = [
      { title = "Table availability %", q = "avg:azure.storage_storageaccounts_tableservices.availability{[[scope]]}" },
      { title = "Table transactions", q = "sum:azure.storage_storageaccounts_tableservices.transactions{[[scope]]}.as_count()" },
    ]
    "microsoft.logic/workflows" = [
      { title = "Logic App runs started/failed", q = "sum:azure.logic_workflows.runs_started{[[scope]]}.as_count(), sum:azure.logic_workflows.runs_failed{[[scope]]}.as_count()" },
    ]
  }

  service_widgets = {
    for name, s in var.services : name => concat(
      s.traces_enabled ? [{
        definition = {
          type        = "group"
          title       = "APM (${s.server_operation})"
          layout_type = "ordered"
          widgets = [
            { definition = { type = "timeseries", title = "Requests and errors", requests = [
              { q = "sum:trace.${s.server_operation}.hits{service:${name},$env}.as_count()", display_type = "bars" },
              { q = "sum:trace.${s.server_operation}.errors{service:${name},$env}.as_count()", display_type = "bars" },
            ] } },
            { definition = { type = "timeseries", title = "Latency p50 / p95 / p99 (s)", requests = [
              { q = "p50:trace.${s.server_operation}{service:${name},$env}", display_type = "line" },
              { q = "p95:trace.${s.server_operation}{service:${name},$env}", display_type = "line" },
              { q = "p99:trace.${s.server_operation}{service:${name},$env}", display_type = "line" },
            ] } },
          ]
        }
      }] : [],
      s.rum_enabled ? [{
        definition = {
          type     = "query_value", title = "RUM sessions (1d)", precision = 0,
          requests = [{ response_format = "scalar", queries = [{ data_source = "rum", name = "q1", indexes = ["*"], compute = { aggregation = "count" }, search = { query = "@type:session service:${name} $env" } }], formulas = [{ formula = "q1" }] }]
        }
      }] : [],
      s.workflow_metric_prefix == null ? [] : [{
        definition = {
          type        = "group"
          title       = "Durable workflows"
          layout_type = "ordered"
          widgets = [
            { definition = { type = "timeseries", title = "Workflow outcomes", requests = [
              { q = "sum:${s.workflow_metric_prefix}.workflow.completed{service:${name},$env} by {workflow,outcome}.as_count()", display_type = "bars" },
            ] } },
            { definition = { type = "timeseries", title = "Workflow duration p95 (ms)", requests = [
              { q = "p95:${s.workflow_metric_prefix}.workflow.duration{service:${name},$env} by {workflow}", display_type = "line" },
            ] } },
          ]
        }
      }],
      [for r in s.resources : {
        definition = {
          type        = "group"
          title       = "${r.role} (${r.type})"
          layout_type = "ordered"
          widgets = [for w in lookup(local.resource_widgets, lower(r.type == "Microsoft.Web/sites" && s.architecture == "functions" ? "${r.type}#functions" : r.type), []) : {
            definition = { type = "timeseries", title = w.title, requests = [for q in split(", ", replace(w.q, "[[scope]]", r.scope)) : { q = q, display_type = "line" }] }
          }]
        }
        } if length(lookup(local.resource_widgets, lower(r.type == "Microsoft.Web/sites" && s.architecture == "functions" ? "${r.type}#functions" : r.type), [])) > 0
      ],
      s.logs_enabled ? [{
        definition = { type = "log_stream", title = "Error logs", query = "service:${name} $env status:error", columns = ["host", "service", "message"], indexes = [], message_display = "expanded-md", show_date_column = true, show_message_column = true, sort = { column = "time", order = "desc" } }
      }] : [],
      [for id in s.slo_ids : { definition = { type = "slo", title = "SLO", slo_id = id, view_type = "detail", view_mode = "overall", time_windows = ["7d", "30d"], show_error_budget = true } }],
      [{ definition = { type = "manage_status", title = "Monitors", query = "tag:(service:${name} AND env:${s.env})", summary_type = "monitors", display_format = "countsAndList", color_preference = "text", hide_zero_counts = true, sort = "status,asc" } }],
      [{ definition = { type = "note", content = "Owner team: **${s.team}** - Runbook: ${s.runbook_url}", background_color = "gray", font_size = "14", text_align = "left", show_tick = false, tick_pos = "50%", tick_edge = "left" } }],
    )
  }

  all_resources = flatten([for name, s in var.services : [for r in s.resources : merge(r, { service = name, architecture = s.architecture })]])
  db_types      = ["microsoft.sql/servers/databases", "microsoft.sql/managedinstances", "microsoft.dbforpostgresql/flexibleservers", "microsoft.dbformysql/flexibleservers", "microsoft.documentdb/databaseaccounts", "microsoft.cache/redisenterprise", "microsoft.cache/redis"]
  queue_types   = ["microsoft.servicebus/namespaces"]
  pipeline      = coalesce(var.overview.pipeline_scope, "env:${var.overview.env}")

  overview_widgets = [
    {
      definition = {
        type = "group", title = "User journey (browser -> BFF -> APIs -> data -> workflow)", layout_type = "ordered"
        widgets = concat(
          [for svc in var.overview.journey : {
            definition = { type = "query_value", title = "${svc} req/s", precision = 2, autoscale = true,
            requests = [{ q = "sum:trace.${try(var.services[svc].server_operation, "http.server.request")}.hits{service:${svc},$env}.as_rate()", aggregator = "avg" }] }
          } if try(var.services[svc].traces_enabled, false)],
          [for svc in var.overview.journey : {
            definition = { type = "timeseries", title = "${svc} error % ", requests = [{ q = "100 * sum:trace.${try(var.services[svc].server_operation, "http.server.request")}.errors{service:${svc},$env}.as_count() / sum:trace.${try(var.services[svc].server_operation, "http.server.request")}.hits{service:${svc},$env}.as_count()", display_type = "line" }] }
          } if try(var.services[svc].traces_enabled, false)],
          [{ definition = { type = "manage_status", title = "Journey monitors", query = "tag:(env:${var.overview.env} AND managed_by:observability-package)", summary_type = "monitors", display_format = "countsAndList", color_preference = "text", hide_zero_counts = true, sort = "status,asc" } }],
        )
      }
    },
    {
      definition = {
        type = "group", title = "Databases and caches (Azure platform metrics; DBM: see Database Monitoring)", layout_type = "ordered"
        widgets = flatten([for r in local.all_resources : [for w in lookup(local.resource_widgets, lower(r.type), []) : {
          definition = { type = "timeseries", title = "${r.service}/${r.role}: ${w.title}", requests = [for q in split(", ", replace(w.q, "[[scope]]", r.scope)) : { q = q, display_type = "line" }] }
        }] if contains(local.db_types, lower(r.type))])
      }
    },
    {
      definition = {
        type = "group", title = "Queues and durable workflows", layout_type = "ordered"
        widgets = concat(
          flatten([for r in local.all_resources : [for w in lookup(local.resource_widgets, lower(r.type), []) : {
            definition = { type = "timeseries", title = "${r.service}/${r.role}: ${w.title}", requests = [for q in split(", ", replace(w.q, "[[scope]]", r.scope)) : { q = q, display_type = "line" }] }
          }] if contains(local.queue_types, lower(r.type))]),
          [for name, s in var.services : {
            definition = { type = "timeseries", title = "${name} workflow outcomes", requests = [{ q = "sum:${s.workflow_metric_prefix}.workflow.completed{service:${name},$env} by {workflow,outcome}.as_count()", display_type = "bars" }] }
          } if s.workflow_metric_prefix != null],
        )
      }
    },
    {
      definition = {
        type = "group", title = "Telemetry pipeline health (Fluent Bit, OTel gateway, canary)", layout_type = "ordered"
        widgets = [
          { definition = { type = "timeseries", title = "Canary log records (expect ~1/min)", requests = [{ response_format = "timeseries", queries = [{ data_source = "logs", name = "q1", indexes = ["*"], compute = { aggregation = "count" }, search = { query = "service:telemetry-canary @canary:true env:${var.overview.env}" } }], formulas = [{ formula = "q1" }], display_type = "bars" }] } },
          { definition = { type = "timeseries", title = "Fluent Bit output errors / retries / dropped", requests = [
            { q = "sum:fluentbit_output_errors_total{${local.pipeline}}.as_count()", display_type = "bars" },
            { q = "sum:fluentbit_output_retries_total{${local.pipeline}}.as_count()", display_type = "bars" },
            { q = "sum:fluentbit_output_dropped_records_total{${local.pipeline}}.as_count()", display_type = "bars" },
          ] } },
          { definition = { type = "timeseries", title = "Fluent Bit records in/out", requests = [
            { q = "sum:fluentbit_input_records_total{${local.pipeline}}.as_count()", display_type = "line" },
            { q = "sum:fluentbit_output_proc_records_total{${local.pipeline}}.as_count()", display_type = "line" },
          ] } },
          { definition = { type = "timeseries", title = "OTel gateway accepted vs failed spans", requests = [
            { q = "sum:otelcol_receiver_accepted_spans{${local.pipeline}}.as_count()", display_type = "line" },
            { q = "sum:otelcol_exporter_send_failed_spans{${local.pipeline}}.as_count()", display_type = "bars" },
          ] } },
          { definition = { type = "timeseries", title = "OTel exporter queue size vs capacity", requests = [
            { q = "max:otelcol_exporter_queue_size{${local.pipeline}}", display_type = "line" },
            { q = "max:otelcol_exporter_queue_capacity{${local.pipeline}}", display_type = "line" },
          ] } },
        ]
      }
    },
  ]
}

resource "datadog_dashboard_json" "service" {
  for_each = var.create_service_dashboards ? var.services : {}

  dashboard = templatefile("${path.module}/templates/service.json.tftpl", {
    title       = "[${each.value.env}] ${each.key} - service overview"
    description = "Managed by the observability package (onboarding manifest). Team ${each.value.team}. Do not edit in the UI; changes are overwritten."
    env         = each.value.env
    widgets     = local.service_widgets[each.key]
  })
}

resource "datadog_dashboard_json" "overview" {
  count = var.overview.enabled ? 1 : 0

  dashboard = templatefile("${path.module}/templates/overview.json.tftpl", {
    title       = var.overview.title
    description = "Application overview: journey, databases, queues/durable workflows and telemetry pipeline health. Managed by the observability package."
    env         = var.overview.env
    widgets     = local.overview_widgets
  })
}
