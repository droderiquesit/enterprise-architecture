# "Azure platform logs" dashboard (log queries only; works with or without the dedicated index).
locals {
  dq = "${local.q} $env"

  logs_ts = { for k, v in {
    by_source       = { title = "Azure platform log volume by source", query = local.dq, facet = "source" }
    activity_by_cat = { title = "Activity Log events by category", query = "${local.dq} azure_log_type:activity", facet = "@category" }
    activity_writes = { title = "Activity Log successful writes/deletes by resource group", query = "${local.dq} azure_log_type:activity @category:Administrative @resultType:Success @operationName:(*\\/WRITE OR *\\/DELETE OR *\\/write OR *\\/delete)", facet = "resource_group" }
    policy_denies   = { title = "Azure Policy denies", query = "${local.dq} azure_log_type:activity @category:Policy @operationName:(MICROSOFT.AUTHORIZATION\\/POLICIES\\/DENY\\/ACTION OR Microsoft.Authorization\\/policies\\/deny\\/action)", facet = "resource_group" }
    kv_denied       = { title = "Key Vault 401/403 by vault", query = "source:azure.keyvault @category:AuditEvent @properties.httpStatusCode:(401 OR 403) $env", facet = "resource_name" }
    aks_exec        = { title = "AKS exec / port-forward / attach by cluster", query = "source:azure.containerservice @aks_audit.objectRef.subresource:(exec OR portforward OR attach) $env", facet = "resource_name" }
    truncated       = { title = "Records truncated by the size guard (Datadog 1 MB limit)", query = "${local.dq} truncated:true", facet = "source" }
    } : k => {
    definition = {
      type  = "timeseries"
      title = v.title
      requests = [{
        response_format = "timeseries"
        display_type    = "bars"
        queries = [{
          data_source = "logs", name = "q1", indexes = ["*"], compute = { aggregation = "count" }, search = { query = v.query }
          group_by    = [{ facet = v.facet, limit = 10, sort = { aggregation = "count", order = "desc" } }]
        }]
        formulas = [{ formula = "q1" }]
      }]
    }
  } }

  entra_widgets_all = [
    { definition = {
      type  = "timeseries"
      title = "Entra ID sign-in failures by error code"
      requests = [{
        response_format = "timeseries", display_type = "bars"
        queries = [{
          data_source = "logs", name = "q1", indexes = ["*"], compute = { aggregation = "count" }
          search      = { query = "source:azure.activedirectory @category:SignInLogs -@properties.status.errorCode:0" }
          group_by    = [{ facet = "@properties.status.errorCode", limit = 10, sort = { aggregation = "count", order = "desc" } }]
        }]
        formulas = [{ formula = "q1" }]
      }]
    } },
    { definition = {
      type             = "log_stream", title = "Entra ID directory changes (AuditLogs)", query = "source:azure.activedirectory @category:AuditLogs",
      columns          = ["host", "service", "@operationName", "@properties.initiatedBy.user.userPrincipalName"], indexes = [], message_display = "inline",
      show_date_column = true, show_message_column = true, sort = { column = "time", order = "desc" }
    } },
  ]
  entra_widgets = slice(local.entra_widgets_all, 0, var.dashboard.entra ? 2 : 0)

  dashboard_widgets = [
    {
      definition = {
        type        = "group"
        title       = "Azure platform logs (Activity Log, resource logs${var.dashboard.entra ? ", Entra ID" : ""})"
        layout_type = "ordered"
        widgets = concat(
          [for k in ["by_source", "activity_by_cat", "activity_writes", "policy_denies", "kv_denied", "aks_exec", "truncated"] : local.logs_ts[k]],
          [
            { definition = {
              type             = "log_stream", title = "Activity Log: failed or deleted operations", query = "${local.dq} azure_log_type:activity (@resultType:Failure OR @operationName:(*\\/DELETE OR *\\/delete))",
              columns          = ["host", "service", "@operationName", "@resultType", "resource_group"], indexes = [], message_display = "inline",
              show_date_column = true, show_message_column = true, sort = { column = "time", order = "desc" }
            } },
            { definition = {
              type             = "log_stream", title = "Service Health / Resource Health", query = "${local.dq} azure_log_type:activity @category:(ServiceHealth OR ResourceHealth)",
              columns          = ["host", "service", "@properties.title", "@properties.region", "@properties.incidentType"], indexes = [], message_display = "inline",
              show_date_column = true, show_message_column = true, sort = { column = "time", order = "desc" }
            } },
          ],
          local.entra_widgets,
          [{ definition = { type = "note", content = "Source: Azure diagnostic settings -> Event Hubs -> Fluent Bit aggregator (ddsource `azure.*`, service `azure`). Guide: docs/guides/azure-logs-to-datadog.md in the package repository. Application logs (`azure_log_type:application`) are excluded.", background_color = "gray", font_size = "14", text_align = "left", show_tick = false, tick_pos = "50%", tick_edge = "left" } }],
        )
      }
    },
  ]
}

resource "datadog_dashboard_json" "azure_logs" {
  count = var.dashboard.enabled ? 1 : 0
  dashboard = jsonencode({
    title       = coalesce(var.dashboard.title, "[${var.env}] Azure platform logs")
    description = "Azure Activity Log, resource platform logs and (optionally) Entra ID logs shipped through Event Hubs and the Fluent Bit aggregator. Managed by the observability package (modules/log-management)."
    layout_type = "ordered"
    reflow_type = "auto"
    notify_list = []
    template_variables = [
      { name = "env", prefix = "env", available_values = [], default = var.env },
    ]
    widgets = local.dashboard_widgets
  })
}
