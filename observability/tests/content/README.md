# tests/content

`python3 -m pytest -q observability/tests/content` (needs pyyaml, jsonschema, pytest). Core package tests of the
onboarding tools and the read-only verification tools; the monitoring-content tests moved with the content to
`extras/content/tests/content` (optional add-on, run separately).

* `test_onboarding_v2.py` - manifest v2 (identity + tags + resources + telemetry routing): lab and example manifests
  valid with `--strict`, committed `rendered/` output current and schema-valid, tag policy enforcement, content sections
  reported as notices, v1 manifests rejected with the migration hint, `migrate_v1.py`, contract reference resolution.
* `test_telemetry_verify.py` - verifier against recorded API responses (`fixtures/datadog-api/`), no network.
* `test_markers.py` - DORA deployment marker payload/retries.

Terraform modules are tested per directory with `tools/validate/terraform.sh <dir>` (source repository) or
`terraform init -backend=false && terraform validate && terraform test`.
