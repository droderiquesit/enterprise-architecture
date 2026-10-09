variable "applications" {
  description = "RUM applications keyed by a stable key (normally the frontend service name)."
  type = map(object({
    name = string
    type = optional(string, "browser")
  }))

  validation {
    condition     = alltrue([for a in values(var.applications) : contains(["browser", "ios", "android", "react-native", "flutter", "roku", "electron", "unity", "kotlin-multiplatform"], a.type)])
    error_message = "Unsupported RUM application type."
  }
}
