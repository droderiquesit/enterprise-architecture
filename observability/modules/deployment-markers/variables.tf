variable "services" {
  description = "Services that receive deployment markers: name -> {env, team, repository_url}."
  type = map(object({
    env            = string
    team           = optional(string)
    repository_url = optional(string)
  }))
}

variable "datadog_site" {
  description = "Datadog site, e.g. datadoghq.com, datadoghq.eu, us3.datadoghq.com."
  type        = string
  default     = "datadoghq.com"
}

variable "script_path" {
  description = "Path of send_deployment_event.py as seen by the pipeline agent."
  type        = string
  default     = "tools/markers/send_deployment_event.py"
}
