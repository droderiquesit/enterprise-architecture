"""Send a few synthetic OTLP spans (+ a metric) to the gateway under test."""

import sys
import time

from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter as GrpcMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter as GrpcSpanExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter as HttpSpanExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.trace import Status, StatusCode


def main(grpc_endpoint: str, http_endpoint: str, token: str | None = None) -> None:
    headers = {"authorization": f"Bearer {token}"} if token else None
    resource = Resource.create(
        {
            "service.name": "hello-orders-api",
            "service.version": "1.4.2",
            "deployment.environment": "test",  # legacy key only: gateway must derive deployment.environment.name
            "service.namespace": "enterprise-hello",
            "team": "observability",
            "process.command_line": "dotnet Hello.Orders.dll --password=hunter2",
        }
    )
    tp = TracerProvider(resource=resource)
    tp.add_span_processor(SimpleSpanProcessor(GrpcSpanExporter(endpoint=grpc_endpoint, insecure=True, headers=headers)))
    http_res = Resource.create({"service.name": "hello-catalog-api", "deployment.environment.name": "test"})
    tp_http = TracerProvider(resource=http_res)
    tp_http.add_span_processor(SimpleSpanProcessor(HttpSpanExporter(endpoint=f"{http_endpoint}/v1/traces", headers=headers)))

    tracer = tp.get_tracer("eh.test")
    with tracer.start_as_current_span("POST /orders", kind=trace.SpanKind.SERVER) as span:
        span.set_attribute("http.request.method", "POST")
        span.set_attribute("http.response.status_code", 202)
        with tracer.start_as_current_span("INSERT orders.orders", kind=trace.SpanKind.CLIENT) as db:
            db.set_attribute("db.system.name", "microsoft.sql_server")
    with tracer.start_as_current_span("GET /orders/{id}", kind=trace.SpanKind.SERVER) as span:
        span.set_status(Status(StatusCode.ERROR, "boom"))
    with tp_http.get_tracer("eh.test").start_as_current_span("GET /products", kind=trace.SpanKind.SERVER):
        pass

    reader = PeriodicExportingMetricReader(GrpcMetricExporter(endpoint=grpc_endpoint, insecure=True, headers=headers), export_interval_millis=500)
    mp = MeterProvider(resource=resource, metric_readers=[reader])
    mp.get_meter("eh.test").create_counter("orders.created").add(3, {"order.status": "Pending"})
    time.sleep(1)
    mp.shutdown()
    tp.shutdown()
    tp_http.shutdown()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
