variable "name_prefix" {
  description = "Prefix for generated names, e.g. \"eh-obs-dev-sec\". Every name can be overridden in var.names."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}$", var.name_prefix))
    error_message = "name_prefix must be 2-23 chars of [a-z0-9-] starting with a letter (Container App names are limited to 32 chars)."
  }
}

variable "names" {
  description = "Optional explicit resource names (existing naming standards)."
  type = object({
    eventhub_namespace = optional(string)
    aggregator         = optional(string)
    gateway            = optional(string)
    op_worker          = optional(string)
    apm_gateway        = optional(string)
  })
  default = {}
}

variable "resource_group" {
  description = "Existing resource group for the transport resources."
  type = object({
    name = string
    id   = string
  })
  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+$", var.resource_group.id))
    error_message = "resource_group.id must be a resource group ID."
  }
}

variable "location" {
  description = "Azure region of the resources this module creates."
  type        = string
}

variable "tags" {
  description = "Azure tags of the resources this module creates."
  type        = map(string)
  default     = {}
}

variable "datadog" {
  description = "Datadog site + Delinea DSV reference of the API key (never the key itself)."
  type = object({
    site        = string
    api_key_ref = string
    env         = string
    extra_tags  = optional(map(string), {})
  })
  validation {
    condition     = contains(["datadoghq.com", "us3.datadoghq.com", "us5.datadoghq.com", "datadoghq.eu", "ap1.datadoghq.com", "ap2.datadoghq.com", "ddog-gov.com"], var.datadog.site)
    error_message = "datadog.site must be a Datadog site domain (datadoghq.com, us3/us5.datadoghq.com, datadoghq.eu, ap1/ap2.datadoghq.com, ddog-gov.com)."
  }
  validation {
    condition     = can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", var.datadog.api_key_ref))
    error_message = "datadog.api_key_ref must be a Delinea DSV reference (dsv://<path>#<element>)."
  }
}

variable "secrets" {
  description = <<-EOT
    Delinea DSV runtime settings (ADR-0001 section 14). Collectors and app sidecars read their keys directly from
    DSV with their managed identity through the dsv-fetch helper (init container), never from Key Vault:
      tenant / tld / base_url : DSV endpoint (base_url default https://<tenant>.secretsvaultcloud.<tld>/v1)
      auth                    : DSV_AUTH for workloads (azure = managed identity)
      fetch_image             : digest-pinned dsv-fetch image (registry artifact img-dsv-fetch); pulled with the
                                collector identity when it lives in a private registry
  EOT
  type = object({
    tenant      = optional(string)
    tld         = optional(string, "com")
    base_url    = optional(string)
    auth        = optional(string, "azure")
    fetch_image = optional(string)
  })
  validation {
    condition     = var.secrets.base_url != null || var.secrets.tenant != null
    error_message = "secrets needs tenant (base_url derived) or base_url."
  }
  validation {
    condition     = contains(["azure", "client_credentials", "none"], var.secrets.auth)
    error_message = "secrets.auth must be azure, client_credentials or none."
  }
}

variable "collector_identity" {
  description = "Existing user-assigned identity the collectors run as (dsv-fetch authenticates to DSV with it; it is mapped to a DSV user with read on the collector secret paths)."
  type = object({
    id           = string
    principal_id = string
    client_id    = string
  })
  default = null
}

variable "event_hub" {
  description = <<-EOT
    Event Hubs used by diagnostic settings (app-logs / platform-logs hubs, read by the aggregator Kafka input).
    mode = create   : Standard namespace (Kafka endpoint), 3 hubs (app-logs, platform-logs, activity-logs),
                      consumer group per hub, SAS rules
    mode = existing : bring your own namespace; provide namespace_id, send_authorization_rule_id plus the hub names
    listen_connection_string_ref : DSV reference of the Listen-rule connection string the aggregator reads
                      (mode = create: the module outputs the generated value as the SENSITIVE output
                      generated_secrets["eventhub-fluentbit-listen"]; tools/secrets/publish.py writes it to DSV
                      at this path after apply)
    mode = none     : no Event Hub route (App Service/Functions app logs then need another collector)
  EOT
  type = object({
    mode                              = optional(string, "create")
    sku                               = optional(string, "Standard")
    capacity                          = optional(number, 1)
    auto_inflate_max_throughput_units = optional(number, 0)
    partition_count                   = optional(number, 2)
    message_retention_days            = optional(number, 1)
    app_logs_hub                      = optional(string, "app-logs")
    platform_logs_hub                 = optional(string, "platform-logs")
    # control-plane logs (subscription Activity Log, optional Entra ID): a dedicated hub so a data-plane burst on
    # platform-logs never delays/throttles audit events; "" = share platform_logs_hub (no extra hub)
    activity_logs_hub            = optional(string, "activity-logs")
    consumer_group               = optional(string, "fluent-bit")
    namespace_id                 = optional(string)
    namespace_fqdn               = optional(string)
    send_authorization_rule_id   = optional(string)
    listen_connection_string_ref = optional(string)
    private_endpoint = optional(object({
      subnet_id           = string
      private_dns_zone_id = string
    }))
  })
  default = {}
  validation {
    condition     = contains(["create", "existing", "none"], var.event_hub.mode)
    error_message = "event_hub.mode must be create, existing or none."
  }
  validation {
    condition     = contains(["Standard", "Premium"], var.event_hub.sku)
    error_message = "event_hub.sku must be Standard or Premium (Basic has no Kafka endpoint)."
  }
  validation {
    condition     = var.event_hub.partition_count >= 1 && var.event_hub.partition_count <= 32 && var.event_hub.message_retention_days >= 1 && var.event_hub.message_retention_days <= 7
    error_message = "partition_count must be 1-32 and message_retention_days 1-7."
  }
  validation {
    condition     = var.event_hub.mode != "existing" || (var.event_hub.namespace_id != null && var.event_hub.send_authorization_rule_id != null)
    error_message = "event_hub.mode = existing requires namespace_id and send_authorization_rule_id."
  }
  validation {
    condition     = var.event_hub.listen_connection_string_ref == null || can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", coalesce(var.event_hub.listen_connection_string_ref, "x")))
    error_message = "event_hub.listen_connection_string_ref must be a dsv:// reference."
  }
}

variable "container_apps" {
  description = "Existing Container Apps environment (VNet-integrated; TCP ingress for the aggregator requires a custom VNet)."
  type = object({
    environment_id        = string
    workload_profile_name = optional(string, "Consumption")
    # Never true: receivers must not be reachable from the internet. Kept as an input so a mistaken
    # attempt fails validation loudly instead of being silently ignored.
    external_ingress = optional(bool, false)
  })
  default = null
  validation {
    condition     = var.container_apps == null || !try(var.container_apps.external_ingress, false)
    error_message = "Public (external) ingress for OTLP/Forward receivers is not allowed: collectors are internal-only (ACA internal ingress = VNet only)."
  }
}

variable "aggregator" {
  description = "Fluent Bit aggregator (forward + kafka inputs -> Datadog). Deployed only with log_pipeline = fluent_bit_direct (the Observability Pipelines Worker replaces it otherwise)."
  type = object({
    hosting                = optional(string, "container_app")
    image                  = optional(string, "fluent/fluent-bit:5.1.3")
    cpu                    = optional(number, 0.5)
    memory                 = optional(string, "1Gi")
    min_replicas           = optional(number, 1)
    max_replicas           = optional(number, 2)
    forward_shared_key_ref = optional(string)
    # TLS for the forward input: PEM cert/key read from DSV as FILES by dsv-fetch (/dsv-tls/tls.crt|tls.key)
    forward_tls = optional(object({
      cert_ref = string
      key_ref  = string
    }))
    # hosting = none: endpoints of an aggregator you already run
    external_endpoint = optional(object({
      host = string
      port = number
    }))
  })
  default = {}
  validation {
    condition     = contains(["container_app", "none"], var.aggregator.hosting)
    error_message = "aggregator.hosting must be container_app or none."
  }
  validation {
    condition     = var.aggregator.hosting != "none" || var.aggregator.external_endpoint != null
    error_message = "aggregator.hosting = none requires aggregator.external_endpoint (the caller provides the aggregator)."
  }
  validation {
    condition     = var.aggregator.hosting != "container_app" || can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", coalesce(var.aggregator.forward_shared_key_ref, "x")))
    error_message = "The aggregator Forward input requires forward_shared_key_ref (dsv:// reference)."
  }
  validation {
    condition     = var.aggregator.min_replicas >= 1 && var.aggregator.max_replicas >= var.aggregator.min_replicas && var.aggregator.max_replicas <= 10
    error_message = "aggregator replicas: 1 <= min <= max <= 10 (min >= 1 keeps the Kafka consumer and forward listener alive)."
  }
}

variable "gateway" {
  description = "OTel gateway for managed runtimes (OTLP gRPC 4317 + HTTP 4318, internal only)."
  type = object({
    hosting             = optional(string, "container_app")
    distribution        = optional(string, "upstream")
    image               = optional(string)
    cpu                 = optional(number, 0.5)
    memory              = optional(string, "1Gi")
    min_replicas        = optional(number, 1)
    max_replicas        = optional(number, 3)
    sampling            = optional(string, "probabilistic")
    sampling_percentage = optional(number, 100)
    # OTLP logs: drop (default; app logs only via Fluent Bit) | forward (opt-in, duplicates if a Fluent Bit route exists)
    otlp_logs = optional(string, "drop")
    # optional bearertokenauth on OTLP: token for the server (file via dsv-fetch), full header string for
    # clients (published in the contract as otlp.headers_ref; apps resolve it at start-up)
    auth = optional(object({
      token_ref          = string
      client_headers_ref = string
    }))
    external_endpoints = optional(object({
      grpc_endpoint = string
      http_endpoint = string
    }))
  })
  default = {}
  validation {
    condition     = contains(["container_app", "none"], var.gateway.hosting) && contains(["upstream", "ddot"], var.gateway.distribution)
    error_message = "gateway.hosting must be container_app|none and gateway.distribution upstream|ddot."
  }
  validation {
    condition     = contains(["probabilistic", "tail", "none"], var.gateway.sampling) && var.gateway.sampling_percentage >= 0 && var.gateway.sampling_percentage <= 100
    error_message = "gateway.sampling must be probabilistic|tail|none and sampling_percentage 0-100."
  }
  validation {
    condition     = var.gateway.sampling != "tail" || var.gateway.max_replicas == 1
    error_message = "Tail sampling needs every span of a trace on one replica: set gateway.max_replicas = 1 (ACA ingress is not trace-id aware)."
  }
  validation {
    condition     = !(var.gateway.distribution == "ddot" && var.gateway.auth != null)
    error_message = "The DDOT collector does not ship the bearertokenauth extension; use distribution = upstream for OTLP auth."
  }
  validation {
    condition     = var.gateway.hosting != "none" || var.gateway.external_endpoints != null
    error_message = "gateway.hosting = none requires gateway.external_endpoints."
  }
}

variable "sidecar_mode" {
  description = "Default for app sidecars published in the contract: datadog (direct, TLS) or forward (via aggregator)."
  type        = string
  default     = "datadog"
  validation {
    condition     = contains(["datadog", "forward"], var.sidecar_mode)
    error_message = "sidecar_mode must be datadog or forward."
  }
}

variable "images" {
  description = "Pinned images (ADR-0001 §2)."
  type = object({
    fluent_bit     = optional(string, "fluent/fluent-bit:5.1.3")
    otel_contrib   = optional(string, "otel/opentelemetry-collector-contrib:0.162.0")
    ddot_collector = optional(string, "datadog/ddot-collector:7.84.2")
  })
  default = {}
}

variable "aca_console_allow" {
  description = <<-EOT
    Container Apps / Jobs whose ContainerAppConsoleLogs the aggregator forwards (exact names or prefixes ending
    in '*'). ACA environments export console logs for ALL apps; apps with a Fluent Bit sidecar must be excluded
    to avoid duplicates, so list only apps/jobs with app_log_route = eventhub (e.g. jobs: "eh-caj-*").
    Empty = forward all (only correct when no app in the environment uses a sidecar).
  EOT
  type        = list(string)
  default     = []
}

variable "fleet_policy" {
  description = "Decoded fleet policy (null = package default config/fleet-policy.yaml): log_pipeline, op_worker sizing, agent version for the APM gateway."
  type        = any
  default     = null
}

variable "tag_policy" {
  description = "Decoded tag policy (null = package default) - enforced by the Observability Pipelines tag processors and the aggregator."
  type        = any
  default     = null
}

variable "log_pipeline" {
  description = "Override the fleet policy log_pipeline: observability_pipelines | fluent_bit_direct. Null = policy."
  type        = string
  default     = null
  validation {
    condition     = var.log_pipeline == null || contains(["observability_pipelines", "fluent_bit_direct"], coalesce(var.log_pipeline, "x"))
    error_message = "log_pipeline must be observability_pipelines or fluent_bit_direct."
  }
}

variable "default_tags" {
  description = "Environment-level Datadog tags (modules/tagging `tags` of the environment identity: env, region, managed_by, application, static policy tags). Filled into logs that arrive without them."
  type        = map(string)
  default     = {}
}

variable "observability_pipelines" {
  description = <<-EOT
    Datadog Observability Pipelines (log_pipeline = observability_pipelines):
      pipeline_id   : existing pipeline (created in the Datadog UI / elsewhere); null = this module creates it
                      (datadog_observability_pipeline via modules/observability-pipeline)
      hosting       : container_app (Worker on the Container Apps environment, internal ingress) | none (Worker
                      elsewhere, e.g. modules/kubernetes on AKS: give external_endpoint)
      workload_profile_name: profile of the Worker app (null = container_apps.workload_profile_name). On a Dedicated
                      profile dsv-fetch runs as a refresher sidecar (init containers get no managed identity there).
      buffer_storage: emptydir (replica-scoped) | azure_files (an ACA environment storage you provide; one data dir
                      per replica) - disk buffers of the destinations live there
      archive / azure / redaction: passed to modules/observability-pipeline
  EOT
  type = object({
    pipeline_id           = optional(string)
    name                  = optional(string)
    hosting               = optional(string, "container_app")
    image                 = optional(string)
    workload_profile_name = optional(string)
    buffer_storage        = optional(string, "emptydir")
    azure_files_storage   = optional(string)
    external_endpoint = optional(object({
      host = string
      port = optional(number, 24224)
    }))
    archive = optional(object({
      enabled               = optional(bool, false)
      container_name        = optional(string, "datadog-log-archive")
      blob_prefix           = optional(string, "")
      connection_string_ref = optional(string)
    }), {})
    azure = optional(object({
      scope_tags        = optional(map(map(string)), {})
      static_tags       = optional(map(string), {})
      daily_quota_bytes = optional(number, 0)
      sample_categories = optional(map(number), {})
    }), {})
    redaction_extra_patterns = optional(map(string), {})
    otlp_logs_source         = optional(bool, false)
  })
  default = {}
  validation {
    condition     = contains(["container_app", "none"], var.observability_pipelines.hosting) && contains(["emptydir", "azure_files"], var.observability_pipelines.buffer_storage)
    error_message = "observability_pipelines.hosting must be container_app|none and buffer_storage emptydir|azure_files."
  }
  validation {
    condition     = var.observability_pipelines.buffer_storage != "azure_files" || var.observability_pipelines.azure_files_storage != null
    error_message = "buffer_storage = azure_files needs azure_files_storage (name of an ACA environment storage)."
  }
}

variable "apm_gateway" {
  description = <<-EOT
    Datadog Agent APM gateway for managed runtimes (fleet policy apm.mode = datadog, managed_runtime_path =
    agent_gateway): Container Apps / ACI / App Service / Functions tracers send to http://<fqdn>:8126 (VNet-internal);
    the Agent resolves its API key from Delinea DSV (ENC[dsv://...] + dsv-fetch secret backend), so no workload holds
    a key. hosting = none: give external_url (an Agent you run), or leave it null when no workload uses the gateway.
  EOT
  type = object({
    hosting      = optional(string, "container_app")
    image        = optional(string)
    cpu          = optional(number, 1)
    memory       = optional(string, "2Gi")
    min_replicas = optional(number, 1)
    max_replicas = optional(number, 3)
    external_url = optional(string)
  })
  default = {}
  validation {
    condition     = contains(["container_app", "none"], var.apm_gateway.hosting)
    error_message = "apm_gateway.hosting must be container_app or none."
  }
}

variable "service_tags" {
  description = "Per service: its rendered Datadog tag set (onboarding rendered `tags`, modules/tagging). The OTel gateway fills missing policy tags of that service.name (never overwriting a client value)."
  type        = map(map(string))
  default     = {}
}
