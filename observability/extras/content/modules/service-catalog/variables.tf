variable "services" {
  description = "Software Catalog entities (v3, kind service) keyed by service name."
  type = map(object({
    display_name = optional(string)
    description  = optional(string, "")
    team         = string
    owner        = string
    env          = string
    tier         = optional(string, "medium")
    lifecycle    = optional(string, "production")
    type         = optional(string, "web")
    languages    = optional(list(string), [])
    depends_on   = optional(list(string), [])
    component_of = optional(list(string), [])
    repository   = optional(string)
    runbook_url  = string
    tags         = optional(list(string), [])
    contacts = optional(list(object({
      name    = optional(string)
      type    = string
      contact = string
    })), [])
    dashboard_url = optional(string)
  }))
}

variable "systems" {
  description = "Optional v3 system entities keyed by system name (components are service:<name> refs)."
  type = map(object({
    display_name = optional(string)
    owner        = string
    components   = list(string)
  }))
  default = {}
}
