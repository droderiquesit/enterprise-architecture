# modules/rum

Real User Monitoring for browser frontends. You can create the RUM application here or adopt one the organisation
already has.

| `applications.<key>.mode` | What happens |
|---|---|
| `create` (default) | `datadog_rum_application` named `name`, of type `type` (default `browser`) |
| `existing` | no resource is created; give `application_id` and `client_token` from the application settings in Datadog |

Outputs:

* `applications`: key -> `{application_id, client_token, name, type, mode}`. The client token is Datadog's
  browser-facing credential (shipped to every visitor), so it is non-sensitive. API and application keys are never
  involved.
* `browser_config`: key -> the `datadogRum.init` options the frontend renders into its runtime config:
  * `applicationId`, `clientToken`, `site`;
  * `service`, `env`, `version`, normalised by the tag policy;
  * `sessionSampleRate` and `sessionReplaySampleRate`, from fleet policy `rum` (replay **0** by default);
  * `allowedTracingUrls`: `[{match: <origin>, propagatorTypes: ["tracecontext"]}]` (W3C trace context, fleet policy `rum.propagator_types`) for the first-party
    API origins (exact `https://` origins only), so RUM sessions join the backend traces of both Datadog and
    OpenTelemetry-instrumented services;
  * `globalContext`: the tag-policy identity (team, owner, domain, tier, ...). The app applies it with
    `datadogRum.setGlobalContextProperty`.

Create the application before the frontend deploys (the lab: `obs-prereqs`, settings
`rum_applications.<key>.{mode, application_id, client_token}`).

## Test
`terraform init -backend=false && terraform test` in this directory (mock providers, no credentials): `tests/rum.tftest.hcl`.
