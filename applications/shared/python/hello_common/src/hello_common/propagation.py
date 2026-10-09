"""W3C trace-context helpers for asynchronous boundaries (Service Bus messages, queues, jobs).

Producers put ``traceparent``/``tracestate`` in message application properties. Consumers start a
*new* trace for the processing span and attach a **span link** to the producer context - an async
hand-off is not a parent/child relationship (the consumer may run minutes later, be retried, or
batch several producers).
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from typing import Any

from opentelemetry import trace
from opentelemetry.trace import Link, SpanContext, TraceFlags, TraceState
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

_TRACEPARENT = re.compile(r"^([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$")
_propagator = TraceContextTextMapPropagator()


def _text(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, (bytes, bytearray)):
        return bytes(value).decode("utf-8", errors="replace")
    return str(value)


def normalize_properties(props: Mapping[Any, Any] | None) -> dict[str, str]:
    """Service Bus returns application_properties with bytes keys/values; normalise to str."""
    out: dict[str, str] = {}
    for key, value in (props or {}).items():
        k = _text(key)
        v = _text(value)
        if k is not None and v is not None:
            out[k] = v
    return out


def inject_current() -> dict[str, str]:
    """traceparent/tracestate for the current span (empty dict when no valid span)."""
    carrier: dict[str, str] = {}
    _propagator.inject(carrier)
    return carrier


def parse_traceparent(value: str | None, tracestate: str | None = None) -> SpanContext | None:
    if not value:
        return None
    match = _TRACEPARENT.match(value.strip().lower())
    if not match:
        return None
    version, trace_id, span_id, flags = match.groups()
    if version == "ff" or int(trace_id, 16) == 0 or int(span_id, 16) == 0:
        return None
    state = TraceState()
    if tracestate:
        try:
            state = TraceState.from_header([tracestate])
        except Exception:
            state = TraceState()
    return SpanContext(
        trace_id=int(trace_id, 16),
        span_id=int(span_id, 16),
        is_remote=True,
        trace_flags=TraceFlags(int(flags, 16) & 0x01),
        trace_state=state,
    )


def producer_context(props: Mapping[Any, Any] | None) -> SpanContext | None:
    """Producer SpanContext from message properties: traceparent, then Diagnostic-Id (Azure SDK)."""
    norm = normalize_properties(props)
    lowered = {k.lower(): v for k, v in norm.items()}
    tp = lowered.get("traceparent") or lowered.get("diagnostic-id")
    return parse_traceparent(tp, lowered.get("tracestate"))


def links_from_properties(props: Mapping[Any, Any] | None, **attributes: Any) -> list[Link]:
    ctx = producer_context(props)
    if ctx is None:
        return []
    return [Link(ctx, attributes={"link.kind": "producer", **attributes})]


def current_trace_ids() -> tuple[str, str] | None:
    ctx = trace.get_current_span().get_span_context()
    if not ctx.is_valid:
        return None
    return format(ctx.trace_id, "032x"), format(ctx.span_id, "016x")
