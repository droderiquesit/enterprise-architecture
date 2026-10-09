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
    _ensure_worker_propagator()
    _done = True


def _ensure_worker_propagator() -> None:
    """Workaround (verified locally with mcr.microsoft.com/azure-functions/python:4-python3.13, Oct 2026): with only
    PYTHON_ENABLE_OPENTELEMETRY=true the Python 3.13 worker (azure_functions_runtime) marks OTel as available but
    never sets its trace-context propagator (that only happens on the Azure Monitor path), so every invocation
    fails with "'NoneType' object has no attribute 'extract'". Calling the worker's own initialiser fixes it."""
    for module in ("azure_functions_runtime.otel", "azure_functions_worker.otel"):
        try:
            mod = __import__(module, fromlist=["update_opentelemetry_status", "otel_manager"])
        except ImportError:
            continue
        manager = getattr(mod, "otel_manager", None)
        if manager is not None and getattr(manager, "get_trace_context_propagator", lambda: True)() is None:
            mod.update_opentelemetry_status()
        return
