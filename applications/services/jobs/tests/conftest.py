import os

os.environ.setdefault("DD_ENV", "test")
os.environ.setdefault("DD_SERVICE", "hello-jobs")
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)

import pytest
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

from hello_common.config import service_info
from hello_common.telemetry import setup_telemetry

EXPORTER = InMemorySpanExporter()
PROVIDER = setup_telemetry(service_info("hello-jobs"), span_exporter=EXPORTER)


@pytest.fixture
def spans():
    EXPORTER.clear()

    def _get():
        PROVIDER.force_flush()
        return EXPORTER.get_finished_spans()

    return _get
