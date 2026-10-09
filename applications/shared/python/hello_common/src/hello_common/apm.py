"""Tracer selection: ``TELEMETRY_SDK = otel | datadog`` so a process never runs two tracers.

``otel`` (default when unset)
    hello_common configures the OpenTelemetry SDK (tracer + meter providers, OTLP exporters) - unchanged behaviour.
``datadog``
    hello_common creates **no** OpenTelemetry SDK provider and no OTLP exporter. Traces come from the Datadog
    Python tracer (``ddtrace``):

    * injected by the platform (Single Step Instrumentation on AKS/VMs, ``ddtrace-run`` in a serverless-init
      entrypoint): detected (``ddtrace.bootstrap.sitecustomize`` already loaded) and left alone - no second patch;
    * otherwise enabled here with ``import ddtrace.auto`` (``ddtrace`` is a pinned dependency of every service
      image) unless ``DD_TRACE_ENABLED=false``. ``DD_TRACE_OTEL_ENABLED`` defaults to ``true`` in this path so the
      OpenTelemetry *API* calls in the services (servicebus.process spans with links, job/workflow spans) are
      recorded by ddtrace (Datadog "OpenTelemetry API support").

    Custom metrics (hello.*) go to DogStatsD (``hello_common.telemetry.meter``) unless ``DD_METRICS_OTEL_ENABLED=true``
    (then ddtrace's OTel MeterProvider exports OTLP to the Agent, which must have OTLP ingest enabled).

Continuous Profiler (``DD_PROFILING_ENABLED=true``): in datadog mode ``ddtrace.auto`` starts it (ddtrace preload);
with ``DD_TRACE_ENABLED=false`` it is started alone via ``ddtrace.profiling.auto``; when the tracer was injected the
injector already owns the profiler and nothing is started twice. In otel mode the Datadog profiler is not supported
by this repository (Datadog documents no profiler + OpenTelemetry SDK pairing for Python) and the setting is ignored
with a start-up info log.

Safety net: if ``TELEMETRY_SDK`` is *unset* but a Datadog tracer was injected, the effective mode is ``datadog``
(prevents double tracing when SSI targets a workload whose env was not updated). An explicit ``TELEMETRY_SDK=otel``
next to an injected tracer is honoured but logged as a warning.

:func:`bootstrap_from_env` runs from ``hello_common/__init__.py`` - i.e. before FastAPI, httpx, psycopg or redis are
imported by any service - which is what ``ddtrace.auto`` requires ("import as early as possible").
"""

from __future__ import annotations

import logging
import os
import sys
from typing import Any

MODE_OTEL = "otel"
MODE_DATADOG = "datadog"
_MODES = frozenset({MODE_OTEL, MODE_DATADOG})
_TRUE = frozenset({"1", "true", "yes", "on"})
_FALSE = frozenset({"0", "false", "no", "off"})

log = logging.getLogger(__name__)

# Filled by bootstrap_from_env(); reported by report_status() once logging is configured.
_status: dict[str, Any] = {"bootstrapped": False, "tracer": None, "profiler": None, "notes": []}


class TelemetryModeError(ValueError):
    pass


def _flag(name: str) -> bool | None:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return None
    value = raw.strip().lower()
    if value in _TRUE:
        return True
    if value in _FALSE:
        return False
    return None


def datadog_tracer_loaded() -> bool:
    """True once ddtrace's bootstrap ran in this process (SSI, ddtrace-run, ``import ddtrace.auto``)."""
    return "ddtrace.bootstrap.sitecustomize" in sys.modules


def injection_source() -> str | None:
    """How ddtrace got into the process: ``ssi`` | ``ddtrace-run`` | ``manual`` | None (not loaded)."""
    if not datadog_tracer_loaded():
        return None
    if os.environ.get("_DD_PY_SSI_INJECT") == "1":
        return "ssi"
    ddtrace = sys.modules.get("ddtrace")
    bootstrap_dir = os.path.join(os.path.dirname(getattr(ddtrace, "__file__", "") or ""), "bootstrap")
    if bootstrap_dir in sys.path:
        return "ddtrace-run"
    return "manual" if _status.get("tracer") == "enabled" else "external"


def configured_mode() -> str | None:
    raw = (os.environ.get("TELEMETRY_SDK") or "").strip().lower()
    if not raw:
        return None
    if raw not in _MODES:
        raise TelemetryModeError(f"TELEMETRY_SDK must be one of {sorted(_MODES)}, got {raw!r}")
    return raw


def telemetry_mode() -> str:
    """Effective mode. Unset TELEMETRY_SDK => otel, unless a Datadog tracer is already injected => datadog."""
    mode = configured_mode()
    if mode is not None:
        return mode
    return MODE_DATADOG if datadog_tracer_loaded() else MODE_OTEL


def is_datadog_mode() -> bool:
    try:
        return telemetry_mode() == MODE_DATADOG
    except TelemetryModeError:
        return False


def _start_serverless_compat() -> None:
    """Azure Functions: Datadog's documented setup starts the Serverless Compatibility Layer before ddtrace.auto."""
    if not os.environ.get("FUNCTIONS_WORKER_RUNTIME"):
        return
    try:
        from datadog_serverless_compat import start  # type: ignore[import-not-found]
    except ImportError:
        _status["notes"].append("FUNCTIONS_WORKER_RUNTIME set but datadog-serverless-compat is not installed")
        return
    start()
    _status["notes"].append("datadog-serverless-compat started")


def bootstrap_from_env() -> dict[str, Any]:
    """Enable ddtrace when TELEMETRY_SDK=datadog and it is not injected. Idempotent; never raises."""
    if _status["bootstrapped"]:
        return _status
    _status["bootstrapped"] = True
    try:
        mode = configured_mode()
    except TelemetryModeError as exc:
        _status["notes"].append(str(exc))
        return _status
    profiling = _flag("DD_PROFILING_ENABLED") is True
    if datadog_tracer_loaded():
        # SSI / ddtrace-run / serverless entrypoint already did everything (incl. the profiler) - do not re-patch.
        _status["tracer"] = "injected"
        _status["profiler"] = "owned-by-injector" if profiling else None
        if mode == MODE_OTEL:
            _status["notes"].append("TELEMETRY_SDK=otel but a Datadog tracer is injected: two tracers will run")
        return _status
    if mode != MODE_DATADOG:
        if profiling:
            _status["profiler"] = "ignored-in-otel-mode"
        return _status
    trace_enabled = _flag("DD_TRACE_ENABLED") is not False
    try:
        if trace_enabled:
            # Our manual spans use the OpenTelemetry API; route them to ddtrace unless explicitly disabled.
            os.environ.setdefault("DD_TRACE_OTEL_ENABLED", "true")
            _start_serverless_compat()
            import ddtrace.auto

            _status["tracer"] = "enabled"
            _status["profiler"] = "enabled" if profiling else None
        else:
            _status["tracer"] = "disabled"
            if profiling:
                import ddtrace.profiling.auto  # noqa: F401

                _status["profiler"] = "enabled"
    except ImportError as exc:
        _status["tracer"] = "unavailable"
        _status["notes"].append(f"ddtrace not importable: {exc}")
    except Exception as exc:  # pragma: no cover - never block start-up on APM
        _status["tracer"] = "error"
        _status["notes"].append(f"ddtrace start-up failed: {type(exc).__name__}: {exc}")
    return _status


def status() -> dict[str, Any]:
    return {**_status, "mode": telemetry_mode() if _status["bootstrapped"] else configured_mode() or MODE_OTEL, "source": injection_source()}


def report_status() -> None:
    """One start-up line describing the tracer/profiler selection (called after logging is configured)."""
    try:
        doc = status()
    except TelemetryModeError as exc:
        log.error("invalid telemetry mode: %s", exc)
        return
    fields = {
        "telemetry.sdk": doc["mode"],
        "apm.tracer": doc["tracer"] or "none",
        "apm.tracer_source": doc["source"] or "none",
        "apm.profiler": doc["profiler"] or "off",
    }
    level = logging.INFO
    for note in doc["notes"]:
        if "two tracers" in note or "failed" in note or "not importable" in note:
            level = logging.WARNING
    log.log(
        level,
        "telemetry mode %s (tracer=%s, profiler=%s)%s",
        fields["telemetry.sdk"],
        fields["apm.tracer"],
        fields["apm.profiler"],
        ("; " + "; ".join(doc["notes"])) if doc["notes"] else "",
        extra=fields,
    )
    if doc["profiler"] == "ignored-in-otel-mode":
        log.info("DD_PROFILING_ENABLED is ignored with TELEMETRY_SDK=otel (the Datadog profiler is only started in datadog mode)")


_trace_processors: list[Any] = []


def _configure_processors() -> bool:
    try:
        from ddtrace.trace import tracer

        tracer.configure(trace_processors=list(_trace_processors))
        return True
    except Exception:  # pragma: no cover - older/newer ddtrace layout
        return False


def add_trace_processor(processor: Any) -> bool:
    """Append a ddtrace TraceProcessor/TraceFilter (keeps the ones installed here, e.g. the probe filter)."""
    if not datadog_tracer_loaded():
        return False
    _trace_processors.append(processor)
    return _configure_processors()


def install_probe_filter(paths: frozenset[str]) -> bool:
    """Drop ddtrace traces of health probes (the OTel path excludes them in FastAPIInstrumentor)."""
    if not datadog_tracer_loaded():
        return False
    try:
        from ddtrace.trace import TraceFilter
    except Exception:  # pragma: no cover - older/newer ddtrace layout
        return False

    class _ProbeFilter(TraceFilter):
        def process_trace(self, trace):  # type: ignore[override]
            for span in trace:
                if span.span_type != "web":
                    continue
                route = span.get_tag("http.route") or ""
                path = (span.get_tag("http.url") or "").split("?", 1)[0]
                if route in paths or any(path.endswith(p) for p in paths):
                    return None
            return trace

    if any(type(p).__name__ == "_ProbeFilter" for p in _trace_processors):
        return True
    return add_trace_processor(_ProbeFilter())


def _reset_for_tests() -> None:
    _status.update(bootstrapped=False, tracer=None, profiler=None, notes=[])
