# app-env — application environment composer (pure module)

Owner: applications layer. No providers, no resources: called by every deployment root in `applications/deployments`.

**Purpose**: wraps the observability instrumentation hook (`observability/modules/instrumentation`) and adds what the
deployment owns — `AZURE_CLIENT_ID` (+ `AZURE_CREDENTIAL_MODE` for Python), `FAULTS_ENABLED`, `FAULT_TOKEN` as a Delinea
DSV reference, `PORT`, `LOG_LEVEL`, `GIT_COMMIT` and the service's own `extra_env` / `secret_env`. Secret settings are
always `dsv://<path>#<element>` references resolved by the application at start-up (ADR-0001 §14); no secret value
passes through this module.

**Inputs**: `service` (unified service identity), `runtime`, `architecture`, `telemetry` (obs-telemetry-transport
contract v3 fields), optional `identity_client_id`, `faults`, `port`, `extra_env`, `secret_env` and the fleet-policy
overrides (`apm`, `logs`, `profiling`, `agent_sidecar`, `serverless_init`). See `variables.tf` (every variable is described).

**Outputs**: `env` / `app_settings` (same map), `secret_env`, `dsv_env`, the platform patches `container_app_patch`,
`aci_sidecar`, `k8s_patch_object`, labels/annotations/tags, and the effective `log_collector`, `log_route`, `apm`,
`profiling` decisions. See `outputs.tf`.

**Tests**: exercised by every root's `terraform test` (mock providers), e.g.
`bash tools/validate/terraform.sh applications/deployments/core-aca`.
