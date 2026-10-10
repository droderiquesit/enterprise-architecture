# modules/service-catalog

`datadog_software_catalog` entities (definition v3, kind service; optional kind system) with owner, contacts,
runbook/repository/dashboard links, tags, lifecycle, tier, languages, dependsOn, componentOf.

## Test
`terraform init -backend=false && terraform test` in this directory (mock providers, no credentials): `tests/catalog.tftest.hcl`.
