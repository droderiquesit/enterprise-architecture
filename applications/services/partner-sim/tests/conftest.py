import os

os.environ.setdefault("DD_ENV", "test")
os.environ.setdefault("DD_SERVICE", "hello-partner-sim")
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)
os.environ["LATENCY_MS_MEAN"] = "1"
os.environ["LATENCY_MS_JITTER"] = "0"
