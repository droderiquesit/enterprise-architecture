# foundation/modules/naming

Shared **code** module (not a component; ADR-0001 §3 rule 5, §7): deterministic CAF names. No `random_*`
providers, so names are reproducible from configuration and never change between plans.

- `names.<type>` = `<prefix>-<abbr>-<workload>-<env>-<regionShort>` (max 63 chars), abbreviations from the
  [CAF list](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations)
  (`local.abbreviations` in `main.tf`).
- `unique.{storage, container_registry, key_vault, cosmos, globally_unique}` = dash-free / length-limited globally
  unique names with the 5-hex `suffix` = `substr(sha1("<subscription_id>/<prefix>/<env>"), 0, 5)`.

| Input | Notes |
|---|---|
| `prefix` | 2-6 lowercase alphanumerics (`environment.name_prefix`, default `eh`) |
| `environment` | 2-8 lowercase alphanumerics |
| `location` | Azure region; known regions map to a short code, others fall back to the first 4 non-vowel characters |
| `subscription_id` | only hashed into `suffix` |
| `workload` | component short name (`network`, `tfstate`, ...) |

Outputs: `names`, `unique`, `suffix`, `region_short`. Interface frozen: changing a name renames resources.

Validation: `tools/validate/terraform.sh foundation/modules/naming` (fmt + validate); behaviour is covered by the tests of
every root that uses it (e.g. `bootstrap`, `foundation/network`).
