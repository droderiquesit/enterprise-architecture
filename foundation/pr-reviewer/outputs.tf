output "contract" {
  description = "foundation-pr-reviewer contract v1 (catalog/contracts/foundation-pr-reviewer.v1.schema.json). No secrets."
  value = {
    resource_group_name   = azurerm_resource_group.this.name
    function_app_id       = azurerm_function_app_flex_consumption.this.id
    function_app_name     = azurerm_function_app_flex_consumption.this.name
    function_url          = "https://${azurerm_function_app_flex_consumption.this.default_hostname}"
    webhook_path          = "/api/ado-webhook"
    webhook_url           = "https://${azurerm_function_app_flex_consumption.this.default_hostname}/api/ado-webhook"
    webhook_username      = var.settings.webhook_username
    webhook_secret_ref    = local.webhook_ref
    deployment_container  = "${azurerm_storage_account.this.primary_blob_endpoint}${azurerm_storage_container.deploy.name}"
    storage_account_name  = azurerm_storage_account.this.name
    queue_name            = azurerm_storage_queue.jobs.name
    identity_id           = azurerm_user_assigned_identity.pr_reviewer.id
    identity_name         = azurerm_user_assigned_identity.pr_reviewer.name
    identity_client_id    = azurerm_user_assigned_identity.pr_reviewer.client_id
    identity_principal_id = azurerm_user_assigned_identity.pr_reviewer.principal_id
    network_mode          = var.settings.network_mode
    inbound_service_tag   = var.settings.restrict_to_azure_devops ? "AzureDevOps" : null
    status_context        = "eh-review/policy"
  }
}

output "dsv_desired_state" {
  description = "Desired Delinea DSV state for the pr-reviewer identity (non-sensitive). Converged by tools/secrets/dsv_apply.py."
  value       = local.dsv_desired_state
}
