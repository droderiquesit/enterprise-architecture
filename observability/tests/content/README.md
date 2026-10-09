# tests/content

`python3 -m pytest -q observability/tests/content` (needs pyyaml, jsonschema, pytest; terraform for the module tests).

* `test_onboarding_render.py` - merge precedence, templating, references, committed rendered output is current,
  every monitor has runbook + notification + matching threshold, metric names are documented.
* `test_telemetry_verify.py` - verifier against recorded API responses (`fixtures/datadog-api/`), no network.
* `test_markers.py` - DORA deployment marker payload/retries.
* `test_terraform_modules.py` - fmt/init/validate/`terraform test` of every content module and lab root.

Fixtures:
* `fixtures/verified-metrics.txt` - metric names extracted on 2026-10-09 from the Datadog integration documentation
  pages listed in its header (Azure integrations, kubernetes_state_core, system), the OTel collector health-metrics
  page and the Fluent Bit monitoring page.
* `fixtures/datadog-recommended-azure-monitors.txt` - Datadog recommended Azure monitor queries (integration | query),
  retrieved with the Datadog MCP `get_monitor_templates` on 2026-10-09; evidence for Azure tag names.
