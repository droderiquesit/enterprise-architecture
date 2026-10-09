# Datadog-side log management for Azure platform / control-plane logs: optional index (retention, quota, sampled
# exclusion filters), optional Activity Log pipeline, optional log-based metrics, optional archive, dashboard.
# Every object is opt-in except the dashboard, so organisations that manage indexes/pipelines centrally are untouched.
locals {
  q = var.scope_query

  default_exclusions = [
    { name = "aks-full-audit-reads-90pct", query = "source:azure.containerservice @category:kube-audit @aks_audit.verb:(get OR list OR watch)", sample_rate = 0.9, enabled = true },
    { name = "storage-reads-90pct", query = "source:azure.storage @category:StorageRead", sample_rate = 0.9, enabled = true },
    { name = "cosmos-dataplane-90pct", query = "source:azure.documentdb @category:(DataPlaneRequests OR MongoRequests OR CassandraRequests OR GremlinRequests OR TableApiRequests)", sample_rate = 0.9, enabled = true },
  ]
  exclusions = concat(var.index.default_exclusions ? local.default_exclusions : [], var.index.exclusion_filters)

  # operationName arrives upper-case from the Activity Log Event Hubs export (MICROSOFT.X/Y/DELETE) and
  # mixed-case from some resource providers; attribute values are matched case-sensitively, so both are listed.
  activity = "${local.q} azure_log_type:activity"
  log_metrics = {
    "activity.writes" = {
      query    = "${local.activity} @category:Administrative @resultType:Success @operationName:(*\\/WRITE OR *\\/write)"
      group_by = ["subscription_id", "resource_group"]
    }
    "activity.deletes" = {
      query    = "${local.activity} @category:Administrative @resultType:Success @operationName:(*\\/DELETE OR *\\/delete)"
      group_by = ["subscription_id", "resource_group"]
    }
    "activity.policy_denies" = {
      query    = "${local.activity} @category:Policy @operationName:(MICROSOFT.AUTHORIZATION\\/POLICIES\\/DENY\\/ACTION OR Microsoft.Authorization\\/policies\\/deny\\/action)"
      group_by = ["subscription_id", "resource_group"]
    }
    "keyvault.access_denied" = {
      query    = "source:azure.keyvault @category:AuditEvent @properties.httpStatusCode:(401 OR 403)"
      group_by = ["subscription_id", "resource_name"]
    }
    "aks.exec_portforward" = {
      query    = "source:azure.containerservice @aks_audit.objectRef.subresource:(exec OR portforward OR attach)"
      group_by = ["resource_name"]
    }
    "entra.signin_failures" = {
      query    = "source:azure.activedirectory @category:SignInLogs -@properties.status.errorCode:0"
      group_by = ["tenant"]
    }
    "volume" = {
      query    = local.q
      group_by = ["source", "category"]
    }
    "truncated" = {
      query    = "${local.q} truncated:true"
      group_by = ["source"]
    }
  }
}

resource "datadog_logs_index" "azure" {
  count          = var.index.enabled ? 1 : 0
  name           = var.index.name
  retention_days = var.index.retention_days

  flex_retention_days                      = var.index.flex_retention_days
  daily_limit                              = var.index.daily_limit
  daily_limit_warning_threshold_percentage = var.index.daily_limit != null ? var.index.daily_limit_warning_threshold_percentage : null

  dynamic "daily_limit_reset" {
    for_each = var.index.daily_limit != null ? [1] : []
    content {
      reset_time       = var.index.daily_limit_reset_time
      reset_utc_offset = var.index.daily_limit_reset_utc_offset
    }
  }

  filter {
    query = local.q
  }

  dynamic "exclusion_filter" {
    for_each = local.exclusions
    content {
      name       = exclusion_filter.value.name
      is_enabled = exclusion_filter.value.enabled
      filter {
        query       = exclusion_filter.value.query
        sample_rate = exclusion_filter.value.sample_rate
      }
    }
  }
}

resource "datadog_logs_index_order" "this" {
  count   = var.index_order.manage ? 1 : 0
  name    = "index-order"
  indexes = var.index_order.indexes

  lifecycle {
    precondition {
      condition     = !var.index.enabled || contains(var.index_order.indexes, var.index.name)
      error_message = "index_order.indexes must contain index.name (and every other index of the organisation)."
    }
  }
  depends_on = [datadog_logs_index.azure]
}

resource "datadog_logs_custom_pipeline" "activity" {
  count      = var.pipeline.enabled ? 1 : 0
  name       = var.pipeline.name
  is_enabled = true
  filter {
    query = local.activity
  }

  dynamic "processor" {
    for_each = [
      { name = "operationName -> evt.name", source = "operationName", target = "evt.name" },
      { name = "resultType -> evt.outcome", source = "resultType", target = "evt.outcome" },
      { name = "category -> evt.category", source = "category", target = "evt.category" },
      { name = "callerIpAddress -> network.client.ip", source = "callerIpAddress", target = "network.client.ip" },
    ]
    content {
      attribute_remapper {
        name                 = processor.value.name
        is_enabled           = true
        sources              = [processor.value.source]
        source_type          = "attribute"
        target               = processor.value.target
        target_type          = "attribute"
        preserve_source      = true
        override_on_conflict = false
      }
    }
  }
}

resource "datadog_logs_metric" "this" {
  for_each = var.metrics.enabled ? local.log_metrics : {}
  name     = "${var.metrics.prefix}.${each.key}"

  compute {
    aggregation_type = "count"
  }
  filter {
    query = each.value.query
  }
  dynamic "group_by" {
    for_each = each.value.group_by
    content {
      path     = group_by.value
      tag_name = group_by.value
    }
  }
}

resource "datadog_logs_archive" "azure" {
  count        = var.archive.enabled ? 1 : 0
  name         = var.archive.name
  query        = coalesce(var.archive.query, local.q)
  include_tags = var.archive.include_tags

  azure_archive {
    client_id       = var.archive.client_id
    tenant_id       = var.archive.tenant_id
    storage_account = var.archive.storage_account
    container       = var.archive.container
    path            = var.archive.path
  }
}
