# extras/content: optional monitoring content (2.0.0, not released)

Since package 3.0.0 the observability package configures collection and tags only. The monitoring content of 2.x is
kept here, unchanged and optional, for organisations that still want Terraform-managed monitors, SLOs, dashboards
and related objects. It is **not** part of the release tarball (`tools/release/package.sh` packages no `extras/`).
Its version is `VERSION` (2.0.0).

| Path | Content |
|---|---|
| `modules/` | `onboarding`, `monitors`, `slos`, `dashboards`, `synthetics`, `service-catalog`, `notification-routing`, `log-management` |
| `archetypes/` | global defaults, platform and profile archetypes (monitor definitions, runbook sections) |
| `schemas/` | archetype, notification-routing, onboarding-manifest v1 and rendered-service v1 schemas |
| `tools/onboarding/` | the v1 `validate.py` / `render.py` (archetype merge, routing) |
| `onboarding/` | the lab's v1 manifests (`dev/`), their rendered output (`rendered/dev/`, the input of the generated alert runbooks) and routing |
| `examples/existing-environment/` | the 2.x example's manifests, rendered output and routing |
| `lab/monitoring/` | the lab root `obs-monitoring` |
| `tests/` | the content tests (`python3 -m pytest observability/extras/content/tests`) |

Using it with package 3.0.0:

* Keep v1 manifests for the content (`tools/onboarding/migrate_v1.py --keep-content` writes v2 manifests that still
  carry the content sections; the core tools ignore them with a notice).
* Monitors select on the tags of the 3.0.0 tag policy. Keep the policy keys, or derive the policy from these monitors
  with `tools/tags/derive_from_monitors.py`.
* Pipeline signals changed in 3.0.0. Logs carry `telemetry.pipeline:observability-pipelines` with
  `log_pipeline = observability_pipelines`. The `pipeline.fluentbit_*` monitors apply only to the remaining Fluent
  Bit edge collectors.
