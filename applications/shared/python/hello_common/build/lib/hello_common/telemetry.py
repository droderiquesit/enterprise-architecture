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
``ALLOWED_METRIC_ATTRIBUTES``.
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
_state: dict[str, Any] = {"configured": False, "tracer_provider": None, "meter_provider": None, "instrumented": set()}


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


def setup_telemetry(info: ServiceInfo, *, span_exporter: SpanExporter | None = None, metric_reader: Any = None) -> TracerProvider:
    """Configure global tracer/meter providers once per process. Returns the TracerProvider.

    ``span_exporter`` / ``metric_reader`` are injection points for tests (InMemorySpanExporter etc.).
    """
    with _lock:
        if _state["configured"]:
            return _state["tracer_provider"]
        set_global_textmap(CompositePropagator([TraceContextTextMapPropagator(), W3CBaggagePropagator()]))
        resource = build_resource(info)
        provider = TracerProvider(resource=resource)  # sampler from OTEL_TRACES_SAMPLER(_ARG)
        exporter = span_exporter or (None if env_bool("OTEL_SDK_DISABLED", False) else _span_exporter())
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
        readers = [metric_reader] if metric_reader is not None else ([] if env_bool("OTEL_SDK_DISABLED", False) else [r for r in [_metric_reader()] if r])
        meter_provider = MeterProvider(
            metric_readers=readers,
            resource=resource,
            views=[View(instrument_name="*", attribute_keys=set(ALLOWED_METRIC_ATTRIBUTES))],
        )
        metrics.set_meter_provider(meter_provider)
        _state.update(configured=True, tracer_provider=provider, meter_provider=meter_provider)
        _configure_azure_core_tracing()
        instrument_libraries()
        log.debug("telemetry configured", extra={"otlp_protocol": _protocol(), "otlp_export": exporter is not None})
        return provider


def _configure_azure_core_tracing() -> None:
    """Route azure-core (Service Bus, Cosmos, Tables, Blob, ...) spans through OpenTelemetry."""
    try:
        from azure.core.settings import settings
        from azure.core.tracing.ext.opentelemetry_span import OpenTelemetrySpan

        settings.tracing_implementation = OpenTelemetrySpan
    except Exception as exc:  # pragma: no cover - optional dependency
        log.debug("azure-core tracing not enabled: %s", exc)


def instrument_libraries() -> list[str]:
    """Instrument every supported client library that is importable. Idempotent."""
    done: set[str] = _state["instrumented"]
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


def meter(name: str = "enterprise-hello") -> metrics.Meter:
    return metrics.get_meter(name)
