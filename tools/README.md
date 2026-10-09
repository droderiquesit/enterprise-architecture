# tools/

Python 3.13 tooling used by the pipeline and by engineers locally. Dependencies: standard library,
PyYAML and jsonschema only (`pipelines/requirements-tools.txt`). Run everything from the repository
root. `tools/catalog/` and the observability tools are owned by other teams and documented there.

| Package | Entry points | Purpose |
|---|---|---|
| `changeset` | `python3 -m tools.changeset graph \| owners \| fingerprint \| select \| apply-set` | registry + dependency graph (cycle path, layers, consumers, shared-module discovery), fingerprints, selection document + ADO output variables for modes pr/deploy/manual/reconcile/drift/retire, retirement detection |
| `config` | `resolve.py --env`, `render.py --env --component` | profile + custom selection → enabled set (auto-adds hard deps for `custom`, explains missing deps otherwise); per-root `terraform.tfvars.json` + sha256 |
| `contracts` | `materialize.py`, `publish.py publish\|check`, `validate.py` | upstream envelopes → `contracts.auto.tfvars.json`; `terraform output` → validated envelope; JSON Schema checks |
| `pipeline` | `generate.py [--check]`, `conditions.py`, `simulate.py` | generated stages, ADO expression evaluator, run simulator (tests) |
| `validate` | `terraform.sh <dir>`, `all_terraform.py`, `component.py`, `plan_policy.py`, `versions.py`, `ownership.py`, `pipeline_lint.py` | static validation |
| `deploy` | `record.py`, `plan_manifest.py`, `artifacts.py`, `storecp.py`, `retire.py` | deployment records, plan binding, artifact resolve/build metadata/tfvars, store copy, retirement |
| `smoke` | `smoke.py` | bounded HTTP smoke tests from contract endpoints |
| `report` | `report.py deployment\|drift`, `deployment_marker.py` | deployment report + evidence JSON, drift report, Datadog DORA deployment events |

Stores (`--records-url`, `--store`, `--source`) accept a local directory (tests, break-glass) or
`https://<account>.blob.core.windows.net/<container>[/prefix]` (Azure CLI with `--auth-mode login`;
no keys or SAS).

Common local commands:

```bash
python3 -m tools.changeset graph                       # registry valid + acyclic, layers
python3 tools/config/resolve.py --env dev              # what the dev profile enables
python3 -m tools.changeset select --mode pr --env dev --target main      # what a PR would validate
python3 -m tools.changeset select --mode deploy --env dev --records-dir /tmp/records --out /tmp/sel.json
python3 tools/pipeline/generate.py                     # after editing catalog/components.yaml
python3 tools/validate/pipeline_lint.py && python3 tools/validate/ownership.py && python3 tools/validate/versions.py
python3 tools/validate/all_terraform.py --workers 4    # every root + module: fmt/init/validate/test
python3 -m pytest -q tests/changeset tests/pipeline tests/tools
```

Details of modes, fingerprints and stage conditions: `pipelines/README.md`.
