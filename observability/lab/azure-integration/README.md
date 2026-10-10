# lab/azure-integration (component `obs-azure-integration`)

**Owner:** observability. **Purpose:** Datadog ↔ Azure integration for the lab subscription(s) through
`modules/azure-integration`.

* **Consumes:** nothing for secrets. `app_auth = secret` takes the client secret from the pipeline input `TF_VAR_datadog_azure_client_secret` (read from Delinea DSV just in time).
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
* `log_management`: accepted and ignored since package 3.0.0. The 2.x dashboard / log-based metrics / index /
  pipeline moved to `extras/content/modules/log-management` (optional); parsing, tags, dedupe and quotas of the
  Azure platform logs happen in the Observability Pipelines pipeline of `obs-telemetry-transport`.

## Providers
* The Datadog provider reads `DD_API_KEY` and `DD_APP_KEY` from the pipeline environment (Delinea DSV, masked variables).
* `api_url = https://api.<site>/`

## Secrets
Default `app_auth = secretless`: no secret. With `app_auth = secret` the client secret arrives as the sensitive
variable `datadog_azure_client_secret` (pipeline, from DSV) and lands in state as `datadog_integration_azure.client_secret`
(datadog provider 4.25 has no write-only argument) - documented exception. No data source reads secrets.

## Cost
No Azure cost. Datadog bills the Azure-monitored hosts and containers it discovers; tag filters bound this.

## Teardown
Destroy removes the Datadog integration and the role assignments. The Entra app stays (bootstrap owns it).

## Duplicate prevention
* Native log forwarding (subscription, resource and Entra logs) is off. It is mutually exclusive with the Event Hubs
  path (validation).
* Datadog automated log forwarding is not used. See `modules/azure-integration/README.md`.
