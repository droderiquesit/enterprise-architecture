# Datadog tagging with the observability package

The observability package (4.0.0; since 3.0.0) does not create monitors, SLOs or dashboards. Its job is to connect Azure resources
and workloads to Datadog and to put **the same tags on every signal**, so that the monitors, SLOs and dashboards that
already exist in your organisation match:

* metrics, traces, logs and profiles;
* RUM;
* Azure resource tags and platform logs;
* DBM checks.

The tag policy is the contract; `modules/tagging` is the only code that renders it.

Status: implemented and tested offline (Terraform tests per path, Python parity tests, recorded API responses). Not
verified against a live Datadog organisation.

## 1. The policy

[`observability/config/tag-policy.yaml`](../../observability/config/tag-policy.yaml), schema
[`tag-policy.v1`](../../observability/schemas/tag-policy.v1.schema.json).

| Key | Required | Default | Source | Notes |
|---|---|---|---|---|
| `env` | yes | - | manifest `metadata.env` | reserved; `value_map: {development: dev, production: prod}`; OTel `deployment.environment.name` |
| `service` | yes | `platform` | manifest `metadata.service` | reserved; OTel `service.name` |
| `version` | yes | `n/a` | deployment (`DD_VERSION`) | reserved; deploy-time value, not in manifests |
| `team`, `owner`, `application`, `domain`, `tier`, `region`, `managed_by` | yes | `managed_by: terraform` | manifest metadata / Azure location | `owner` e-mail addresses normalise to `orders_example.com` |
| `cost_center`, `component` | no | - | manifest / environment | |

Fields per key:

* `key`: renames the key. It cannot be changed for `env`, `service` and `version`.
* `aliases`: the value is also emitted under extra keys, for example `environment`.
* `value_map`, `allowed_values`, `default`, `required`.
* `otel_attributes`: the OTel resource attributes read and written for the key.
* `azure_tag_keys`: the Azure resource tags that carry the value (first match wins).
* `k8s_label`.

Top-level fields:

* `static_tags`: tags on every signal.
* `environments.<env>.static_tags`.
* `enforce_required`: when on, a missing required value fails `terraform plan`.

Normalisation (`normalize: datadog`) is exactly Datadog's:

* lower case;
* characters other than letters, digits and `_-:./` become `_`;
* repeated `_` collapse, and leading or trailing `_` are removed;
* at most 200 characters.

The value you emit is therefore the value a monitor scope sees.

## 2. Adopt it from your existing monitors

```bash
# read-only (GET /api/v1/monitor, /api/v1/slo; a read-only application key is enough)
python3 observability/tools/tags/derive_from_monitors.py --site datadoghq.eu \
  --policy observability/config/tag-policy.yaml --out-json required-tags.json --out-md required-tags.md
```

The report lists every tag key and value your monitors and SLOs filter, exclude or group on. It covers metric scopes
and `by {}`, log, APM and RUM searches, service-check `.over()` / `.by()`, and SLO queries. It classifies each key as
`policy:<key>` (possibly `(alias)`), `policy:static`, `platform` (tags Datadog or Azure set themselves, such as
`host` and `kube_*`) or `unmapped`. For an unmapped key it suggests an alias when the key's values match an existing
policy key (for example monitors use `environment` where the policy says `env`). Edit a copy of the policy until every key your monitors depend on is either a policy key, an alias or a
static tag. Then check:

```bash
python3 observability/tools/tags/check_coverage.py --rendered observability/onboarding/rendered/dev \
  --policy my-tag-policy.yaml --requirements required-tags.json            # static: exit 1 on a required gap
python3 observability/tools/tags/check_coverage.py --rendered rendered/prod --env prod --live --minutes 60  # read-only live check
```

The static check compares the rendered tag sets with the policy and with the monitors' requirements, including value
mismatches such as monitors filtering `env:production` while services emit `env:prod`. The live check searches logs
and spans and lists the hosts of every rendered service. It reports services without data, events missing policy keys
and values that differ from the rendered set. Every Datadog call goes through a client that refuses anything but
reads (`ReadOnlyViolation`). Offline, `--fixtures <dir>` replays recorded responses
(`observability/tests/tags/fixtures/`).

## 3. Where the tags come from, per path

`modules/tagging` turns one identity (the manifest metadata + environment) into every representation.

| Path | Representation | Module |
|---|---|---|
| Datadog libraries (APM, profiles, logs injection) | `DD_ENV`, `DD_SERVICE`, `DD_VERSION`, `DD_TAGS` (other policy keys) | `instrumentation` |
| OpenTelemetry SDKs (`apm.mode = otel`) | `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`; never set in datadog mode (Datadog maps it to `DD_TAGS` - duplicates) | `instrumentation` |
| Kubernetes pods | UST labels `tags.datadoghq.com/{env,service,version}`, `ad.datadoghq.com/tags` annotation, policy labels + Agent `podLabelsAsTags` | `instrumentation`, chart `hello-service`, `kubernetes` |
| Datadog Agents (AKS, VM / VMSS, ACI sidecar, APM gateway, DBM) and serverless-init | `DD_TAGS` / `datadog.tags` / check `tags` | `kubernetes`, `host-agent-package`, `instrumentation`, `telemetry-transport`, `dbm` |
| Fluent Bit (Batch nodes; `fluent_bit_direct` fallback) | Lua `eh_finalize` static tags (never override record keys), Kubernetes label map, Azure tag map and scope tags | `fluent-bit` |
| Observability Pipelines | VRL tag processor: environment defaults, value maps, normalisation, resource-scope tags of platform logs; fills missing tags, never overwrites | `observability-pipeline` |
| OTel gateway (otel mode) | `transform/eh_tag_policy`: per `service.name`, inserts missing attributes, never overwrites | `otel-collector`, `telemetry-transport` |
| Azure resources | `azure_tags` (deploy roots merge them into the resource tags); the Datadog Azure integration imports them onto metrics | `instrumentation` / app-env |
| Azure platform logs | resource-scope tags (`fleet-inventory` `scope_tags`: resource id prefix -> owner tags) | `observability-pipeline` |
| RUM | `service`, `env`, `version` + `globalContext` (`setGlobalContextProperty`) | `rum` |

Tests per path: `modules/tagging/tests`, `modules/instrumentation/tests`, `modules/kubernetes/tests`,
`modules/host-agents/tests`, `modules/host-agent-package/tests`, `modules/dbm/tests`, `modules/fluent-bit/tests`, `modules/otel-collector/tests`,
`modules/rum/tests`, `observability/tests/tags`, `observability/tests/transport` (Lua, VRL and OTel overlays executed
with the real binaries), `tests/charts/test_datadog_tags.py`.

## 4. Rules that keep tags clean

* One value per key per signal: canonical keys always win over `extra_tags` and static tags. Edge collectors and
  pipelines only fill in missing keys.
* `version` is a deploy-time value. Infrastructure gets `n/a`, so `version` never appears as an empty tag.
* High-cardinality values (request ids, user ids) are never tags.
* With `enforce_required: true` a service without `team`, `owner`, `domain`, `tier` or `region` cannot be planned.
  The onboarding validator reports the same in CI (`validate.py --strict`).
* Changing a value (for example renaming a team) changes the tag on every path at the next apply. Monitors keyed on
  the old value stop matching, so run `check_coverage.py --requirements` before you merge.
