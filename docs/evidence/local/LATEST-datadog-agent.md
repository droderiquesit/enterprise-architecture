# Local e2e evidence - Datadog Agent variant (LATEST)

- run: `docs/evidence/local/20261010T010217Z-datadog-agent` (2026-10-10T01:01:29+00:00 -> 2026-10-10T01:02:17+00:00)
- status vocabulary (ADR-0001 §11): **locally-verified** (real Datadog Agent 7.84.2 + mock intake). Nothing was deployed and no data reached Datadog.
- result: **10/10 checks passed**
- tracers: .NET 3.55.1.0, python 4.15.6; images: {'hello-catalog-api:0.1.0-e2e': 'sha256:12709f107176', 'hello-orders-api-ddtrace:0.1.0-e2e': 'sha256:2f62b9eb7348', 'datadog/agent:7.84.2': 'sha256:779986aa446b'}
- command: `python3 tests/integration/run_dd_agent_e2e.py`

| check | result | what |
|---|---|---|
| dd-1 | pass | Datadog Agent 7.84.2 healthy; catalog-api and orders-api serving |
| dd-2 | pass | traces from ddtrace (Python) and dd-trace-dotnet reached the intake through the Agent |
| dd-3 | pass | distributed trace .NET -> Python with one 128-bit trace id, correct parenting, traceparent response header |
| dd-4 | pass | Activity-based custom span (Hello.App 'send order-events') recorded by the Datadog .NET tracer |
| dd-5 | pass | health probes are not traced (Python probe filter) |
| dd-6 | pass | log correlation: Agent-collected logs carry the ids of received traces (both services) |
| dd-7 | pass | hello.* custom metrics via DogStatsD -> Agent -> series intake (both services, bounded tags) |
| dd-8 | pass | Continuous Profiler: Python and .NET profiles through the Agent profiling proxy |
| dd-9 | pass | datadog mode runs no OpenTelemetry SDK / OTLP exporter |
| dd-10 | pass | API key on every Agent payload; nothing sent to a real Datadog endpoint |

Details: `summary.json` (per-check detail), `tap_records.json` (decoded Agent payloads), `agent_collected_logs.json`, `container-*.log`.
