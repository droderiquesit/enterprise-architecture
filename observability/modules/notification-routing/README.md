# modules/notification-routing

Maps route keys used by manifests to Datadog @-handles for one environment (`schemas/notification-routing.v1.schema.json`),
optionally creating `datadog_webhook`s (`create_webhooks = true`). Manifests never contain raw handles.
