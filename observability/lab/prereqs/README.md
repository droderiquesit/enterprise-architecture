# obs-prereqs (lab root)

- **Owner**: observability layer (monitoring-as-code content). Component id `obs-prereqs` (catalog/components.yaml).
- **Purpose**: create Datadog objects that must exist *before* applications deploy: the RUM application(s) whose id and
  client token the frontend bakes into its runtime `config.json`.
- **Consumed contracts**: none.
- **Produced contract**: `obs-prereqs` v1 (`catalog/contracts/obs-prereqs.v1.schema.json`):
  `{datadog_site, rum.applications.<key>.{application_id, client_token, name, type, site, service, session_sample_rate,
  session_replay_sample_rate, default_privacy_level, track_user_interactions}}`. Consumers: `deploy-frontend`
  (config.json), `obs-monitoring` (RUM references).
- **Why the client token is in a contract**: Datadog documents client tokens as the credential for end-user facing
  applications (API keys "cannot be used to send data from a browser ... as they would be exposed client-side").
  Every visitor downloads it with `config.json`; it only submits RUM data. API/application keys never leave Delinea DSV (pipeline masked variables only).
- **Settings** (`components.obs-prereqs`): `datadog_site` (default `datadoghq.com`), `rum_applications` map
  (default `{hello-frontend = {}}`; per app `type`, `service`, `session_sample_rate` 100, `session_replay_sample_rate` 0,
  `default_privacy_level` `mask-user-input`, `track_user_interactions` true). Names: `<prefix>-<env>-<key>`.
- **Credentials**: provider reads `DD_API_KEY`/`DD_APP_KEY` from the pipeline environment (read from Delinea DSV,
  `datadog-api-key`, `datadog-app-key`).
- **Cost at defaults**: no Azure cost. Datadog RUM is billed per session (1k-session units); the lab traffic generator
  produces ~2 browser journeys per run -> a few hundred sessions/month at 100% sampling; replay off.
- **Teardown / retention**: `terraform destroy` deletes the RUM application; already ingested RUM data follows the
  org's retention. Recreating it yields a new application id/token -> redeploy the frontend.
- **Networking**: Datadog SaaS API only (HTTPS egress from the deployment agent).
- **Limitations**: one Datadog org/site per environment.
- **Docs**: https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/rum_application ,
  https://docs.datadoghq.com/real_user_monitoring/browser/setup/ , https://docs.datadoghq.com/account_management/api-app-keys/#client-tokens
- **Checks**: `terraform init -backend=false && terraform validate && terraform test` (mock provider).
