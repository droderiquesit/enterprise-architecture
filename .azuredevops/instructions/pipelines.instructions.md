---
applyTo: "azure-pipelines*.yml,pipelines/**/*.yml"
---
# Azure Pipelines YAML

- PR validation builds run source-branch YAML: they must stay credential-free (no service connections, no DSV fetch,
  no secret variables). Flag any credential use reachable from a PR build.
- Deployments only from `main` (and approved environments), through `pipelines/templates/universal.yml`.
- No variable groups for secrets; secrets come from DSV via `tools/secrets/fetch.py` on self-hosted agents only.
- Pin tasks/tool versions; no `curl | bash` from unpinned URLs; scripts live in `pipelines/scripts/`.
- `pipelines/generated/*` is generated (`tools/pipeline/generate.py`): change the generator, not the output.
