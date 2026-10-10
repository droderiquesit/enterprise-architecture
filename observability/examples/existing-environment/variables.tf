variable "env" {
  description = "Environment name; selects rendered/<env>."
  type        = string
  default     = "prod"
}

variable "region" {
  description = "Azure region of the environment (tag policy key region)."
  type        = string
  default     = "westeurope"
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.com"
}

variable "telemetry" {
  description = <<-EOT
    The existing telemetry transport (equivalent of the obs-telemetry-transport contract), supplied by hand:
    OTLP endpoints of your collector/agents, Fluent Bit forward target (the Observability Pipelines Worker's fluent
    source), the Datadog API key as a Delinea DSV reference (dsv://...), the DSV endpoint + dsv-fetch image your
    workloads use (secrets.fetch_image: digest-pinned img-dsv-fetch >= 2.0.0, the static binary), and env.fleet /
    env.apm_gateway (log pipeline, APM mode and the Datadog Agent APM endpoint of managed runtimes).
  EOT
  type = object({
    datadog_site = string
    api_key_ref  = string
    secrets = object({
      tenant      = optional(string)
      tld         = optional(string, "com")
      base_url    = string
      fetch_image = string
    })
    otlp = object({
      grpc_endpoint = string
      http_endpoint = string
    })
    fluentbit = object({
      forward_host = string
      forward_port = number
      sidecar_mode = optional(string, "forward")
    })
    env = optional(map(map(string)), {})
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
      forward_host = "opw-observability-pipelines-worker.observability-pipelines.svc.cluster.local"
      forward_port = 24224
    }
    env = {
      fleet       = { EH_LOG_PIPELINE = "observability_pipelines", EH_APM_MODE = "datadog", EH_PROFILING_ENABLED = "true" }
      apm_gateway = { DD_TRACE_AGENT_URL = "http://datadog-apm.observability.internal:8126" }
    }
  }
  validation {
    condition     = can(regex("^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", var.telemetry.secrets.fetch_image))
    error_message = "telemetry.secrets.fetch_image must be the digest-pinned dsv-fetch image (<registry>/<repo>@sha256:<64 hex>)."
  }
}

variable "instrumented_services" {
  description = "Services that receive instrumentation settings (outputs for the application owners). Identity, runtime and hosting come from rendered/<env>."
  type = map(object({
    version = string
  }))
  default = {
    orders-web = { version = "2026.10.1" }
    orders-api = { version = "4.2.0" }
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
    Diagnostic settings on the manifest resources -> existing Event Hubs (the Observability Pipelines Worker reads them).
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
    Existing AKS cluster for the Datadog Agent (DaemonSet + Cluster Agent + cluster-checks runners; collects the pod
    logs and sends them to the Observability Pipelines Worker, Single Step Instrumentation of ssi_namespaces) and the
    Worker itself (modules/kubernetes, package 4.0.0). One secret path: every Agent component reads the key from
    Delinea DSV with workload identity identity_client_id (REQUIRED; federated by your identity team with the service
    accounts datadog/datadog, datadog/datadog-cluster-agent, datadog/datadog-cluster-checks and
    observability-pipelines/opw-observability-pipelines-worker). No key passes through Terraform or a Kubernetes Secret.
    values_overrides: per-cluster chart values documents (e.g. [file("clusters/aks-prod-weu.yaml")]), applied last.
  EOT
  type = object({
    enabled                = optional(bool, true)
    identity_client_id     = optional(string)
    cluster_name           = optional(string, "aks-prod-weu")
    host                   = optional(string, "https://aks-prod-weu.hcp.westeurope.azmk8s.io:443")
    cluster_ca_certificate = optional(string, "")
    ssi_namespaces         = optional(list(string), ["orders"])
    values_overrides       = optional(list(string), [])
    # canonical tag-policy values of the cluster infrastructure
    identity = optional(map(string), { team = "platform", owner = "platform-team@contoso.example", application = "platform", domain = "platform", tier = "infrastructure" })
  })
  default = { identity_client_id = "00000000-0000-0000-0000-000000000000" }
  validation {
    condition     = !var.kubernetes.enabled || can(regex("^[0-9a-fA-F-]{36}$", coalesce(var.kubernetes.identity_client_id, "x")))
    error_message = "kubernetes.identity_client_id (client id of the workload identity that reads the Datadog API key in DSV) is required."
  }
}

variable "hosts" {
  description = <<-EOT
    Optional: Datadog Agent on existing VMs / VMSS via Azure Policy (DeployIfNotExists) + Azure VM Applications
    (modules/host-agents, mode = policy). Tag the hosts datadog:enabled = "true". agent_identity: the per-environment
    DSV-reader user-assigned identity (read on the API key path only). dsv_fetch_release_dir: the img-dsv-fetch
    release zip, sha256-verified and unzipped by the pipeline before plan. package_version: bumped per change and
    promoted dev -> test -> prod.
  EOT
  type = object({
    enabled                      = optional(bool, false)
    resource_group_id            = optional(string)
    names                        = optional(object({ gallery = string, storage_account = string, publisher_identity = string }))
    package_version              = optional(string, "1.0.0")
    dsv_fetch_release_dir        = optional(string, ".dsv-fetch-release")
    publisher_principal_ids      = optional(list(string), [])
    agent_identity               = optional(object({ id = string, client_id = string }))
    scope                        = optional(object({ type = string, id = string, not_scopes = optional(list(string), []) }))
    identity_resource_group_name = optional(string)
    op_agent_logs_url            = optional(string)
  })
  default = {}
  validation {
    condition     = !var.hosts.enabled || (var.hosts.resource_group_id != null && var.hosts.names != null && var.hosts.agent_identity != null && var.hosts.scope != null && var.hosts.identity_resource_group_name != null)
    error_message = "hosts.enabled needs resource_group_id, names, agent_identity, scope and identity_resource_group_name."
  }
}

variable "dbm" {
  description = <<-EOT
    Datadog Database Monitoring for the existing PostgreSQL server, run as cluster checks by the Cluster Agent on the
    existing AKS cluster (no new compute). The DBM user/grants are created by the DBA with the package SQL
    (modules/dbm/sql/postgres-flexible.sql); the password lives in Delinea DSV and is resolved by the cluster-checks
    runners' dsv-fetch secret backend (ENC[dsv://...]).
  EOT
  type = object({
    enabled      = optional(bool, true)
    host         = optional(string, "psql-orders-prod.postgres.database.azure.com")
    resource_id  = optional(string, "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-data-prod/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-orders-prod")
    password_ref = optional(string, "dsv://monitoring/prod/dbm-orders-postgresql#value")
  })
  default = {}
}

variable "observability_pipelines" {
  description = <<-EOT
    Datadog Observability Pipelines (package default log pipeline): the pipeline is created here, the Worker runs on the
    existing AKS cluster. The Worker's dsv-fetch init container reads its API key (telemetry.api_key_ref) and the Event
    Hubs listen connection string (eventhub.connection_string_ref) from Delinea DSV with workload identity; Terraform
    never reads a value and no Kubernetes Secret holds one. enabled = false: Fluent Bit direct.
  EOT
  type = object({
    enabled = optional(bool, true)
    eventhub = optional(object({
      bootstrap             = string
      topics                = list(string)
      connection_string_ref = string
      }), {
      bootstrap             = "evhns-obs-prod.servicebus.windows.net:9093"
      topics                = ["app-logs", "platform-logs", "activity-logs"]
      connection_string_ref = "dsv://monitoring/prod/eventhub-listen#value"
    })
  })
  default = {}
  validation {
    condition     = var.observability_pipelines.eventhub == null || can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", try(var.observability_pipelines.eventhub.connection_string_ref, "")))
    error_message = "observability_pipelines.eventhub.connection_string_ref must be a dsv:// reference."
  }
}

variable "rum" {
  description = <<-EOT
    RUM applications keyed by the frontend service (modules/rum): mode = create (name) or existing (application_id +
    client_token of an application your organisation already has). allowed_tracing_origins: first-party API origins
    that receive datadog + tracecontext headers.
  EOT
  type = map(object({
    mode                    = optional(string, "create")
    name                    = optional(string)
    application_id          = optional(string)
    client_token            = optional(string)
    allowed_tracing_origins = optional(list(string), [])
  }))
  default = {
    orders-web = { mode = "create", name = "orders-web (prod)", allowed_tracing_origins = ["https://api.orders.contoso.example"] }
  }
}
