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
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "datadog" {
  description = "Datadog site + Key Vault reference of the API key (never the key itself)."
  type = object({
    site              = string
    api_key_secret_id = string
    env               = string
    extra_tags        = optional(map(string), {})
  })
  validation {
    condition     = contains(["datadoghq.com", "us3.datadoghq.com", "us5.datadoghq.com", "datadoghq.eu", "ap1.datadoghq.com", "ap2.datadoghq.com", "ddog-gov.com"], var.datadog.site)
    error_message = "datadog.site must be a Datadog site domain (datadoghq.com, us3/us5.datadoghq.com, datadoghq.eu, ap1/ap2.datadoghq.com, ddog-gov.com)."
  }
  validation {
    condition     = can(regex("^https://[^/]+/secrets/[^/]+/?$", var.datadog.api_key_secret_id))
    error_message = "datadog.api_key_secret_id must be a VERSIONLESS Key Vault secret id (https://<vault>/secrets/<name>)."
  }
}

variable "collector_identity" {
  description = "Existing user-assigned identity the collectors run as (reads Key Vault secret references)."
  type = object({
    id           = string
    principal_id = string
    client_id    = string
  })
  default = null
}

variable "key_vault" {
  description = "Key Vault holding the referenced secrets. grant_secrets_user assigns 'Key Vault Secrets User' to the collector identity (RBAC vaults)."
  type = object({
    id                 = optional(string)
    grant_secrets_user = optional(bool, false)
  })
  default = {}
}

variable "event_hub" {
  description = <<-EOT
    Event Hubs used by diagnostic settings (app-logs / platform-logs hubs, read by the aggregator Kafka input).
    mode = create   : Standard namespace (Kafka endpoint), 2 hubs, consumer group, SAS rules
    mode = existing : bring your own namespace; provide namespace_id, send_authorization_rule_id and
                      listen_connection_string_secret_id (Key Vault) plus the hub names
    mode = none     : no Event Hub route (App Service/Functions app logs then need another collector)
  EOT
  type = object({
    mode                               = optional(string, "create")
    sku                                = optional(string, "Standard")
    capacity                           = optional(number, 1)
    auto_inflate_max_throughput_units  = optional(number, 0)
    partition_count                    = optional(number, 2)
    message_retention_days             = optional(number, 1)
    app_logs_hub                       = optional(string, "app-logs")
    platform_logs_hub                  = optional(string, "platform-logs")
    consumer_group                     = optional(string, "fluent-bit")
    namespace_id                       = optional(string)
    namespace_fqdn                     = optional(string)
    send_authorization_rule_id         = optional(string)
    listen_connection_string_secret_id = optional(string)
    # where the module stores the generated listen connection string (mode = create)
    listen_secret_key_vault_id = optional(string)
    listen_secret_name         = optional(string, "eventhub-fluentbit-listen")
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
    condition     = var.event_hub.mode != "existing" || (var.event_hub.namespace_id != null && var.event_hub.send_authorization_rule_id != null && var.event_hub.listen_connection_string_secret_id != null)
    error_message = "event_hub.mode = existing requires namespace_id, send_authorization_rule_id and listen_connection_string_secret_id."
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
  description = "Fluent Bit aggregator (forward + kafka inputs -> Datadog)."
  type = object({
    hosting                      = optional(string, "container_app")
    image                        = optional(string, "fluent/fluent-bit:5.1.3")
    cpu                          = optional(number, 0.5)
    memory                       = optional(string, "1Gi")
    min_replicas                 = optional(number, 1)
    max_replicas                 = optional(number, 2)
    forward_shared_key_secret_id = optional(string)
    forward_tls = optional(object({
      cert_secret_id = string
      key_secret_id  = string
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
    condition     = var.aggregator.hosting != "container_app" || var.aggregator.forward_shared_key_secret_id != null
    error_message = "The aggregator Forward input requires forward_shared_key_secret_id (Key Vault secret id)."
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
    # optional bearertokenauth on OTLP: token for the server, full header string for clients
    auth = optional(object({
      token_secret_id          = string
      client_headers_secret_id = string
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
