import os

os.environ.setdefault("DD_ENV", "test")
os.environ.setdefault("DD_SERVICE", "hello-jobs")
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)

import pytest  # noqa: E402
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter  # noqa: E402

from hello_common.config import service_info  # noqa: E402
from hello_common.telemetry import setup_telemetry  # noqa: E402

EXPORTER = InMemorySpanExporter()
PROVIDER = setup_telemetry(service_info("hello-jobs"), span_exporter=EXPORTER)


@pytest.fixture
def spans():
    EXPORTER.clear()

    def _get():
        PROVIDER.force_flush()
        return EXPORTER.get_finished_spans()

    return _get
