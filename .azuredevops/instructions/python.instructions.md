---
applyTo: "**/*.py"
---
# Python (3.13)

- Use `hello_common` (logging, telemetry, `http.create_client`, `secrets.resolve_env`) instead of re-implementing.
- Every HTTP/DB call has a timeout; retries are bounded with jitter and only for idempotent operations.
- No `print` of secrets or full request bodies; exceptions must not include secret values.
- `dsv://` references are resolved at start-up only via `hello_common.secrets.resolve_env()`.
- No `subprocess` with `shell=True`, no `eval`/`exec`, no `yaml.load` (use `safe_load`).
- New behaviour needs pytest tests; integration tests are marked `integration`.
