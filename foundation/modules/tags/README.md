# foundation/modules/tags

Shared **code** module (ADR-0001 §7): the required tag set for every taggable lab resource —
`env, application, service, version, team, owner, domain, tier, region, managed_by, component, layer, cost_center,
expires_on, data_classification = synthetic, repository` — merged over `environment.tags`, with `extra` merged last.

| Input | Default | Notes |
|---|---|---|
| `environment` | — | `var.environment` of the calling root (name, location, owner, team, cost_center, expires_on, tags) |
| `component` | — | registry id, e.g. `foundation-network` |
| `layer` | — | `bootstrap`, `foundation`, `platform`, `applications` or `observability` |
| `service` / `version_tag` | `platform` / `n/a` | Datadog unified tags for infrastructure |
| `domain` / `tier` | `shared` / `infrastructure` | |
| `extra` | `{}` | additional tags |

Output: `tags`. Interface frozen.

Validation: `tools/validate/terraform.sh foundation/modules/tags`; tag values are asserted by the roots' tests.
