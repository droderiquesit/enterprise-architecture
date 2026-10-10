"""OpenTelemetry SDK setup: traces + metrics over OTLP (gRPC or HTTP/protobuf) with a bounded pipeline.

Environment (standard OTel variables, read by the SDK/exporters themselves):

OTEL_EXPORTER_OTLP_ENDPOINT   e.g. http://localhost:4317 (gRPC) or http://otel-gateway:4318 (HTTP).
                              Unset => spans are still created (so logs carry trace ids) but nothing
                              is exported.
OTEL_EXPORTER_OTLP_PROTOCOL   grpc (default) | http/protobuf
OTEL_TRACES_SAMPLER(_ARG)     honoured by the SDK (default parentbased_always_on)
OTEL_RESOURCE_ATTRIBUTES      merged into the resource (team=..,domain=..,tier=..)
OTEL_SDK_DISABLED=true        disables everything
OTEL_BSP_MAX_QUEUE_SIZE etc.  override the bounded BatchSpanProcessor defaults below

Resource: service.name, service.version, service.namespace=enterprise-hello,
deployment.environment.name and the legacy deployment.environment.

Metrics never carry user/order ids: a catch-all View keeps only the attribute keys listed in
``ALLOWED_METRIC_ATTRIBUTES`` (and :func:`meter`'s instruments drop every other key before recording, in both modes).

TELEMETRY_SDK=datadog (see :mod:`hello_common.apm`): no OpenTelemetry SDK provider / OTLP exporter is created and no
OTel instrumentation is installed (ddtrace patches FastAPI, httpx, psycopg, redis, azure-servicebus itself).
OTEL_SDK_DISABLED=true likewise creates no provider in otel mode. Custom metrics recorded through :func:`meter` go to
DogStatsD (``datadog`` client; DD_DOGSTATSD_URL or DD_AGENT_HOST[:DD_DOGSTATSD_PORT], default localhost:8125; unified
service tags from DD_ENV/DD_SERVICE/DD_VERSION) - counters as ``count``, histograms as ``distribution``, up/down
counters as signed ``count``, gauges as ``gauge`` - with the same metric names and bounded tags. With
DD_METRICS_OTEL_ENABLED=true they stay on the OpenTelemetry Metrics API instead and ddtrace's MeterProvider exports
them over OTLP to the Agent (requires the Agent's OTLP receiver).
"""

from __future__ import annotations

import logging
import os
import threading
from typing import Any

from opentelemetry import metrics, trace
from opentelemetry.baggage.propagation import W3CBaggagePropagator
from opentelemetry.propagate import set_global_textmap
from opentelemetry.propagators.composite import CompositePropagator
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.metrics.view import View
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, SpanExporter
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

from . import apm
from .config import ServiceInfo, env_bool, env_int

log = logging.getLogger(__name__)

SERVICE_NAMESPACE = "enterprise-hello"

ALLOWED_METRIC_ATTRIBUTES = frozenset(
    {
        # HTTP (old and stable semantic conventions; never url/target/path which are high-cardinality)
        "http.request.method",
        "http.response.status_code",
        "http.route",
        "http.method",
        "http.status_code",
        "http.scheme",
        "url.scheme",
        "network.protocol.version",
        "http.flavor",
        "error.type",
        "server.address",
        # data / messaging
        "db.system",
        "db.system.name",
        "db.operation.name",
        "messaging.system",
        "messaging.operation",
        "messaging.operation.type",
        "messaging.destination.name",
        # application dimensions (all bounded enums)
        "family",
        "operation",
        "outcome",
        "cache.result",
        "fault.type",
        "command",
        "journey",
        "status",
        "sink",
    }
)

_lock = threading.Lock()
_state: dict[str, Any] = {"configured": False, "tracer_provider": None, "meter_provider": None, "instrumented": set(), "mode": None}
PROBE_PATHS = frozenset({"/healthz", "/readyz", "/version"})


def _protocol() -> str:
    proto = (os.environ.get("OTEL_EXPORTER_OTLP_TRACES_PROTOCOL") or os.environ.get("OTEL_EXPORTER_OTLP_PROTOCOL") or "grpc").strip().lower()
    return "http/protobuf" if proto.startswith("http") else "grpc"


def _endpoint_configured() -> bool:
    return bool(os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT") or os.environ.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"))


def build_resource(info: ServiceInfo) -> Resource:
    attrs = {
        "service.name": info.service,
        "service.version": info.version,
        "service.namespace": SERVICE_NAMESPACE,
        "deployment.environment.name": info.env,
        "deployment.environment": info.env,
    }
    # Resource.create merges OTEL_RESOURCE_ATTRIBUTES (team/domain/tier...) and the SDK defaults;
    # explicitly passed attributes win so unified tags stay consistent with the logs.
    return Resource.create(attrs)


def _span_exporter() -> SpanExporter | None:
    if not _endpoint_configured():
        return None
    if _protocol() == "http/protobuf":
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter as HttpSpanExporter

        return HttpSpanExporter(timeout=10)
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter as GrpcSpanExporter

    return GrpcSpanExporter(timeout=10)


def _metric_reader() -> PeriodicExportingMetricReader | None:
    if not _endpoint_configured() or os.environ.get("OTEL_METRICS_EXPORTER", "otlp").lower() == "none":
        return None
    if _protocol() == "http/protobuf":
        from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter as HttpMetricExporter

        exporter = HttpMetricExporter(timeout=10)
    else:
        from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter as GrpcMetricExporter

        exporter = GrpcMetricExporter(timeout=10)
    return PeriodicExportingMetricReader(exporter, export_interval_millis=env_int("OTEL_METRIC_EXPORT_INTERVAL", 30000, minimum=1000))


def setup_telemetry(info: ServiceInfo, *, span_exporter: SpanExporter | None = None, metric_reader: Any = None) -> trace.TracerProvider:
    """Configure global tracer/meter providers once per process. Returns the active TracerProvider.

    ``span_exporter`` / ``metric_reader`` are injection points for tests (InMemorySpanExporter etc.).
    In datadog mode, or with OTEL_SDK_DISABLED=true, no SDK provider is created and the global (ddtrace's when
    DD_TRACE_OTEL_ENABLED=true, else the no-op proxy) provider is returned.
    """
    with _lock:
        if _state["configured"]:
            return _state["tracer_provider"]
        apm.bootstrap_from_env()  # no-op when already run from hello_common/__init__
        mode = apm.telemetry_mode()
        _state["mode"] = mode
        if mode == apm.MODE_DATADOG or env_bool("OTEL_SDK_DISABLED", False):
            _state.update(configured=True, tracer_provider=trace.get_tracer_provider(), meter_provider=None)
            if mode == apm.MODE_DATADOG:
                apm.install_probe_filter(PROBE_PATHS)
            apm.report_status()
            return _state["tracer_provider"]
        set_global_textmap(CompositePropagator([TraceContextTextMapPropagator(), W3CBaggagePropagator()]))
        resource = build_resource(info)
        provider = TracerProvider(resource=resource)  # sampler from OTEL_TRACES_SAMPLER(_ARG)
        exporter = span_exporter or _span_exporter()
        if exporter is not None:
            provider.add_span_processor(
                BatchSpanProcessor(
                    exporter,
                    max_queue_size=env_int("OTEL_BSP_MAX_QUEUE_SIZE", 2048, minimum=64, maximum=65536),
                    schedule_delay_millis=env_int("OTEL_BSP_SCHEDULE_DELAY", 5000, minimum=100),
                    max_export_batch_size=env_int("OTEL_BSP_MAX_EXPORT_BATCH_SIZE", 512, minimum=1, maximum=2048),
                    export_timeout_millis=env_int("OTEL_BSP_EXPORT_TIMEOUT", 30000, minimum=1000),
                )
            )
        trace.set_tracer_provider(provider)
        readers = [metric_reader] if metric_reader is not None else [r for r in [_metric_reader()] if r]
        meter_provider = MeterProvider(
            metric_readers=readers,
            resource=resource,
            views=[View(instrument_name="*", attribute_keys=set(ALLOWED_METRIC_ATTRIBUTES))],
        )
        metrics.set_meter_provider(meter_provider)
        _state.update(configured=True, tracer_provider=provider, meter_provider=meter_provider)
        _configure_azure_core_tracing()
        instrument_libraries()
        apm.report_status()
        log.debug("telemetry configured", extra={"otlp_protocol": _protocol(), "otlp_export": exporter is not None})
        return provider


def otel_sdk_active() -> bool:
    """True when this process configured the OpenTelemetry SDK (otel mode, SDK not disabled)."""
    return _state["meter_provider"] is not None


def _configure_azure_core_tracing() -> None:
    """Route azure-core (Service Bus, Cosmos, Tables, Blob, ...) spans through OpenTelemetry."""
    try:
        from azure.core.settings import settings
        from azure.core.tracing.ext.opentelemetry_span import OpenTelemetrySpan

        settings.tracing_implementation = OpenTelemetrySpan
    except Exception as exc:  # pragma: no cover - optional dependency
        log.debug("azure-core tracing not enabled: %s", exc)


def instrument_libraries() -> list[str]:
    """Instrument every supported client library that is importable. Idempotent. No-op in datadog mode."""
    done: set[str] = _state["instrumented"]
    if apm.is_datadog_mode():
        return sorted(done)
    candidates = {
        "httpx": ("opentelemetry.instrumentation.httpx", "HTTPXClientInstrumentor"),
        "psycopg": ("opentelemetry.instrumentation.psycopg", "PsycopgInstrumentor"),
        "redis": ("opentelemetry.instrumentation.redis", "RedisInstrumentor"),
        "pymongo": ("opentelemetry.instrumentation.pymongo", "PymongoInstrumentor"),
        "pymysql": ("opentelemetry.instrumentation.pymysql", "PyMySQLInstrumentor"),
        "logging": ("opentelemetry.instrumentation.logging", "LoggingInstrumentor"),
    }
    import importlib
    import importlib.util

    for lib, (module_name, cls_name) in candidates.items():
        if lib in done:
            continue
        if lib != "logging" and importlib.util.find_spec(lib) is None:
            continue
        try:
            module = importlib.import_module(module_name)
            instrumentor = getattr(module, cls_name)()
            if lib == "logging":
                instrumentor.instrument(set_logging_format=False)
            else:
                instrumentor.instrument()
            done.add(lib)
        except Exception as exc:  # instrumentation is best-effort; never block startup
            log.debug("instrumentation for %s unavailable: %s", lib, exc)
    return sorted(done)


def shutdown_telemetry() -> None:
    _dogstatsd_close()
    with _lock:
        provider = _state.get("tracer_provider")
        meter_provider = _state.get("meter_provider")
        try:
            if provider is not None:
                provider.force_flush(5000)
                provider.shutdown()
            if meter_provider is not None:
                meter_provider.shutdown(timeout_millis=5000)
        except Exception as exc:  # pragma: no cover
            log.warning("telemetry shutdown error: %s", exc)


def tracer(name: str = "enterprise-hello") -> trace.Tracer:
    return trace.get_tracer(name)


# ------------------------------------------------------------------------------------------------ metrics facade
_dogstatsd_lock = threading.Lock()
_dogstatsd: dict[str, Any] = {"client": None, "failed": False, "factory": None}


def _metrics_backend() -> str:
    """``otel`` (OTel Metrics API: our SDK provider, or ddtrace's with DD_METRICS_OTEL_ENABLED) or ``dogstatsd``."""
    mode = _state["mode"] or (apm.MODE_DATADOG if apm.is_datadog_mode() else apm.MODE_OTEL)
    if mode != apm.MODE_DATADOG:
        return "otel"
    return "otel" if env_bool("DD_METRICS_OTEL_ENABLED", False) else "dogstatsd"


def set_dogstatsd_factory(factory: Any) -> None:
    """Test hook: callable returning a DogStatsD-like client (gauge/increment/distribution/flush)."""
    with _dogstatsd_lock:
        _dogstatsd.update(client=None, failed=False, factory=factory)


def _dogstatsd_client() -> Any:
    client = _dogstatsd["client"]
    if client is not None or _dogstatsd["failed"]:
        return client
    with _dogstatsd_lock:
        if _dogstatsd["client"] is None and not _dogstatsd["failed"]:
            try:
                if _dogstatsd["factory"] is not None:
                    _dogstatsd["client"] = _dogstatsd["factory"]()
                else:
                    from datadog.dogstatsd import DogStatsd

                    # Host/port/UDS from DD_DOGSTATSD_URL / DD_AGENT_HOST / DD_DOGSTATSD_PORT; env/service/version
                    # tags from DD_ENV/DD_SERVICE/DD_VERSION; client-side aggregation + buffering (flushed by a thread).
                    _dogstatsd["client"] = DogStatsd(disable_aggregation=False, disable_buffering=False, disable_telemetry=True)
            except Exception as exc:  # metrics must never break request handling
                _dogstatsd["failed"] = True
                log.warning("DogStatsD client unavailable, custom metrics dropped: %s", exc)
    return _dogstatsd["client"]


def _dogstatsd_close() -> None:
    client = _dogstatsd["client"]
    if client is None:
        return
    try:
        flush = getattr(client, "flush_aggregated_metrics", None)
        if flush:
            flush()
        client.flush()
    except Exception as exc:  # pragma: no cover
        log.debug("dogstatsd flush failed: %s", exc)


def bounded_attributes(attributes: Any) -> dict[str, Any]:
    if not attributes:
        return {}
    return {k: v for k, v in dict(attributes).items() if k in ALLOWED_METRIC_ATTRIBUTES and v is not None}


def _tags(attributes: Any) -> list[str]:
    return [f"{k}:{v}" for k, v in sorted(bounded_attributes(attributes).items())]


class _Instrument:
    """OTel-API-shaped instrument that records to the OTel instrument or to DogStatsD (decided per call)."""

    __slots__ = ("_kind", "_name", "_otel")

    def __init__(self, otel_instrument: Any, name: str, kind: str) -> None:
        self._otel = otel_instrument
        self._name = name
        self._kind = kind

    @property
    def name(self) -> str:
        return self._name

    def _send(self, amount: float, attributes: Any) -> None:
        if _metrics_backend() == "otel":
            if self._kind in ("counter", "up_down_counter"):
                self._otel.add(amount, bounded_attributes(attributes))
            elif self._kind == "gauge":
                self._otel.set(amount, bounded_attributes(attributes))
            else:
                self._otel.record(amount, bounded_attributes(attributes))
            return
        client = _dogstatsd_client()
        if client is None:
            return
        tags = _tags(attributes)
        try:
            if self._kind in ("counter", "up_down_counter"):
                client.increment(self._name, amount, tags=tags)
            elif self._kind == "histogram":
                client.distribution(self._name, amount, tags=tags)
            else:
                client.gauge(self._name, amount, tags=tags)
        except Exception as exc:  # pragma: no cover - UDP send errors are swallowed by the client already
            log.debug("dogstatsd send failed: %s", exc)

    def add(self, amount: float, attributes: Any = None, context: Any = None) -> None:
        self._send(amount, attributes)

    def record(self, amount: float, attributes: Any = None, context: Any = None) -> None:
        self._send(amount, attributes)

    set = record  # gauge alias


class HelloMeter:
    """Facade over ``opentelemetry.metrics.Meter`` used by every service (see module docstring)."""

    def __init__(self, name: str) -> None:
        self._meter = metrics.get_meter(name)

    def create_counter(self, name: str, unit: str = "", description: str = "") -> _Instrument:
        return _Instrument(self._meter.create_counter(name, unit=unit, description=description), name, "counter")

    def create_up_down_counter(self, name: str, unit: str = "", description: str = "") -> _Instrument:
        return _Instrument(self._meter.create_up_down_counter(name, unit=unit, description=description), name, "up_down_counter")

    def create_histogram(self, name: str, unit: str = "", description: str = "", **kwargs: Any) -> _Instrument:
        return _Instrument(self._meter.create_histogram(name, unit=unit, description=description, **kwargs), name, "histogram")

    def create_gauge(self, name: str, unit: str = "", description: str = "") -> _Instrument:
        return _Instrument(self._meter.create_gauge(name, unit=unit, description=description), name, "gauge")

    def __getattr__(self, item: str) -> Any:  # observable instruments etc.: plain OTel API (otel mode only)
        return getattr(self._meter, item)


def meter(name: str = "enterprise-hello") -> HelloMeter:
    return HelloMeter(name)
