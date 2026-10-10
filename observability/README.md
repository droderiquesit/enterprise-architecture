# Observability package (Datadog collection and tagging for Azure)

Version: see `VERSION` (semantic versioning). Release notes: `CHANGELOG.md`. Upgrade notes: `UPGRADING.md`.

A portable, versioned package that **connects Azure resources and workloads to Datadog** and makes every signal carry
the same tags. Telemetry flows through the most mature Datadog path each resource type supports:

* the Datadog Agent wherever it can run (AKS nodes, VM / VMSS hosts via Azure Policy + VM Applications, a sidecar in
  ACI container groups) and Datadog serverless-init on Container Apps - one log collector per architecture;
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
| Collection | `modules/{azure-integration,diagnostic-settings,azure-logs,telemetry-transport,fluent-bit,otel-collector,kubernetes,dbm}`, hosts: `modules/{host-agents,host-agent-package,host-agent-policy}` (VM Applications + Azure Policy), `config/{fluent-bit,otel}` |
| Secret helper | `images/dsv-fetch` (static Go binary `dsv-fetch` 2.x: image + release zip; Delinea DSV with managed identity) |
| APM / profiling / RUM | `modules/instrumentation` (per-workload hook), `modules/rum` (create or existing application), `modules/fleet-automation` (optional Agent upgrade window) |
| Onboarding | `schemas/onboarding-manifest.v2.schema.json`, `tools/onboarding/{validate,render,migrate_v1}.py` |
| Verification | `tools/verify/telemetry_verify.py`, `tools/tags/check_coverage.py`, `tools/markers/send_deployment_event.py`, `modules/deployment-markers` |
| Release / pipelines / example | `tools/release/package.sh`, `pipelines/templates/*.yml`, `examples/existing-environment/` |

Status vocabulary:

* Everything here is **implemented**: static validation, `terraform test` with mock providers, and unit tests with
  recorded API responses.
* The Fluent Bit -> Worker forward path, the VRL programs, the Worker bootstrap, the APM gateway Agent, the OTel
  gateway, the DBM checks, the ACI Agent sidecar / ACA serverless-init sidecar, the Datadog chart rendered through
  the post-renderer and the VM Application Linux installer are **locally verified** with docker / helm
  (`tests/transport/`, `tests/kubernetes/`, `modules/host-agent-package/tests/`).
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
* `logs.collector` per architecture (4.0.0): `agent` (AKS, VM, VMSS), `agent_sidecar` (ACI), `serverless_init`
  (Container Apps), `azure` (App Service, Functions, Logic Apps: diagnostic settings), `fluent_bit` (Batch).
  `fluent_bit_direct` replaces every Agent-side collector by Fluent Bit. The 3.x key `logs.node_collector`
  (`agent` | `fluent_bit`) is still honoured on aks / vm / vmss.
* `logs.hosts`: files the host Agent tails (Linux, Windows) and Windows Event Log channels.
* `apm.mode`: `datadog` (default), `otel` or `none`. Exceptions: Azure Functions and Durable Functions stay on
  OpenTelemetry, and Windows services fall back to OpenTelemetry.
* `apm.managed_runtime_path`: `agent_gateway` (default), `serverless_init` (Container Apps default) or
  `agent_sidecar` (ACI default).
* Profiling types per runtime, DSM, DBM propagation, sampling, ignored resources.
* `agent.image` / `agent.version`: the single Agent pin of the fleet (Helm, VM Application, ACI sidecar, APM gateway;
  equal to `versions.yaml` `images.datadog_agent` in the source repository), `agent.serverless_init`, Remote
  Configuration (on) and remote updates (off), OP Worker sizing, RUM sampling and replay.

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
  * Agent / Worker Helm releases, the host policy assignment / gallery / VM Applications, and collector Container
    Apps (the Agent stays on enrolled hosts until the application is removed from their model).

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
| Datadog Agents (AKS node Agent, Cluster Agent, cluster-checks runners; VMs / VMSS Linux + Windows; ACI sidecar and DBM Agent; APM gateway on ACA) | One path: `api_key: ENC[dsv://...]`, with the static dsv-fetch binary (`agent-backend`) as `secret_backend_command` - copied by an init container (containers) or installed from the VM Application package (hosts). **Verified locally** for the APM gateway, the ACI sidecar, the DBM Agent and the chart render. |
| OP Worker on ACA | dsv-fetch writes a dotenv file (init container on the Consumption profile, refresher elsewhere). The Worker command refuses to start without it (fail closed). |
| OP Worker on AKS | dsv-fetch init container (workload identity) writes an in-memory env file from `op_worker.secret_env` (`NAME -> dsv://...`); the chart Secret holds only `ENC[]`. No synced Secret. |
| Container Apps serverless-init | Its start command runs dsv-fetch (managed identity), sources the key into its own process and execs `/datadog-init`; no Container Apps secret. |
| Fluent Bit (only `fluent_bit_direct` and Batch) | dsv-fetch env-yaml file. In Observability Pipelines mode the edge needs **no** Datadog key at all. |
| OTel gateway | dsv-fetch files. |
| Applications | Env values that are `dsv://` references, plus `DSV_*`. |
| Pipelines | `pipelines/templates/dsv-secrets.yml`. |

Datadog serverless-init 1.10.4 does not resolve `ENC[]` (verified locally: it sent the literal value); since 4.0.0
its start wrapper reads the key with dsv-fetch instead, so there is no Container Apps secret (verified locally).

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
* AKS workload-identity tokens with DSV are not verified. 4.0.0 removed the synced-Secret fallback
  (`api_key.mode = existing`); the documented alternative is the node pool's kubelet identity via IMDS.
* Not verified on Azure: the policy remediation's partial PUT on VMSS, gallery publishing with the publisher identity,
  the Windows MSI + `dsv-fetch.exe` ACLs on a real Windows host, the ACI `emptyDir` written by the uid 65532 init
  container, and the Helm post-renderer on the deploy agents (needs `sh` and `awk`). See `docs/known-limitations.md`
  in the source repository.
