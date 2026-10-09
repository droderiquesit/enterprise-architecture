variable "settings" {
  description = "deploy-durable settings (environments/<env>/environment.yaml components.deploy-durable)."
  type = object({
    flex_app_key           = optional(string, "durable") # key in platform-functions contract `flex`
    faults_enabled         = optional(bool, false)
    activity_failure_rate  = optional(number, 0.1) # FAULT_ACTIVITY_FAILURE_RATE when faults_enabled (lab only)
    log_level              = optional(string, "information")
    trace_sample_ratio     = optional(number, 1)
    maximum_instance_count = optional(number, 10) # Flex scale ceiling (lab)
    instance_memory_in_mb  = optional(number, 2048)
    always_ready_instances = optional(number, 0) # 0 = scale to zero
    http_concurrency       = optional(number, 16)
    reconcile_schedule     = optional(string, "0 */30 * * * *")
    history_retention_days = optional(number, 7)
    payment_timeout_secs   = optional(number, 10)
    task_hub               = optional(string) # default "hellodurable<env>"
    # Upstream base URLs. Overrides only: when null they are derived from the optional upstream contracts
    # (orders: deploy-core-aca/aks apps["hello-orders-api"].url; inventory: deploy-appservice hello-inventory-api,
    # else deploy-core-aca/aks; partner: deploy-partner-sim.url). Kubernetes-internal *.svc.cluster.local URLs are
    # ignored. Still unset => status updates are skipped / reservation and payment simulated (hello-durable README).
    orders_api_url    = optional(string)
    inventory_api_url = optional(string)
    partner_api_url   = optional(string)
    # Network exposure. Durable HTTP functions are anonymous at the Functions layer, so the app must stay private:
    #   private-endpoint (default when foundation_network is provided): public access disabled + PE (sites).
    #   restricted: public endpoint with ip_restriction default Deny + allowed_ip_ranges (e.g. deploy agent egress IPs).
    network_mode      = optional(string, "auto")
    allowed_ip_ranges = optional(list(string), [])
    # Windows Consumption (Y1) app running only Reconciliation; created when platform-functions has
    # consumption_windows and this is true.
    windows_consumption_enabled = optional(bool, true)
  })
  default = {}

  validation {
    condition     = contains(["auto", "private-endpoint", "restricted"], var.settings.network_mode)
    error_message = "network_mode must be auto, private-endpoint or restricted."
  }
  validation {
    condition     = var.settings.maximum_instance_count >= 1 && var.settings.maximum_instance_count <= 100 && contains([512, 2048, 4096], var.settings.instance_memory_in_mb)
    error_message = "maximum_instance_count 1-100 (lab ceiling) and instance_memory_in_mb 512, 2048 or 4096."
  }
  validation {
    condition     = var.settings.activity_failure_rate >= 0 && var.settings.activity_failure_rate <= 1
    error_message = "activity_failure_rate must be 0..1."
  }
}
