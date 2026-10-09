variable "env" {
  description = "Environment name; selects rendered/<env> and routing/<env>.yaml."
  type        = string
  default     = "prod"
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.com"
}

variable "synthetics" {
  description = "Synthetic tests. private_location_id = an existing Datadog private location for private endpoints."
  type = object({
    enabled             = optional(bool, true)
    paused              = optional(bool, false)
    private_location_id = optional(string)
  })
  default = {}
}

variable "telemetry" {
  description = <<-EOT
    The existing telemetry transport (equivalent of the obs-telemetry-transport contract), supplied by hand:
    OTLP endpoints of your collector/agents, Fluent Bit forward target, the Datadog API key as a Delinea DSV
    reference (dsv://...) and the DSV endpoint + dsv-fetch image your workloads use. Used only to compute
    instrumentation patches for the application owners.
  EOT
  type = object({
    datadog_site = string
    api_key_ref  = string
    secrets = object({
      tenant      = optional(string)
      tld         = optional(string, "com")
      base_url    = string
      fetch_image = optional(string)
    })
    otlp = object({
      grpc_endpoint = string
      http_endpoint = string
    })
    fluentbit = object({
      forward_host = string
      forward_port = number
    })
  })
  default = {
    datadog_site = "datadoghq.com"
    api_key_ref  = "dsv://monitoring/prod/datadog-api-key#value"
    secrets = {
      tenant      = "contoso"
      base_url    = "https://contoso.secretsvaultcloud.com/v1"
      fetch_image = "acrplatformprod.azurecr.io/dsv-fetch@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    }
    otlp = {
      grpc_endpoint = "http://otel-gateway.observability.internal:4317"
      http_endpoint = "http://otel-gateway.observability.internal:4318"
    }
    fluentbit = {
      forward_host = "fluent-bit-aggregator.observability.internal"
      forward_port = 24224
    }
  }
}

variable "instrumented_services" {
  description = "Services that receive instrumentation patches (outputs for the application owners to apply)."
  type = map(object({
    version      = string
    team         = string
    runtime      = string
    architecture = string
  }))
  default = {
    orders-web = { version = "2026.10.1", team = "orders", runtime = "dotnet", architecture = "appservice" }
    orders-api = { version = "4.2.0", team = "orders", runtime = "java", architecture = "aks" }
  }
}

variable "fault_injection_enabled" {
  description = "Never enable fault injection in an existing (production) environment. Kept as an explicit, validated switch."
  type        = bool
  default     = false
  validation {
    condition     = var.fault_injection_enabled == false
    error_message = "Fault injection must stay disabled in existing environments."
  }
}

variable "azure_subscription_id" {
  description = "Subscription of the monitored resources (provider context only; resource ids come from manifests)."
  type        = string
  default     = "00000000-0000-0000-0000-000000000000"
}

variable "diagnostics" {
  description = <<-EOT
    Diagnostic settings on the manifest resources -> existing Event Hubs (Fluent Bit aggregator reads them).
    platform_log_tier: security | standard | verbose (package category policy, see docs/guides/azure-logs-to-datadog.md).
  EOT
  type = object({
    enabled           = optional(bool, true)
    platform_log_tier = optional(string, "standard")
    destination = optional(object({
      authorization_rule_id = string
      app_logs_hub          = string
      platform_logs_hub     = string
      activity_logs_hub     = optional(string, "activity-logs")
      }), {
      authorization_rule_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-observability-prod/providers/Microsoft.EventHub/namespaces/evhns-obs-prod/authorizationRules/diagnostics-send"
      app_logs_hub          = "app-logs"
      platform_logs_hub     = "platform-logs"
      activity_logs_hub     = "activity-logs"
    })
  })
  default = {}
}

variable "azure_logs" {
  description = <<-EOT
    Control-plane logs of the SUPPLIED subscriptions -> the same Event Hubs namespace (diagnostics.destination):
    subscription Activity Log (all categories by default) and, optionally, tenant-wide Entra ID logs (needs the
    Security Administrator role for the deploying identity, Entra ID P1/P2 for sign-in logs, acknowledge_prerequisites).
    Only diagnostic settings are created; destroy removes only them.
  EOT
  type = object({
    activity_log_enabled = optional(bool, true)
    subscription_ids     = optional(list(string), ["00000000-0000-0000-0000-000000000000"])
    categories           = optional(list(string), ["Administrative", "Security", "ServiceHealth", "Alert", "Recommendation", "Policy", "Autoscale", "ResourceHealth"])
    entra = optional(object({
      enabled                   = optional(bool, false)
      acknowledge_prerequisites = optional(bool, false)
      categories                = optional(list(string), ["AuditLogs", "SignInLogs", "ServicePrincipalSignInLogs", "ManagedIdentitySignInLogs"])
    }), {})
  })
  default = {}
}

variable "log_management" {
  description = "Datadog-side handling of the Azure platform logs (package modules/log-management). Index, pipeline and archive are org-wide objects and stay off unless this root owns them."
  type = object({
    dashboard = optional(bool, true)
    metrics   = optional(bool, true)
    index     = optional(bool, false)
    pipeline  = optional(bool, false)
  })
  default = {}
}

variable "azure_integration" {
  description = <<-EOT
    Datadog Azure integration (platform metrics for every monitor on azure.* metrics). Default: an EXISTING Entra app
    registration with secretless (workload identity federation) auth; Monitoring Reader is expected to be granted
    already (assign_monitoring_reader = false keeps this root free of role assignments). Set enabled = false when the
    integration is already managed elsewhere.
  EOT
  type = object({
    enabled                  = optional(bool, true)
    tenant_id                = optional(string, "00000000-0000-0000-0000-000000000000")
    client_id                = optional(string, "00000000-0000-0000-0000-000000000000")
    subscription_ids         = optional(list(string), ["00000000-0000-0000-0000-000000000000"])
    assign_monitoring_reader = optional(bool, false)
    sp_object_id             = optional(string)
  })
  default = {}
}

variable "kubernetes" {
  description = <<-EOT
    Existing AKS cluster for the Datadog Agent (DaemonSet + Cluster Agent) and the Fluent Bit DaemonSet
    (modules/kubernetes). api_key_mode = dsv_secret_backend (default): the Agents and Fluent Bit read the key from
    Delinea DSV with workload identity (identity_client_id, federated with the service accounts datadog/datadog,
    datadog/datadog-cluster-checks and fluent-bit/fluent-bit by your identity team); existing: a Secret
    "datadog-api-key" synced by the Delinea dsv-k8s syncer. No key passes through Terraform either way.
  EOT
  type = object({
    enabled                   = optional(bool, true)
    api_key_mode              = optional(string, "dsv_secret_backend")
    identity_client_id        = optional(string, "00000000-0000-0000-0000-000000000000")
    cluster_agent_secret_name = optional(string)
    cluster_name           = optional(string, "aks-prod-weu")
    host                   = optional(string, "https://aks-prod-weu.hcp.westeurope.azmk8s.io:443")
    cluster_ca_certificate = optional(string, "")
  })
  default = {}
}

variable "dbm" {
  description = <<-EOT
    Datadog Database Monitoring for the existing PostgreSQL server, run as cluster checks by the Cluster Agent on the
    existing AKS cluster (no new compute). The DBM user/grants are created by the DBA with the package SQL
    (modules/dbm/sql/postgres-flexible.sql); the password lives in Delinea DSV and is resolved by the cluster-checks
    runners' dsv-fetch secret backend (ENC[dsv://...]).
  EOT
  type = object({
    enabled         = optional(bool, true)
    host            = optional(string, "psql-orders-prod.postgres.database.azure.com")
    resource_id     = optional(string, "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-data-prod/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-orders-prod")
    password_ref    = optional(string, "dsv://monitoring/prod/dbm-orders-postgresql#value")
  })
  default = {}
}
