# environment + upstream contract variables (ADR-0001 §5, §6). Root settings follow below.
variable "environment" {
  description = "Environment globals rendered by tools/config/render.py (ADR-0001 §6)."
  type = object({
    name            = string
    location        = string
    subscription_id = string
    tenant_id       = string
    name_prefix     = string
    owner           = string
    team            = string
    cost_center     = string
    expires_on      = string
    tags            = map(string)
  })
}

variable "foundation_network" {
  description = "foundation-network contract v1 (only the fields this root uses)."
  type = object({
    resource_group_name = string
    location            = string
    subnets = map(object({
      id             = string
      name           = string
      address_prefix = string
    }))
    private_dns_zones = optional(map(object({
      id   = string
      name = string
    })), {})
    egress = optional(object({
      type       = string
      public_ips = optional(list(string), [])
    }), { type = "nat-gateway", public_ips = [] })
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v2 (only the fields this root uses)."
  type = object({
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
  })
}

variable "settings" {
  description = "platform-messaging settings (environment.yaml components.platform-messaging)."
  type = object({
    # Standard: no Private Link / VNet rules (Premium only); public endpoint with Entra-only auth,
    # optional IP firewall. Premium: private endpoint + public network access disabled.
    sku                           = optional(string, "Standard")
    premium_capacity              = optional(number, 1)
    premium_partitions            = optional(number, 1)
    private_endpoint_enabled      = optional(bool, true)  # honoured only on Premium
    public_network_access_enabled = optional(bool, false) # honoured only on Premium
    # IP firewall (all SKUs). When non-empty the namespace denies every other source.
    allowed_ip_ranges   = optional(list(string), [])
    allow_egress_ips    = optional(bool, false) # add foundation NAT/firewall egress IPs to allowed_ip_ranges
    topic_name          = optional(string, "order-events")
    topic_max_size_mb   = optional(number, 1024)
    message_ttl         = optional(string, "P14D")
    duplicate_detection = optional(string, "PT10M")
    subscriptions = optional(map(object({
      max_delivery_count = optional(number, 10)
      lock_duration      = optional(string, "PT1M")
      consumer           = string
      })), {
      fulfillment   = { consumer = "hello-durable", max_delivery_count = 10, lock_duration = "PT2M" }
      notifications = { consumer = "hello-worker", max_delivery_count = 10, lock_duration = "PT1M" }
      audit         = { consumer = "hello-functions", max_delivery_count = 10, lock_duration = "PT1M" }
      archive       = { consumer = "hello-logicapps", max_delivery_count = 10, lock_duration = "PT1M" }
    })
    queue_name               = optional(string, "batch-items")
    queue_max_delivery_count = optional(number, 5)
    queue_lock_duration      = optional(string, "PT5M")
    queue_consumer           = optional(string, "hello-jobs")
    # Senders. Logic Apps (Consumption/Standard) use foundation user-assigned identities; keys that
    # are not present in the identity contract are skipped (and reported in the contract).
    topic_sender_identities = optional(list(string), ["hello-orders-api", "hello-durable"])
    queue_sender_identities = optional(list(string), ["hello-durable"])
    logic_app_identities    = optional(list(string), ["hello-logicapps"])
    # KEDA's azure-servicebus scaler (ACA event-driven job) needs Manage rights to read message counts.
    queue_scaler_owner_enabled = optional(bool, true)
  })
  default = {}

  validation {
    condition     = contains(["Standard", "Premium"], var.settings.sku)
    error_message = "sku must be Standard or Premium (Basic has no topics)."
  }
  validation {
    condition     = contains([1, 2, 4, 8, 16], var.settings.premium_capacity)
    error_message = "premium_capacity must be 1, 2, 4, 8 or 16 messaging units."
  }
  validation {
    condition     = alltrue([for s in values(var.settings.subscriptions) : s.max_delivery_count >= 1 && s.max_delivery_count <= 100])
    error_message = "subscription max_delivery_count must be between 1 and 100."
  }
}
