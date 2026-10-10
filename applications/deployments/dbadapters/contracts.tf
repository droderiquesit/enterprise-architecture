# Generated: upstream contract variables (ADR-0001 §5). Only the fields this root uses.
# Optional producers (catalog/components.yaml optional_consumes) default to null; every resource that
# depends on them is guarded with count/for_each.

variable "platform_containerapps" {
  description = "platform-containerapps contract v1 (required)."
  type = object({
    resource_group_name    = string
    location               = optional(string)
    environment_id         = string
    default_domain         = string
    ingress_mode           = string
    workload_profiles      = list(string)
    dedicated_profile_name = optional(string)
  })
}

variable "platform_shared" {
  description = "platform-shared contract v1 (required)."
  type = object({
    acr_id           = string
    acr_login_server = string
  })
}

variable "obs_telemetry_transport" {
  description = "obs-telemetry-transport contract v3 (required). Secrets are Delinea DSV references (dsv://...), never values."
  type = object({
    datadog_site = string
    api_key_ref  = string
    secrets = object({
      provider    = optional(string, "delinea-dsv")
      tenant      = optional(string)
      tld         = optional(string, "com")
      base_url    = string
      auth        = optional(string, "azure")
      fetch_image = optional(string)
      env_file    = optional(string, "/dsv-secrets/fluentbit-env.yaml")
    })
    otlp = object({
      grpc_endpoint            = string
      http_endpoint            = string
      headers_ref              = optional(string)
      default_protocol         = optional(string, "http/protobuf")
      node_agent_grpc_port     = optional(number, 4317)
      node_agent_http_port     = optional(number, 4318)
      host_agent_grpc_endpoint = optional(string, "http://localhost:4317")
    })
    fluentbit = object({
      forward_host           = string
      forward_port           = number
      sidecar_image          = optional(string, "fluent/fluent-bit:5.1.3")
      sidecar_config         = optional(string)
      sidecar_forward_config = optional(string)
      sidecar_parsers        = optional(string)
      sidecar_lua            = optional(string)
      sidecar_mode           = optional(string, "datadog")
      logs_intake_host       = optional(string)
      forward_shared_key_ref = optional(string)
    })
    env = optional(map(map(string)), {})
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v2 (required): identities + Delinea DSV secrets block (refs). No Key Vault."
  type = object({
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
      secrets      = optional(list(string), [])
    }))
    secrets = object({
      provider  = optional(string, "delinea-dsv")
      tenant    = optional(string)
      tld       = optional(string, "com")
      base_url  = optional(string)
      base_path = string
      refs      = optional(map(string), {})
    })
  })
}

variable "platform_appservice" {
  description = "platform-appservice contract v1 (optional; null when the producer is not enabled)."
  type = object({
    resource_group_name   = string
    location              = optional(string)
    integration_subnet_id = string
    plans = map(object({
      id      = string
      name    = string
      os_type = string
      sku     = string
    }))
    functions_dedicated_plan = optional(string)
    logicapps_storage = optional(object({
      id            = string
      name          = string
      blob_endpoint = optional(string)
    }))
  })
  default = null
}

variable "platform_vmss" {
  description = "platform-vmss contract v1 (optional; null when the producer is not enabled)."
  type = object({
    resource_group_name = string
    location            = optional(string)
    scale_sets = map(object({
      id                 = string
      name               = string
      orchestration_mode = string
      upgrade_mode       = optional(string, "Manual")
      workload           = string
      identity_id        = optional(string)
      identity_client_id = optional(string)
      app_root           = optional(string, "/opt/hello")
      log_dir            = optional(string, "/var/log/hello")
    }))
  })
  default = null
}

variable "platform_db_sql" {
  description = "platform-db-sql contract v1 (optional; null when the producer is not enabled)."
  type = object({
    server = object({
      fqdn = string
      port = optional(number, 1433)
    })
    databases = map(object({
      name = string
      id   = optional(string)
    }))
  })
  default = null
}

variable "platform_db_sqlmi" {
  description = "platform-db-sqlmi contract v1 (optional; null when the producer is not enabled)."
  type = object({
    enabled = optional(bool, true)
    server = optional(object({
      fqdn = string
      port = optional(number, 1433)
    }))
    databases = optional(map(object({
      name = string
    })), {})
  })
  default = null
}

variable "platform_db_sqlvm" {
  description = "platform-db-sqlvm contract v1 (optional; null when the producer is not enabled)."
  type = object({
    vm = object({
      id                 = string
      private_ip_address = string
    })
    server = object({
      fqdn = string
      port = optional(number, 1433)
    })
    databases = map(object({
      name               = string
      login              = optional(string)
      password_secret_id = optional(string) # dsv:// reference (field name kept from v1)
    }))
  })
  default = null
}

variable "platform_db_postgresql" {
  description = "platform-db-postgresql contract v1 (optional; null when the producer is not enabled)."
  type = object({
    server = object({
      fqdn = string
      port = optional(number, 5432)
    })
    databases = map(object({
      name = string
      id   = optional(string)
    }))
    elastic_cluster = optional(object({
      id       = string
      fqdn     = string
      port     = optional(number, 5432)
      database = optional(string, "adapter")
    }))
  })
  default = null
}

variable "platform_db_mysql" {
  description = "platform-db-mysql contract v1 (optional; null when the producer is not enabled)."
  type = object({
    server = object({
      fqdn = string
      port = optional(number, 3306)
    })
    databases = map(object({
      name = string
      id   = optional(string)
    }))
  })
  default = null
}

variable "platform_db_cosmos_nosql" {
  description = "platform-db-cosmos-nosql contract v1 (optional; null when the producer is not enabled)."
  type = object({
    account = object({
      id       = string
      name     = string
      endpoint = string
      host     = optional(string)
      port     = optional(number)
      username = optional(string)
    })
    auth_mode     = string
    key_secret_id = optional(string) # dsv:// reference (field name kept from v1)
    databases = map(object({
      name = string
      containers = optional(map(object({
        name          = string
        partition_key = optional(string)
      })), {})
    }))
  })
  default = null
}

variable "platform_db_cosmos_mongo" {
  description = "platform-db-cosmos-mongo contract v1 (optional; null when the producer is not enabled)."
  type = object({
    account = object({
      id       = string
      name     = string
      endpoint = string
      host     = optional(string)
      port     = optional(number)
      username = optional(string)
    })
    auth_mode     = string
    key_secret_id = optional(string) # dsv:// reference (field name kept from v1)
    databases = map(object({
      name = string
      containers = optional(map(object({
        name          = string
        partition_key = optional(string)
      })), {})
    }))
  })
  default = null
}

variable "platform_db_cosmos_cassandra" {
  description = "platform-db-cosmos-cassandra contract v1 (optional; null when the producer is not enabled)."
  type = object({
    account = object({
      id       = string
      name     = string
      endpoint = string
      host     = optional(string)
      port     = optional(number)
      username = optional(string)
    })
    auth_mode     = string
    key_secret_id = optional(string) # dsv:// reference (field name kept from v1)
    databases = map(object({
      name = string
      containers = optional(map(object({
        name          = string
        partition_key = optional(string)
      })), {})
    }))
  })
  default = null
}

variable "platform_db_cosmos_gremlin" {
  description = "platform-db-cosmos-gremlin contract v1 (optional; null when the producer is not enabled)."
  type = object({
    account = object({
      id       = string
      name     = string
      endpoint = string
      host     = optional(string)
      port     = optional(number)
      username = optional(string)
    })
    auth_mode     = string
    key_secret_id = optional(string) # dsv:// reference (field name kept from v1)
    databases = map(object({
      name = string
      containers = optional(map(object({
        name          = string
        partition_key = optional(string)
      })), {})
    }))
  })
  default = null
}

variable "platform_db_cosmos_table" {
  description = "platform-db-cosmos-table contract v1 (optional; null when the producer is not enabled)."
  type = object({
    account = object({
      id       = string
      name     = string
      endpoint = string
      host     = optional(string)
      port     = optional(number)
      username = optional(string)
    })
    auth_mode     = string
    key_secret_id = optional(string) # dsv:// reference (field name kept from v1)
    databases = map(object({
      name = string
      containers = optional(map(object({
        name          = string
        partition_key = optional(string)
      })), {})
    }))
  })
  default = null
}

variable "platform_db_documentdb" {
  description = "platform-db-documentdb contract v1 (optional; null when the producer is not enabled)."
  type = object({
    cluster = object({
      id   = string
      name = string
      host = string
      port = optional(number, 10260)
    })
    databases = map(object({
      name = string
    }))
  })
  default = null
}

variable "platform_db_cassandra_mi" {
  description = "platform-db-cassandra-mi contract v1 (optional; null when the producer is not enabled)."
  type = object({
    enabled = optional(bool, true)
    cluster = optional(object({
      id                     = string
      datacenter             = optional(string, "dc1")
      seed_node_ip_addresses = list(string)
      port                   = optional(number, 9042)
    }))
    databases = optional(map(object({
      name               = string
      login              = optional(string)
      password_secret_id = optional(string) # dsv:// reference (field name kept from v1)
    })), {})
  })
  default = null
}

variable "platform_db_redis" {
  description = "platform-db-redis contract v1 (optional; null when the producer is not enabled)."
  type = object({
    cache = object({
      id       = string
      hostname = string
      port     = optional(number, 10000)
    })
  })
  default = null
}

variable "platform_db_table_storage" {
  description = "platform-db-table-storage contract v1 (optional; null when the producer is not enabled)."
  type = object({
    account = object({
      id       = string
      name     = string
      endpoint = string
    })
    databases = map(object({
      name = string
    }))
  })
  default = null
}

variable "platform_db_ledger" {
  description = "platform-db-ledger contract v1 (optional; null when the producer is not enabled)."
  type = object({
    ledger = object({
      id                        = string
      name                      = string
      ledger_endpoint           = string
      identity_service_endpoint = optional(string)
    })
    databases = map(object({
      name = string
    }))
  })
  default = null
}

variable "platform_db_horizondb" {
  description = "platform-db-horizondb contract v1 (optional; null when the producer is not enabled)."
  type = object({
    enabled = optional(bool, true)
    cluster = optional(object({
      id   = string
      fqdn = optional(string)
      port = optional(number, 5432)
    }))
  })
  default = null
}

variable "platform_data_analytics" {
  description = "platform-data-analytics contract v1 (optional; null when the producer is not enabled)."
  type = object({
    blob = optional(object({
      id        = string
      endpoint  = string
      container = optional(string, "adapter")
    }))
    adls = optional(object({
      id         = string
      endpoint   = string
      filesystem = optional(string, "adapter")
    }))
    data_explorer = optional(object({
      id       = string
      uri      = string
      database = optional(string, "adapter")
      table    = optional(string, "Records")
    }))
    search = optional(object({
      id       = string
      endpoint = string
      index    = optional(string, "adapter-records")
    }))
  })
  default = null
}

variable "foundation_network" {
  description = "foundation-network contract v1 (optional; null when the producer is not enabled)."
  type = object({
    resource_group_name  = string
    location             = string
    internal_dns_zone    = optional(string)
    internal_dns_zone_id = optional(string)
    private_dns_zones = optional(map(object({
      id   = string
      name = string
    })), {})
    subnets = map(object({
      id             = string
      name           = string
      address_prefix = string
    }))
  })
  default = null
}
