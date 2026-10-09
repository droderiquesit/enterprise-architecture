"""Process-level setup for the Functions Python worker: JSON logs + OTel SDK exporting OTLP.

Functions settings (see README): host.json "telemetryMode": "OpenTelemetry" (host emits OTel),
PYTHON_ENABLE_OPENTELEMETRY=true (worker streams OTel logs/traces, avoiding duplicate host log entries),
OTEL_EXPORTER_OTLP_ENDPOINT (+ OTEL_EXPORTER_OTLP_PROTOCOL) -> observability OTel gateway. No Application
Insights connection string is set. The worker's own logging handler is kept (FunctionAppLogs path)."""

from __future__ import annotations

from hello_common.config import service_info
from hello_common.logging import configure_logging
from hello_common.telemetry import setup_telemetry

_done = False


def configure() -> None:
    global _done
    if _done:
        return
    info = service_info("hello-functions")
    configure_logging(info, keep_existing_handlers=True)
    setup_telemetry(info)
    _done = True
