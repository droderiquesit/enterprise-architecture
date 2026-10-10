---
applyTo: "azure-pipelines*.yml,pipelines/**/*.yml"
---
# Azure Pipelines YAML

- PR validation builds run source-branch YAML: they must stay credential-free (no service connections, no DSV fetch,
  no secret variables). Flag any credential use reachable from a PR build.
- Deployments only from `main` and `release/*` (`environments/branching.yaml`; every other branch compiles as a dry
  run) behind the environment approvals, through `pipelines/templates/universal.yml`.
- Template expressions (`${{ parameters.* }}`) and macros of user-controlled values (branch names, free-text run
  parameters) must not be pasted into script text; pass them through `env:`.
- No variable groups for secrets; secrets come from DSV via `tools/secrets/fetch.py` on self-hosted agents only.
- Pin tasks/tool versions; no `curl | bash` from unpinned URLs; scripts live in `pipelines/scripts/`.
- `pipelines/generated/*` is generated (`tools/pipeline/generate.py`): change the generator, not the output.
