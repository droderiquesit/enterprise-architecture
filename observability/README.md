# Observability package (Datadog collection and tagging for Azure)

Version: see `VERSION` (semantic versioning). Release notes: `CHANGELOG.md`. Upgrade notes: `UPGRADING.md`.

A portable, versioned package that **connects Azure resources and workloads to Datadog** and makes every signal carry
the same tags. Telemetry flows through the most mature Datadog path each resource type supports:

* the Datadog Agent wherever it can run;
* Datadog tracing libraries with Single Step Instrumentation and the Continuous Profiler;
* Datadog Observability Pipelines as the central log pipeline;
* RUM for browsers;
* the Datadog Azure integration for platform metrics and resource tags.

The package works against existing enterprise infrastructure. It never creates networks, compute platforms,
databases or applications, and it needs nothing outside this directory.

Monitors, SLOs and dashboards are **not** part of the package (since 3.0.0). They already exist in your
organisation and select on the tags this package makes consistent. The 2.x monitoring content lives on, optional
and unreleased, in `extras/content/` of the source repository.

| What | Where |
|---|---|
| Tag policy (the core product) | `config/tag-policy.yaml`, `schemas/tag-policy.v1.schema.json`, `modules/tagging` (one tagging module, used on every path), `tools/tags/` (Python mirror + read-only Datadog tools) |
| Fleet collection policy | `config/fleet-policy.yaml`, `schemas/fleet-policy.v1.schema.json`, `modules/fleet-policy` (per-workload decision), `modules/fleet-inventory` (one inventory input -> collection plan per resource) |
| Log pipeline | `modules/observability-pipeline` (`datadog_observability_pipeline`), `config/observability-pipelines/*.vrl`; Worker on Container Apps (`modules/telemetry-transport`) or AKS (`modules/kubernetes`) |
| Collection | `modules/{azure-integration,diagnostic-settings,azure-logs,telemetry-transport,fluent-bit,otel-collector,host-agents,kubernetes,dbm}`, `config/{fluent-bit,otel}` |
| APM / profiling / RUM | `modules/instrumentation` (per-workload hook), `modules/rum` (create or existing application), `modules/fleet-automation` (optional Agent upgrade window) |
| Onboarding | `schemas/onboarding-manifest.v2.schema.json`, `tools/onboarding/{validate,render,migrate_v1}.py` |
| Verification | `tools/verify/telemetry_verify.py`, `tools/tags/check_coverage.py`, `tools/markers/send_deployment_event.py`, `modules/deployment-markers` |
| Release / pipelines / example | `tools/release/package.sh`, `pipelines/templates/*.yml`, `examples/existing-environment/` |

Status vocabulary:

* Everything here is **implemented**: static validation, `terraform test` with mock providers, and unit tests with
  recorded API responses.
* The Fluent Bit -> Worker forward path, the VRL programs, the Worker bootstrap, the APM gateway Agent, the OTel
  gateway, the DBM checks and the Linux installer are **locally verified** with docker (`tests/transport/`).
* Nothing has been deployed or verified against a live Datadog organisation by these tests.

## 1. How it works

```
config/tag-policy.yaml ----> modules/tagging ----------------------------------------------.
config/fleet-policy.yaml --> modules/fleet-policy (per workload) / fleet-inventory (fleet)   |
                                       |                                                    v
manifests (v2: identity + tags + resources) -> render.py -> rendered/<env>/*.json (committed, CI --check)
                                       |
    +------------------+---------------+-----------------+------------------+--------------------+
    | Azure integration| diagnostic    | Observability   | Agents (AKS Helm,| instrumentation    |
    | (metrics + tags) | settings ->   | Pipelines       | hosts, APM       | hook (env / patch) |
    |                  | Event Hubs    | (Worker)        | gateway, DBM)    | + RUM application  |
    +------------------+---------------+-----------------+------------------+--------------------+
```

Every module that emits telemetry or tags derives its tags from `modules/tagging`:

* Agent `DD_TAGS`;
* `ad.datadoghq.com/tags`, the UST labels and `podLabelsAsTags`;
* tracer `DD_ENV` / `DD_SERVICE` / `DD_VERSION` / `DD_TAGS`;
* the OTel gateway's `transform/eh_tag_policy`;
* Fluent Bit record tags and the Observability Pipelines tag processor;
* Azure resource tags;
* the RUM global context.

## 2. Tag policy

`config/tag-policy.yaml` lists the canonical keys:

* the reserved `env`, `service` and `version`;
* `team`, `owner`, `application`, `domain`, `tier`, `region` and `managed_by` (required);
* `cost_center` and `component` (optional).

Each key carries its value map (for example `production -> prod`), aliases, allowed values, OTel attributes and the
Azure tag keys it reads. Values are normalised to Datadog rules: lower case; characters other than letters, digits
and `_-:./` become `_`; repeated `_` collapse; at most 200 characters.

Adopt it in this order:

1. `tools/tags/derive_from_monitors.py` reads your existing monitors and SLOs read-only and proposes the policy your
   alerting already depends on.
2. `tools/tags/check_coverage.py` reports which monitored scopes miss which tags in live data (logs, spans, hosts).
3. Onboard the services. Guide: `docs/guides/datadog-tagging.md` (source repository).

## 3. Fleet collection

`config/fleet-policy.yaml` is the single switch board:

* `log_pipeline`: `observability_pipelines` (default) or `fluent_bit_direct` (2.x).
* `logs.node_collector`: `agent` or `fluent_bit`.
* `apm.mode`: `datadog` (default), `otel` or `none`. Exceptions: Azure Functions and Durable Functions stay on
  OpenTelemetry, and Windows services fall back to OpenTelemetry.
* `apm.managed_runtime_path`: `agent_gateway` (default) or `serverless_init` (opt-in, ACA only).
* Profiling types per runtime, DSM, DBM propagation, sampling, ignored resources.
* Agent version, Remote Configuration and remote updates, OP Worker sizing, RUM sampling and replay.

Overrides apply per architecture and per environment. The authoritative path per resource type and signal, the
duplicate-prevention rules and the robustness of every hop are in `modules/README-transport.md`. The per-resource
matrix, including unsupported combinations, is in `docs/guides/datadog-fleet-collection.md` (source repository).

## 4. Install (consumer)

Prerequisites:

* Terraform >= 1.14 (tested 1.16.5) and the DataDog/datadog provider `~> 4.25`.
* Python 3.11+ with `pyyaml` and `jsonschema`, only for validate and render in CI.
* A Datadog API key and application key in Delinea DevOps Secrets Vault (DSV). The package uses no Azure Key Vault
  (section 9).

Steps:

1. Pick a release: `observability-<version>.tar.gz` and its `.sha256`.
2. Copy `examples/existing-environment/` into your repository. Set `package.lock.json` and run `./vendor.sh`.
3. Write one manifest per service (`schemas/onboarding-manifest.v2.schema.json`), then:
   ```
   python3 .vendor/observability-<v>/tools/onboarding/validate.py --manifests manifests/prod --env prod --strict
   python3 .vendor/observability-<v>/tools/onboarding/render.py render --manifests manifests/prod --env prod --out rendered/prod
   ```
   Commit `rendered/prod/*.json`. A custom tag policy goes in with `--tag-policy`.
4. Run `terraform init`, `terraform plan -out tfplan` and `terraform apply tfplan`, or use the ADO templates in
   `pipelines/`. Provider credentials come from `DD_API_KEY` / `DD_APP_KEY` (from DSV), never from tfvars.
5. Hand the `instrumentation` output (tags, env, patches, `app_requirements`) to the application owners.

## 5. Upgrade, rollback, removal

* **Upgrade:** read `UPGRADING.md`. Bump `package.lock.json`, `vendor.sh --update-sources`, re-render, review the
  plan, apply.
* **Rollback:** re-vendor the previous version, re-render, plan and apply. The rendered output is committed, so
  `git revert` plus apply restores the previous state.
* **Removal:** `terraform destroy` removes only what the root created. That covers:
  * Datadog-side objects: integration, pipeline, RUM application, fleet schedule;
  * diagnostic settings;
  * Agent / Worker Helm releases, VM extensions and collector Container Apps.

  Monitored resources and business data are never in the state.

## 6. Versioning policy

Semantic versioning of the whole package (`VERSION`, tag `observability-v<version>`):

* **MAJOR**: a breaking manifest, schema, policy or contract change; a removed or renamed module input or output; a
  changed default collection path.
* **MINOR**: new modules, optional inputs, new supported resource types.
* **PATCH**: fixes.

`tools/release/package.sh` builds a deterministic tarball + sha256. It ships no `extras/` and no lab roots. The build
fails when a file references paths outside the package, remote state, or a real subscription id.

## 7. Pipelines

`pipelines/templates/`:

* `validate-onboarding.yml`: manifest validation against the tag policy, plus the rendered drift check.
* `terraform-plan.yml` and `terraform-apply.yml`.
* `telemetry-verify.yml`: bounded polling. Expected tags come from `rendered/<env>`, and the pipeline tag comes from
  the fleet policy.
* `deployment-marker.yml`.
* `dsv-secrets.yml`.

Reference the templates from the package repository pinned to a release tag.

## 8. Azure platform and control-plane logs

* `modules/azure-logs` exports the Activity Log and, optionally, Entra ID.
* `modules/diagnostic-settings` applies tiered categories (`security | standard | verbose`).
* Both write to Event Hubs. The **Observability Pipelines Worker** reads the hubs through the Kafka endpoint, then
  unwraps, splits, shapes (Datadog Azure forwarder shape), dedupes, samples and applies quotas, and adds the
  resource-scope tags of the owning service (`modules/fleet-inventory` `scope_tags`). With `fluent_bit_direct`, the
  2.x Fluent Bit aggregator does the same.

Guide: `docs/guides/azure-logs-to-datadog.md` (source repository).

## 9. Secrets: Delinea DSV

No secret value is an input, output or state value of this package. Every secret is a reference
`dsv://<path>#<element>`, read at run time by the workload with its managed identity.

| Consumer | How the secret is read |
|---|---|
| Datadog Agents (AKS, VMs, ACI DBM, APM gateway on ACA) | `api_key: ENC[dsv://...]`, with dsv-fetch `agent-backend` as the secret backend. **Verified locally** for the APM gateway and the DBM Agent. |
| OP Worker on ACA | dsv-fetch writes a dotenv file (init container on the Consumption profile, refresher elsewhere). The Worker command refuses to start without it (fail closed). |
| OP Worker on AKS | Existing Secrets maintained by the Delinea dsv-k8s syncer (`apiKeyExistingSecret`, `op_worker.secret_env`). |
| Fluent Bit sidecars, DaemonSet, hosts | dsv-fetch env-yaml file. In Observability Pipelines mode the edge needs **no** Datadog key at all. |
| OTel gateway | dsv-fetch files. |
| Applications | Env values that are `dsv://` references, plus `DSV_*`. |
| Pipelines | `pipelines/templates/dsv-secrets.yml`. |

Documented exception: `apm.managed_runtime_path = serverless_init`. Datadog serverless-init 1.10.4 does not resolve
`ENC[]` (verified locally: it sent the literal value), so `DD_API_KEY` must be a Container Apps secret. That option
is opt-in only.

## 10. Known limitations

* Live behaviour against Datadog has not been exercised:
  * the Worker running the pipeline definition;
  * Kafka SASL against Event Hubs;
  * SSI injection and profiles in a real cluster.

  The local tests stop where Datadog itself is required (API key validation, Remote Configuration).
* DogStatsD (custom and runtime metrics of Datadog libraries) is unavailable behind the APM gateway, because
  Container Apps ingress is TCP-only. Use `serverless_init`, or keep `apm.mode = otel` for workloads that need custom
  metrics there.
* Windows hosts and Azure Functions stay on OpenTelemetry. The Datadog profiler supports neither .NET Function Apps
  nor Python on Functions (preview).
* AKS workload-identity tokens with DSV are not verified. The fallback is the dsv-k8s syncer
  (`api_key.mode = existing`).
