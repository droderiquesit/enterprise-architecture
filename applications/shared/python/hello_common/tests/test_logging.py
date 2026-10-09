import io
import json
import logging
import os
import re

from opentelemetry import trace

from hello_common.config import ServiceInfo
from hello_common.logging import JsonFormatter, configure_logging, redact

INFO = ServiceInfo(service="svc", version="9.9.9", env="test")


def _logger(stream: io.StringIO) -> logging.Logger:
    lg = logging.getLogger(f"t{id(stream)}")
    lg.handlers.clear()
    h = logging.StreamHandler(stream)
    h.setFormatter(JsonFormatter(INFO))
    lg.addHandler(h)
    lg.propagate = False
    lg.setLevel(logging.DEBUG)
    return lg


def test_log_shape_inside_span_has_hex_and_decimal_ids():
    buf = io.StringIO()
    lg = _logger(buf)
    with trace.get_tracer("t").start_as_current_span("op") as span:
        lg.info("hello %s", "world", extra={"order_count": 3})
        ctx = span.get_span_context()
    doc = json.loads(buf.getvalue().strip())
    for key in ("timestamp", "level", "message", "logger", "service", "env", "version", "trace_id", "span_id",
                "dd.trace_id", "dd.span_id", "dd.service", "dd.env", "dd.version"):
        assert key in doc, key
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z", doc["timestamp"])
    assert doc["message"] == "hello world"
    assert doc["level"] == "INFO"
    assert re.fullmatch(r"[0-9a-f]{32}", doc["trace_id"]) and re.fullmatch(r"[0-9a-f]{16}", doc["span_id"])
    assert doc["trace_id"] == format(ctx.trace_id, "032x")
    assert doc["dd.trace_id"] == str(ctx.trace_id & 0xFFFFFFFFFFFFFFFF)
    assert doc["dd.span_id"] == str(ctx.span_id)
    assert doc["dd.service"] == "svc" and doc["dd.env"] == "test" and doc["dd.version"] == "9.9.9"
    assert doc["order_count"] == 3


def test_no_span_omits_trace_keys():
    buf = io.StringIO()
    _logger(buf).warning("outside")
    doc = json.loads(buf.getvalue())
    assert "trace_id" not in doc and "dd.trace_id" not in doc
    assert doc["dd.service"] == "svc"


def test_exception_fields_and_redaction():
    buf = io.StringIO()
    lg = _logger(buf)
    try:
        raise ValueError("connect failed password=hunter2 for user")
    except ValueError:
        lg.exception("boom token=abc123 Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig", extra={"db_password": "x", "idempotency_key": "k-1", "conn": "Host=a;Password=p@ss;"})
    doc = json.loads(buf.getvalue())
    assert doc["error.kind"] == "ValueError"
    assert "hunter2" not in doc["error.message"] and "hunter2" not in doc["error.stack"]
    assert "abc123" not in doc["message"] and "eyJhbGci" not in doc["message"]
    assert doc["db_password"] == "[REDACTED]"
    assert doc["idempotency_key"] == "k-1"
    assert "p@ss" not in doc["conn"]


def test_redact_patterns():
    assert redact("AccountKey=abc==;EndpointSuffix=x") == "AccountKey=[REDACTED];EndpointSuffix=x"
    assert "s3cr3t" not in redact('secret: "s3cr3t"')
    assert "zzz" not in redact("https://a.blob.core.windows.net/c?sv=1&sig=zzz")
    assert redact("plain message") == "plain message"


def test_log_file_rotation_handler(tmp_path):
    path = tmp_path / "logs" / "app.log"
    configure_logging(INFO, level="INFO", log_file_path=str(path))
    logging.getLogger("filetest").info("to file", extra={"k": 1})
    for h in logging.getLogger().handlers:
        h.flush()
    lines = path.read_text().strip().splitlines()
    assert json.loads(lines[-1])["message"] == "to file"
    handler = [h for h in logging.getLogger().handlers if isinstance(h, logging.handlers.RotatingFileHandler)][0]
    assert handler.maxBytes == 10 * 1024 * 1024 and handler.backupCount == 3
    configure_logging(INFO, level="INFO", log_file_path="")
    assert not any(isinstance(h, logging.handlers.RotatingFileHandler) for h in logging.getLogger().handlers)
    assert os.path.exists(path)
