# Deterministic CAF-style naming. No random providers: names must be reproducible
# from configuration so that plans are stable and existing resources are never renamed.
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
}

variable "prefix" {
  type        = string
  description = "Short organisation/lab prefix, e.g. \"eh\"."
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.prefix))
    error_message = "prefix must be 2-6 lowercase alphanumerics starting with a letter."
  }
}

variable "environment" {
  description = "Environment name (2-8 lowercase alphanumerics), e.g. \"dev\"."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.environment))
    error_message = "environment must be 2-8 lowercase alphanumerics."
  }
}

variable "location" {
  description = "Azure region name, e.g. \"swedencentral\"; mapped to a short code (unknown regions: first 4 consonants)."
  type        = string
}

variable "subscription_id" {
  description = "Subscription id; only hashed into the deterministic 5-char suffix of globally unique names."
  type        = string
}

variable "workload" {
  type        = string
  description = "Workload / component short name, e.g. \"net\", \"orders\"."
}

locals {
  region_short = lookup({
    eastus         = "eus", eastus2 = "eus2", westus2 = "wus2", westus3 = "wus3", centralus = "cus",
    northcentralus = "ncus", southcentralus = "scus", westeurope = "weu", northeurope = "neu",
    uksouth        = "uks", swedencentral = "sec", germanywestcentral = "gwc", francecentral = "frc",
    australiaeast  = "aue", japaneast = "jpe", canadacentral = "cac", southeastasia = "sea",
    centralindia   = "inc", brazilsouth = "brs", switzerlandnorth = "chn", norwayeast = "noe",
  }, var.location, substr(replace(var.location, "/[aeiou]/", ""), 0, 4))

  suffix   = substr(sha1("${var.subscription_id}/${var.prefix}/${var.environment}"), 0, 5)
  workload = lower(replace(var.workload, "/[^a-zA-Z0-9-]/", ""))
  base     = "${var.prefix}-%s-${local.workload}-${var.environment}-${local.region_short}"
  compact  = "${var.prefix}%s${replace(local.workload, "-", "")}${var.environment}${local.suffix}"

  # CAF abbreviations: https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations
  abbreviations = {
    resource_group       = "rg", virtual_network = "vnet", subnet = "snet", network_security_group = "nsg",
    route_table          = "rt", nat_gateway = "ng", public_ip = "pip", private_endpoint = "pep",
    firewall             = "afw", bastion = "bas", application_gateway = "agw", front_door = "afd",
    api_management       = "apim", key_vault = "kv", user_assigned_identity = "id",
    log_analytics        = "log", container_registry = "cr", aks = "aks", container_app_environment = "cae",
    container_app        = "ca", container_app_job = "caj", container_group = "ci", app_service_plan = "asp",
    web_app              = "app", function_app = "func", static_web_app = "stapp", logic_app = "logic",
    virtual_machine      = "vm", vm_scale_set = "vmss", batch_account = "ba", service_fabric = "sfmc",
    aro                  = "aro", sql_server = "sql", sql_database = "sqldb", sql_elastic_pool = "sqlep",
    sql_managed_instance = "sqlmi", postgresql = "psql", mysql = "mysql", cosmos = "cosmos",
    mongo_cluster        = "docdb", cassandra_mi = "mi-cass", managed_redis = "amr", storage = "st",
    confidential_ledger  = "ledger", service_bus = "sbns", event_hub = "evhns", data_explorer = "dec",
    synapse              = "synw", search = "srch", budget = "budget", action_group = "ag",
    automation           = "aa", ml_workspace = "mlw", dedicated_host_group = "dhg", disk_encryption_set = "des",
    devops_pool          = "mdp", dev_center = "dc", horizondb = "hzdb",
  }
}

output "region_short" {
  description = "Short region code used in names (e.g. \"sec\" for swedencentral)."
  value       = local.region_short
}

output "suffix" {
  description = "Deterministic 5-hex suffix: substr(sha1(\"<subscription_id>/<prefix>/<environment>\"), 0, 5)."
  value       = local.suffix
}

# Standard dash-separated names (<= 63 chars for most types).
output "names" {
  description = "Map of resource type key => <prefix>-<abbr>-<workload>-<env>-<region> (max 63 chars)."
  value       = { for k, v in local.abbreviations : k => substr(format(local.base, v), 0, 63) }
}

# Globally unique, dash-free, lowercase names (storage <= 24, ACR <= 50, Key Vault <= 24).
output "unique" {
  description = "Globally unique, length-limited names: storage, container_registry, key_vault, cosmos, globally_unique."
  value = {
    storage            = substr(format(local.compact, "st"), 0, 24)
    container_registry = substr(format(local.compact, "cr"), 0, 50)
    key_vault          = substr("${var.prefix}-kv-${substr(local.workload, 0, 6)}-${var.environment}-${local.suffix}", 0, 24)
    cosmos             = substr("${var.prefix}-cosmos-${local.workload}-${var.environment}-${local.suffix}", 0, 44)
    globally_unique    = substr("${var.prefix}-${local.workload}-${var.environment}-${local.suffix}", 0, 60)
  }
}
