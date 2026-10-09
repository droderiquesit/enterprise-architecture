# Optional Entra app registration for the Datadog Azure integration (settings.datadog_integration.enabled).
#
# Credentials: Datadog "Secretless Auth" (recommended by Datadog; OIDC workload identity federation) is used when
# federated_issuer/federated_subject are set - copy both from the Datadog Azure integration tile. Secretless Auth is
# not available on US1-FED/US2-FED or sovereign clouds; there, create a client secret OUT-OF-BAND and store it in
# Delinea DSV (see README "Datadog app registration"). Terraform never creates a client secret, so none is in state.
# The Datadog-side `datadog_integration_azure` resource is owned by observability (obs-azure-integration), which
# consumes the client_id/tenant_id from the bootstrap contract.
locals {
  dd               = local.s.datadog_integration
  dd_enabled       = local.dd.enabled
  dd_secretless    = local.dd_enabled && local.dd.federated_issuer != "" && local.dd.federated_subject != ""
  dd_subscriptions = local.dd_enabled ? toset(concat([var.environment.subscription_id], local.dd.extra_subscription_ids)) : toset([])
}

resource "azuread_application" "datadog" {
  count = local.dd_enabled ? 1 : 0

  display_name     = coalesce(local.dd.display_name, "${var.environment.name_prefix}-${var.environment.name}-datadog-azure-integration")
  owners           = local.dd.owners
  sign_in_audience = "AzureADMyOrg"
  notes            = "Datadog Azure integration (metrics/resource collection). Managed by bootstrap Terraform; no client secret in state."
  tags             = ["enterprise-hello", "datadog", "env:${var.environment.name}"]
}

resource "azuread_service_principal" "datadog" {
  count = local.dd_enabled ? 1 : 0

  client_id = azuread_application.datadog[0].client_id
  owners    = local.dd.owners
}

resource "azuread_application_federated_identity_credential" "datadog" {
  #checkov:skip=CKV_AZURE_249:GitHub Actions check; this credential trusts Datadog's OIDC issuer with an exact subject copied from Datadog.
  count = local.dd_secretless ? 1 : 0

  application_id = azuread_application.datadog[0].id
  display_name   = "datadog-secretless"
  description    = "Datadog OIDC workload identity federation (Secretless Auth)"
  issuer         = local.dd.federated_issuer
  subject        = local.dd.federated_subject
  audiences      = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "datadog_monitoring_reader" {
  for_each = local.dd_subscriptions

  scope                = "/subscriptions/${each.value}"
  role_definition_name = "Monitoring Reader"
  principal_id         = azuread_service_principal.datadog[0].object_id
  principal_type       = "ServicePrincipal"
  description          = "Datadog Azure integration (metrics + resource metadata)"
}
