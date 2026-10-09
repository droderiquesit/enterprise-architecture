variable "environment" {
  description = "Environment globals (ADR-0001 section 6)."
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

variable "settings" {
  description = "obs-monitoring settings (environments/<env>/environment.yaml components.obs-monitoring)."
  type = object({
    rendered_dir        = optional(string) # default: observability/onboarding/rendered/<env>
    routing_file        = optional(string) # default: observability/onboarding/routing/<env>.yaml
    synthetics_enabled  = optional(bool, true)
    synthetics_paused   = optional(bool, true) # lab default: created paused (cost); set false to run
    private_location_id = optional(string)
    service_dashboards  = optional(bool, true)
    overview_dashboard  = optional(bool, true)
    journey             = optional(list(string), ["hello-frontend", "hello-bff", "hello-orders-api", "hello-catalog-api", "hello-durable", "hello-partner-sim"])
    service_catalog     = optional(bool, true)
    slos_enabled        = optional(bool, true)
    create_webhooks     = optional(bool, false)
  })
  default = {}
}

variable "obs_prereqs" {
  description = "obs-prereqs contract (only the fields used)."
  type = object({
    datadog_site = string
    rum = object({
      applications = map(object({
        application_id = string
        name           = string
      }))
    })
  })
}

variable "contract_references" {
  description = <<-EOT
    Flat map '<contract>.<dot.path>' -> value for every materialized upstream contract (deploy-*, platform-*,
    obs-telemetry-transport). Produced by the pipeline with
    `observability/tools/onboarding/render.py references --contracts-dir <dir> --out references.auto.tfvars.json`.
    Services whose presence_ref is absent here are skipped (component not deployed in this profile).
  EOT
  type        = map(string)
  default     = {}
}
