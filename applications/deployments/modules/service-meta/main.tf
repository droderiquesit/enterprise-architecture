# Static metadata of the Enterprise Hello services (unified tags: team/domain/tier/owner, runtime, artifact).
# Mirrors observability/onboarding/<env>/*.yaml metadata so telemetry tags and Datadog onboarding agree.
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
}

locals {
  services = {
    "hello-frontend"      = { team = "web", domain = "storefront", tier = "high", owner = "web@example.com", runtime = "browser", artifact = "svc-frontend", identity = "hello-frontend" }
    "hello-bff"           = { team = "web", domain = "storefront", tier = "critical", owner = "web@example.com", runtime = "dotnet", artifact = "svc-bff", identity = "hello-bff" }
    "hello-orders-api"    = { team = "orders", domain = "orders", tier = "critical", owner = "orders@example.com", runtime = "dotnet", artifact = "svc-orders-api", identity = "hello-orders-api" }
    "hello-inventory-api" = { team = "orders", domain = "inventory", tier = "high", owner = "orders@example.com", runtime = "dotnet", artifact = "svc-inventory-api", identity = "hello-inventory-api" }
    "hello-catalog-api"   = { team = "catalog", domain = "catalog", tier = "high", owner = "catalog@example.com", runtime = "python", artifact = "svc-catalog-api", identity = "hello-catalog-api" }
    "hello-dbadapter"     = { team = "data-platform", domain = "data", tier = "low", owner = "data-platform@example.com", runtime = "python", artifact = "svc-dbadapter", identity = "hello-dbadapter" }
    "hello-worker"        = { team = "fulfillment", domain = "notifications", tier = "medium", owner = "fulfillment@example.com", runtime = "python", artifact = "svc-worker", identity = "hello-worker" }
    "hello-durable"       = { team = "fulfillment", domain = "fulfillment", tier = "critical", owner = "fulfillment@example.com", runtime = "dotnet", artifact = "svc-durable", identity = "hello-durable" }
    "hello-functions"     = { team = "platform-engineering", domain = "audit", tier = "medium", owner = "platform-engineering@example.com", runtime = "python", artifact = "svc-functions", identity = "hello-functions" }
    "hello-partner-sim"   = { team = "fulfillment", domain = "payments", tier = "low", owner = "fulfillment@example.com", runtime = "python", artifact = "svc-partner-sim", identity = "hello-partner-sim" }
    "hello-jobs"          = { team = "fulfillment", domain = "fulfillment", tier = "low", owner = "fulfillment@example.com", runtime = "python", artifact = "svc-jobs", identity = "hello-jobs" }
    "hello-traffic"       = { team = "platform-engineering", domain = "testing", tier = "low", owner = "platform-engineering@example.com", runtime = "python", artifact = "svc-traffic", identity = "hello-traffic" }
    "hello-logicapps"     = { team = "fulfillment", domain = "integration", tier = "low", owner = "fulfillment@example.com", runtime = "dotnet", artifact = "svc-logicapps", identity = "hello-logicapps" }
  }
}

output "services" {
  description = "Service id -> {team, domain, tier, owner, runtime, artifact, identity}."
  value       = local.services
}
