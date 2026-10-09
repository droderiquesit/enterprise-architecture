# tools/

Python 3.13 tooling used by the pipeline and by engineers locally. Dependencies: standard library,
PyYAML and jsonschema only (`pipelines/requirements-tools.txt`). Run everything from the repository
root. `tools/catalog/` and the observability tools are owned by other teams and documented there.

| Package | Entry points | Purpose |
|---|---|---|
| `changeset` | `python3 -m tools.changeset graph \| owners \| fingerprint \| select \| explain \| apply-set` | registry + dependency graph (cycle path, layers, consumers, shared-module and Helm-chart discovery, pipeline scopes), fingerprints, selection per scope (platform/applications) for modes pr/deploy/manual/reconcile/drift/retire/promote incl. cross-pipeline waiting and upstream-contract change detection, retirement detection, `explain` preview of the working tree |
| `config` | `resolve.py --env`, `render.py --env --component`, `promotion.py check\|source\|list` | profile + custom selection → enabled set (auto-adds hard deps for `custom`, explains missing deps otherwise); per-root `terraform.tfvars.json` + sha256; promotion chains and allowed modes per environment |
| `contracts` | `materialize.py`, `publish.py publish\|check`, `validate.py` | upstream envelopes → `contracts.auto.tfvars.json`; `terraform output` → validated envelope; JSON Schema checks |
| `pipeline` | `generate.py [--check]`, `conditions.py`, `simulate.py` | generated stages, ADO expression evaluator, run simulator (tests) |
| `validate` | `terraform.sh <dir>`, `all_terraform.py`, `component.py`, `plan_policy.py`, `versions.py`, `ownership.py`, `pipeline_lint.py`, `pipeline_templates.py` | static validation; pipeline lint (conditions, locks, timeouts, clean workspaces, entries) and template-contract / ADO-limit / environment-consistency lint |
| `deploy` | `record.py`, `plan_manifest.py`, `artifacts.py`, `charts.py`, `storecp.py`, `retire.py` | deployment records, plan binding, artifact resolve/promote/build metadata/tfvars, Helm chart lint/package/push, store copy, retirement |
| `secrets` | `dsv_apply.py plan\|apply`, `fetch.py exec\|ado`, `check.py`, `publish.py`, `hooks.py`, `mock_dsv.py` | Delinea DSV (ADR-0001 section 14): converge DSV users/permissions from `foundation-secrets`, resolve secrets for one pipeline step with the agent's managed identity (never echoed), verify required paths without reading values, write Azure-generated values after apply, plan/apply hooks, mock DSV server for tests |
| `smoke` | `smoke.py` | bounded HTTP smoke tests from contract endpoints |
| `report` | `report.py deployment\|drift`, `deployment_marker.py`, `release_notes.py` | deployment report + evidence JSON, drift report, Datadog DORA deployment events, observability release notes/tag check |

Stores (`--records-url`, `--store`, `--source`) accept a local directory (tests, break-glass) or
`https://<account>.blob.core.windows.net/<container>[/prefix]` (Azure CLI with `--auth-mode login`;
no keys or SAS).

Common local commands:

```bash
python3 -m tools.changeset graph                       # registry valid + acyclic, layers
python3 tools/config/resolve.py --env dev              # what the dev profile enables
python3 -m tools.changeset explain --env dev           # preview: what would be validated/built/planned, and why
python3 -m tools.changeset select --mode pr --scope platform --env dev --target main
python3 -m tools.changeset select --mode deploy --env dev --records-dir /tmp/records --out /tmp/sel.json
python3 tools/pipeline/generate.py                     # after editing catalog/components.yaml
python3 tools/validate/pipeline_lint.py && python3 tools/validate/pipeline_templates.py
python3 tools/validate/ownership.py && python3 tools/validate/versions.py
python3 tools/validate/all_terraform.py --workers 4    # every root + module: fmt/init/validate/test
python3 -m pytest -q tests/changeset tests/pipeline tests/tools
```

Details of modes, fingerprints and stage conditions: `pipelines/README.md`.
