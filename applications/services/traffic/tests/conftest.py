import os

os.environ.setdefault("DD_ENV", "test")
os.environ.setdefault("DD_SERVICE", "hello-traffic")
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)

from hello_common.config import service_info  # noqa: E402
from hello_common.telemetry import setup_telemetry  # noqa: E402

setup_telemetry(service_info("hello-traffic"))  # instruments httpx (W3C traceparent on outbound calls)
