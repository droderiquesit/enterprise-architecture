"""Structured JSON logging (ADR-0001 §9 log shape) with OTel/Datadog trace correlation and redaction.

Each record becomes exactly one JSON object on one line::

    {"timestamp": "2026-10-09T12:00:00.123Z", "level": "INFO", "message": "...", "logger": "...",
     "service": "...", "env": "...", "version": "...",
     "trace_id": "<32 hex>", "span_id": "<16 hex>",
     "dd.trace_id": "<decimal low 64 bits>", "dd.span_id": "<decimal>",
     "dd.service": "...", "dd.env": "...", "dd.version": "...", ...structured fields}

trace/span keys are present whenever a valid OpenTelemetry span is current (every request handled
by an instrumented framework); log lines emitted outside any span omit them rather than carry
fake zero ids. Exceptions add ``error.kind``, ``error.message`` and ``error.stack``.

Anything that looks like a credential (``password=``, ``secret=``, ``token=``, ``key=``,
``Bearer ...``, ``AccountKey=``, ``SharedAccessKey=``) is replaced with ``[REDACTED]`` in the
message, in string field values and in exception text; fields whose *name* denotes a secret are
redacted entirely.

LOG_FILE_PATH (optional): the same lines are also appended to that file with size-based rotation
(10 MB x 3 backups) for Fluent Bit sidecar / VM tailing.
"""

from __future__ import annotations

import datetime as _dt
import json
import logging
import logging.handlers
import os
import re
import sys
import traceback
from typing import Any

from opentelemetry import trace

from .config import ServiceInfo

LOG_FILE_MAX_BYTES = 10 * 1024 * 1024
LOG_FILE_BACKUPS = 3
REDACTED = "[REDACTED]"

# key=value / key: value credential patterns (case-insensitive). The value stops at whitespace,
# ';' ',' '&' or a quote so connection strings and query strings are handled.
_SECRET_KV = re.compile(
    r"(?i)\b([\w.-]*(?:password|passwd|pwd|secret|token|apikey|api_key|api-key|accountkey|"
    r"sharedaccesskey|access_key|accesskey|key|sig|signature))(\s*[=:]\s*)(\"[^\"]*\"|'[^']*'|[^\s;,&\"']+)"
)
_BEARER = re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}")
_SECRET_FIELD = re.compile(r"(?i)(password|passwd|secret|token|apikey|api_key|authorization|credential|connection_string|^key$|_key$|-key$)")
_SAFE_FIELDS = frozenset({"idempotency_key", "cache_key", "partition_key", "row_key", "sort_key", "dd.trace_id", "dd.span_id"})

_STANDARD_ATTRS = frozenset(
    {
        "name", "msg", "args", "levelname", "levelno", "pathname", "filename", "module", "exc_info",
        "exc_text", "stack_info", "lineno", "funcName", "created", "msecs", "relativeCreated", "thread",
        "threadName", "processName", "process", "taskName", "message", "asctime",
        # attributes injected by opentelemetry-instrumentation-logging
        "otelSpanID", "otelTraceID", "otelServiceName", "otelTraceSampled",
    }
)
_RESERVED = frozenset(
    {"timestamp", "level", "message", "logger", "service", "env", "version", "trace_id", "span_id",
     "dd.trace_id", "dd.span_id", "dd.service", "dd.env", "dd.version", "error.kind", "error.message", "error.stack"}
)


def redact(text: str) -> str:
    """Mask credential-looking substrings in free text."""
    if not text:
        return text
    text = _BEARER.sub(lambda m: f"{m.group(1)} {REDACTED}", text)
    return _SECRET_KV.sub(lambda m: f"{m.group(1)}{m.group(2)}{REDACTED}", text)


def _redact_value(key: str, value: Any) -> Any:
    if key not in _SAFE_FIELDS and _SECRET_FIELD.search(key):
        return REDACTED
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, dict):
        return {k: _redact_value(str(k), v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_redact_value(key if not isinstance(v, dict) else "", v) for v in value]
    return value


def trace_fields() -> dict[str, str]:
    """Correlation fields for the current OTel span (empty when no valid span is active)."""
    ctx = trace.get_current_span().get_span_context()
    if not ctx.is_valid:
        return {}
    return {
        "trace_id": format(ctx.trace_id, "032x"),
        "span_id": format(ctx.span_id, "016x"),
        "dd.trace_id": str(ctx.trace_id & 0xFFFFFFFFFFFFFFFF),
        "dd.span_id": str(ctx.span_id),
    }


class JsonFormatter(logging.Formatter):
    def __init__(self, info: ServiceInfo) -> None:
        super().__init__()
        self.info = info

    @staticmethod
    def _timestamp(record: logging.LogRecord) -> str:
        ts = _dt.datetime.fromtimestamp(record.created, tz=_dt.UTC)
        return ts.strftime("%Y-%m-%dT%H:%M:%S.") + f"{int(record.msecs):03d}Z"

    def format(self, record: logging.LogRecord) -> str:  # noqa: A003 - logging API
        try:
            message = record.getMessage()
        except Exception:  # malformed %-args must never kill logging
            message = str(record.msg)
        doc: dict[str, Any] = {
            "timestamp": self._timestamp(record),
            "level": record.levelname,
            "message": redact(message),
            "logger": record.name,
            "service": self.info.service,
            "env": self.info.env,
            "version": self.info.version,
        }
        doc.update(trace_fields())
        doc["dd.service"] = self.info.service
        doc["dd.env"] = self.info.env
        doc["dd.version"] = self.info.version
        for key, value in record.__dict__.items():
            if key in _STANDARD_ATTRS or key.startswith("_") or key in _RESERVED:
                continue
            doc[key] = _redact_value(key, value)
        if record.exc_info and record.exc_info[0] is not None:
            exc_type, exc, tb = record.exc_info
            doc["error.kind"] = exc_type.__name__
            doc["error.message"] = redact(str(exc))
            doc["error.stack"] = redact("".join(traceback.format_exception(exc_type, exc, tb)))
        elif record.stack_info:
            doc["error.stack"] = redact(record.stack_info)
        return json.dumps(doc, default=str, ensure_ascii=False, separators=(",", ":"))


_CONFIGURED_HANDLERS: list[logging.Handler] = []


def configure_logging(info: ServiceInfo, level: str | None = None, log_file_path: str | None = None, *, keep_existing_handlers: bool = False) -> logging.Logger:
    """Install the JSON formatter on the root logger (stdout + optional rotating file).

    ``keep_existing_handlers`` leaves foreign root handlers in place (Azure Functions: the Python worker's
    handler streams records to the host / FunctionAppLogs and must not be removed)."""
    level_name = (level or os.environ.get("LOG_LEVEL") or "INFO").upper()
    log_file_path = log_file_path if log_file_path is not None else os.environ.get("LOG_FILE_PATH") or None
    root = logging.getLogger()
    for handler in _CONFIGURED_HANDLERS:
        root.removeHandler(handler)
        handler.close()
    _CONFIGURED_HANDLERS.clear()
    formatter = JsonFormatter(info)
    stream = logging.StreamHandler(sys.stdout)
    stream.setFormatter(formatter)
    _CONFIGURED_HANDLERS.append(stream)
    if log_file_path:
        directory = os.path.dirname(os.path.abspath(log_file_path))
        os.makedirs(directory, exist_ok=True)
        file_handler = logging.handlers.RotatingFileHandler(
            log_file_path, maxBytes=LOG_FILE_MAX_BYTES, backupCount=LOG_FILE_BACKUPS, encoding="utf-8"
        )
        file_handler.setFormatter(formatter)
        _CONFIGURED_HANDLERS.append(file_handler)
    # Replace any pre-existing handlers (e.g. basicConfig) so every line has the same shape.
    if not keep_existing_handlers:
        for handler in list(root.handlers):
            root.removeHandler(handler)
    for handler in _CONFIGURED_HANDLERS:
        root.addHandler(handler)
    root.setLevel(getattr(logging, level_name, logging.INFO))
    # Library loggers: keep them quiet and route through root (uvicorn access log replaced by ours).
    for noisy in ("azure", "azure.core.pipeline.policies.http_logging_policy", "urllib3", "httpx", "httpcore", "uamqp", "pyamqp"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        lg = logging.getLogger(name)
        lg.handlers.clear()
        lg.propagate = True
    logging.getLogger("uvicorn.access").disabled = True
    return root
