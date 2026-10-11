import os

os.environ.setdefault("DD_ENV", "test")
os.environ.setdefault("DD_SERVICE", "hello-jobs")
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)

from hello_common.testing import span_capture

EXPORTER, PROVIDER, spans = span_capture("hello-jobs")
