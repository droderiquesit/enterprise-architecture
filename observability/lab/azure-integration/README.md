# lab/azure-integration (component `obs-azure-integration`)

**Owner:** observability. **Purpose:** Datadog ↔ Azure integration for the lab subscription(s) through
`modules/azure-integration`.

* **Consumes:** optional `foundation_identity.key_vault_id`, which holds the app registration client secret.
* **Produces:** no contract. Outputs: `integration_id`, `mode`, `azure_logs_dashboard_url`, `azure_log_metrics`,
  `native_log_forwarding`.

## Settings
* `datadog_site`
* `mode`: when null, the mode is `app_registration` if `app_client_id` is set, else `none`. Nothing is deployed
  until bootstrap has created the Entra app.
* `app_client_id`, `app_auth` (`secret` | `secretless`), `app_service_principal_id` (enables the Monitoring
  Reader assignment for each subscription)
* `client_secret_name`, `extra_subscription_ids`
* `metric_tag_filters`: the default includes only resources tagged `application:enterprise-hello`
* `custom_metrics_enabled`, `resource_collection_enabled`
* `native_monitor_id`
* `native_logs` (mode = native): `{ subscription_logs, resource_logs, aad_logs, tag_filters }`, all off. The Event
  Hubs path of `obs-diagnostics` is authoritative.
* `eventhub_log_forwarding`: mirror of what `obs-diagnostics` exports (`activity_logs = true`,
  `resource_logs = true`, `entra = false`). Validation fails when `native_logs` would forward the same source.
* `log_management` (`modules/log-management`): `dashboard` (true), `metrics` (true), `index` (false: org-wide
  object, read the index-order note in the module README), `index_retention_days`, `index_daily_limit`, `pipeline`
  (false), `dashboard_entra`

## Providers
* The Datadog provider reads `DD_API_KEY` and `DD_APP_KEY` from the pipeline environment (Key Vault).
* `api_url = https://api.<site>/`

## Secrets
With `app_auth = secret`, the client secret is read with a data source and lands in state (sensitive) as
`datadog_integration_azure.client_secret`. Use `secretless` to avoid that.

## Cost
No Azure cost. Datadog bills the Azure-monitored hosts and containers it discovers; tag filters bound this.

## Teardown
Destroy removes the Datadog integration and the role assignments. The Entra app stays (bootstrap owns it).

## Duplicate prevention
* Native log forwarding (subscription, resource and Entra logs) is off. It is mutually exclusive with the Event Hubs
  path (validation).
* Datadog automated log forwarding is not used. See `modules/azure-integration/README.md`.
