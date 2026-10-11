# modules/tagging

The single tagging function of the package (pure, no providers). Every path that emits telemetry or tags gets its
tags from this module, so a service carries the same tags in metrics, traces, logs, profiles, RUM and Azure resource
tags.

Inputs:

* `policy`: the decoded tag policy (`config/tag-policy.yaml`, `schemas/tag-policy.v1.schema.json`); null means the
  package default.
* `identity`: canonical key -> value. Missing optional keys get the policy defaults.
* `extra_tags`: additional tags. Canonical policy keys always win over them.
* `enforce_required`: override the policy's `enforce_required`.

With enforcement on, a missing required key fails the plan (precondition on `tags`; the names are in
`missing_required`).

Normalisation (Datadog tag rules):

* aliases and value maps first (`development` -> `dev`, `production` -> `prod`);
* then lower case;
* characters other than letters, digits and `_-:./` become `_`, and repeated `_` collapse;
* 200 characters at most.

`env`, `service` and `version` are the reserved unified service tags.

| Output | Used by |
|---|---|
| `tags`, `unified`, `extra_tags` | every module |
| `dd_tags`, `dd_tags_list`, `dd_tags_extra`, `dd_tags_space` | Datadog libraries (`DD_TAGS`), Agents (`DD_TAGS`, `datadog.tags`) |
| `otel_resource_attributes(_string)` | OpenTelemetry SDKs (otel mode only) and the OTel gateway tag overlay |
| `k8s_labels`, `k8s_annotations`, `pod_labels_as_tags` | UST labels `tags.datadoghq.com/*`, `ad.datadoghq.com/tags`, Agent `podLabelsAsTags` |
| `azure_tags`, `azure_tag_key_map` | Azure resource tags (imported by the Datadog Azure integration); Fluent Bit / pipeline Azure tag mapping |
| `fluent_bit_env`, `rum_global_context` | Fluent Bit Lua; RUM `globalContext` |

`tools/tags/tag_policy.py` is the Python mirror (onboarding render, telemetry_verify, coverage tools). Parity with
this module is tested (`tests/tags/test_tags.py`).
