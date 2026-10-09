# Evidence

ADR-0001 section 11: a component may be reported `deployed` or `verified` **only** with an evidence file produced by the
pipeline or the tools. **No live evidence exists yet** - nothing in this repository has been deployed to Azure or
verified against a Datadog organisation, so this directory contains no environment folders.

## What produces evidence

| Producer | File | Content | Where it goes |
|---|---|---|---|
| Select stage (`tools/changeset select`) | `selection.json` | selected components, modes, reasons, waves, retirements | pipeline artifact `selection` |
| Plan job (`pipelines/templates/terraform-plan.yml`, `tools/validate/plan_policy.py`, `tools/deploy/plan_manifest.py`) | `summary.json`, `summary.md`, `manifest.json` | resource change counts (no attribute values), protected-resource violations, cost warnings; binding of commit/config/contracts/artifacts/terraform lock to `plan_sha256` | pipeline artifact `plan-<component>-<attempt>`; the plan file itself only in the protected `plans` container |
| Apply job (`tools/deploy/record.py write`) | `<env>/<component>.json` | deployment record: status (`succeeded`/`failed`/`partial`/`canceled`/`retired`), commit, run id, artifact digests, finished time | `deployments` container |
| Apply job (`tools/contracts/publish.py`) | `<env>/<contract>/v<major>.json` | contract envelope (no secrets) | `contracts` container |
| Build stage | build metadata JSON, SPDX SBOM (syft), BuildKit provenance | per artifact, pushed/uploaded by digest | pipeline artifacts `artifact-*`, ACR, `packages` container |
| Verify stage (`tools/smoke/smoke.py`) | `smoke-results.json` | per component and endpoint: `/healthz`, `/readyz`, `/version` results | pipeline artifact `smoke-*` |
| Verify stage (`observability/tools/verify/telemetry_verify.py`) | `telemetry-results.json` | checks `rum_resource_trace`, `apm_journey`, `logs_pipeline`, `logs_trace_corr`, `logs_no_duplicates`, `required_tags`, `infra_metrics` (keys never written) | pipeline artifact `telemetry-*` |
| Evidence stage (`tools/report/report.py deployment`) | `deployment-report.md`, `evidence.json` | per component status for **this run only**: `verified` (applied + smoke passed + telemetry passed), `deployed` (applied), `unchanged`, `planned`, `failed`, `skipped`; artifacts `built`/`resolved`; retirements | `evidence` container at `<env>/runs/<build id>/` + pipeline artifact `evidence-<attempt>` |
| Evidence stage (`tools/report/deployment_marker.py`, `observability/tools/markers/send_deployment_event.py`) | Datadog DORA deployment events | service, env, version, commit | Datadog |
| Drift run (`tools/report/report.py drift`) | `drift.md`, `drift.json` | components whose plan shows changes without a code change | pipeline artifact |

The `evidence` container is written by the plan identity (bootstrap grants it Storage Blob Data Contributor on
`evidence`); a failed upload only warns, the pipeline artifact still holds the files.

## Recording evidence in the repository

The pipeline does not commit anything. To make a status claim in documentation, copy the run's files from the
`evidence` container into this directory with [`tools/report/pull_evidence.py`](../../tools/report/pull_evidence.py)
and commit them in a reviewed change:

```bash
az login   # identity with Storage Blob Data Reader on the `evidence` container (private endpoint: run from the VNet)
python3 tools/report/pull_evidence.py --store https://<state account>.blob.core.windows.net/evidence \
  --env <env> --run-id <build id>
# -> docs/evidence/<env>/<build id>/{evidence.json, deployment-report.md, SOURCE.json}
```

The tool copies every object under `<env>/runs/<build id>/`, checks that `evidence.json` names the requested
environment and run, refuses JSON files with secret-looking keys, and records the source and sha256 of each file in
`SOURCE.json`. `--store` also accepts a local directory (e.g. a downloaded `evidence-<attempt>` pipeline artifact laid
out as `<env>/runs/<build id>/`), which is how it is tested offline (`tests/tools/test_pull_evidence.py`). Optional extra
files (e.g. `telemetry-results.json` from the run artifacts) can be added to the same folder by hand.

Only then may [IMPLEMENTATION_CHECKLIST.md](../IMPLEMENTATION_CHECKLIST.md) or a README move an item to `deployed` /
`verified`, linking the file. Evidence files contain no secrets by construction (no attribute values, no keys), but
review them before committing (endpoint host names and resource IDs are included).
