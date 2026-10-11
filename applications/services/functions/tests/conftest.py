import os
import sys
from pathlib import Path

os.environ.setdefault("DD_ENV", "test")
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # function app root (function_app.py, hello_functions/)

from hello_common.testing import span_capture

EXPORTER, PROVIDER, _ = span_capture("hello-functions")
