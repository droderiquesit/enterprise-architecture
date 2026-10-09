import os

import pytest
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

os.environ.setdefault("DD_ENV", "test")
os.environ.setdefault("DD_SERVICE", "hello-common-test")
os.environ.setdefault("DD_VERSION", "1.2.3")
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)

from hello_common.config import service_info  # noqa: E402
from hello_common.telemetry import setup_telemetry  # noqa: E402

EXPORTER = InMemorySpanExporter()
PROVIDER = setup_telemetry(service_info("hello-common-test"), span_exporter=EXPORTER)


@pytest.fixture
def spans():
    EXPORTER.clear()

    def _get():
        PROVIDER.force_flush()
        return EXPORTER.get_finished_spans()

    return _get


@pytest.fixture(autouse=True)
def _clear_faults():
    from hello_common.faults import REGISTRY

    REGISTRY.clear()
    yield
    REGISTRY.clear()
