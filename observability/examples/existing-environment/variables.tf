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
    OTLP endpoints of your collector/agents, Fluent Bit forward target, Datadog API key as a Key Vault
    versionless secret id. Used only to compute instrumentation patches for the application owners.
  EOT
  type = object({
    datadog_site      = string
    api_key_secret_id = string
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
    datadog_site      = "datadoghq.com"
    api_key_secret_id = "https://kv-observability-prod.vault.azure.net/secrets/datadog-api-key"
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
  description = "Diagnostic settings on the manifest resources -> existing Event Hubs (Fluent Bit aggregator reads them)."
  type = object({
    enabled = optional(bool, true)
    destination = optional(object({
      authorization_rule_id = string
      app_logs_hub          = string
      platform_logs_hub     = string
      }), {
      authorization_rule_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-observability-prod/providers/Microsoft.EventHub/namespaces/evhns-obs-prod/authorizationRules/diagnostics-send"
      app_logs_hub          = "app-logs"
      platform_logs_hub     = "platform-logs"
    })
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
    (modules/kubernetes). api_key_mode = existing: the Secret "datadog-api-key" is synced by your secret operator
    (Secrets Store CSI / External Secrets) - no key passes through Terraform.
  EOT
  type = object({
    enabled                = optional(bool, true)
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
    (modules/dbm/sql/postgres-flexible.sql); the password lives in the Kubernetes Secret named below.
  EOT
  type = object({
    enabled         = optional(bool, true)
    host            = optional(string, "psql-orders-prod.postgres.database.azure.com")
    resource_id     = optional(string, "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-data-prod/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-orders-prod")
    password_secret = optional(string, "datadog-dbm-postgres")
  })
  default = {}
}
