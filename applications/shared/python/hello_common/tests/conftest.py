import os

os.environ.setdefault("DD_ENV", "test")
os.environ.setdefault("DD_SERVICE", "hello-common-test")
os.environ.setdefault("DD_VERSION", "1.2.3")
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)

from hello_common.testing import clear_faults, span_capture  # noqa: F401

EXPORTER, PROVIDER, spans = span_capture("hello-common-test")
