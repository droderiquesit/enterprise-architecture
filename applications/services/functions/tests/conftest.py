import os
import sys
from pathlib import Path

os.environ.setdefault("DD_ENV", "test")
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # function app root (function_app.py, hello_functions/)

from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

from hello_common.config import service_info
from hello_common.telemetry import setup_telemetry

EXPORTER = InMemorySpanExporter()
PROVIDER = setup_telemetry(service_info("hello-functions"), span_exporter=EXPORTER)
