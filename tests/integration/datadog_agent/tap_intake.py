"""Recording tap in front of the existing mock Datadog intake (observability/tests/transport/mock_intake, unmodified).

The real Datadog Agent is pointed here (DD_DD_URL, DD_APM_DD_URL, DD_APM_PROFILING_DD_URL, logs). Every request is
recorded - path, headers that matter, and a *decoded summary* of the payload - and then forwarded unchanged to
UPSTREAM (the mock intake), whose answer is returned to the Agent. Decoding (stdlib only):

* /api/v0.2/traces   zstd/gzip -> protobuf AgentPayload -> every pb.Span (service, name, resource, trace/span/parent id,
                     meta, span links) via a schema-less protobuf walker with the Agent's field numbers
* /api/v2/series     protobuf MetricPayload -> metric names + tags (strings)
* /api/v2/profile    multipart/form-data -> part names + the event.json document
* /api/v2/logs       JSON (forwarded; the mock intake stores the events)
* GET /api/v1/validate -> {"valid": true} (the Agent's API-key check; the mock has no such route)

GET /_tap -> everything recorded. DELETE /_tap -> reset. Synthetic local data only; the API key is a fake.
"""

from __future__ import annotations

import gzip
import json
import os
import threading
import urllib.error
import urllib.request
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("UPSTREAM", "http://intake:8080")
_lock = threading.Lock()
_records: list[dict] = []


# ------------------------------------------------------------------------------------------- protobuf walking
def _varint(buf: bytes, i: int) -> tuple[int, int]:
    shift = result = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def fields(buf: bytes) -> list[tuple[int, int, object]]:
    """(field number, wire type, value) for one message; length-delimited values stay bytes."""
    out: list[tuple[int, int, object]] = []
    i = 0
    while i < len(buf):
        key, i = _varint(buf, i)
        num, wt = key >> 3, key & 7
        if wt == 0:
            val, i = _varint(buf, i)
        elif wt == 1:
            val, i = int.from_bytes(buf[i : i + 8], "little"), i + 8
        elif wt == 2:
            n, i = _varint(buf, i)
            val, i = buf[i : i + n], i + n
        elif wt == 5:
            val, i = int.from_bytes(buf[i : i + 4], "little"), i + 4
        else:
            raise ValueError(f"wire type {wt}")
        out.append((num, wt, val))
    return out


def _s(v: object) -> str:
    return v.decode("utf-8", "replace") if isinstance(v, (bytes, bytearray)) else str(v)


def _map_entry(v: bytes) -> tuple[str, str]:
    kv = {n: val for n, _, val in fields(v)}
    return _s(kv.get(1, b"")), _s(kv.get(2, b""))


def decode_span(buf: bytes) -> dict:
    # datadog-agent pkg/proto/datadog/trace/span.proto: service=1 name=2 resource=3 traceID=4 spanID=5 parentID=6
    # start=7 duration=8 error=9 meta=10 metrics=11 type=12 meta_struct=13 spanLinks=14 spanEvents=15
    span: dict = {"meta": {}, "links": []}
    for num, wt, val in fields(buf):
        if num == 1:
            span["service"] = _s(val)
        elif num == 2:
            span["name"] = _s(val)
        elif num == 3:
            span["resource"] = _s(val)
        elif num == 4:
            span["trace_id"] = val
        elif num == 5:
            span["span_id"] = val
        elif num == 6:
            span["parent_id"] = val
        elif num == 9:
            span["error"] = val
        elif num == 10 and wt == 2:
            k, v = _map_entry(val)
            span["meta"][k] = v
        elif num == 12:
            span["type"] = _s(val)
        elif num == 14 and wt == 2:
            # SpanLink: traceID=1 traceID_high=2 spanID=3 attributes=4 tracestate=5 flags=6
            link = {}
            for ln, lwt, lv in fields(val):
                if ln == 1:
                    link["trace_id"] = lv
                elif ln == 2:
                    link["trace_id_high"] = lv
                elif ln == 3:
                    link["span_id"] = lv
                elif ln == 4 and lwt == 2:
                    k, v = _map_entry(lv)
                    link.setdefault("attributes", {})[k] = v
            span["links"].append(link)
    return span


def _decode_idx_tracer_payload(buf: bytes) -> dict:
    """Agent >= 7.7x "idx" TracerPayload (AgentPayload field 11): a string table + spans referencing it.

    Field numbers observed from datadog/agent:7.84.2 output (reverse-engineered, local evidence only):
    TracerPayload: strings=1 (repeated, [0]="") containerID=2 languageName=3 languageVersion=4 tracerVersion=5 env=7
    appVersion=9 chunks=11 ; TraceChunk: priority=1 spans=4 traceID=6 (16 bytes) ; Span: service=1 name=2 resource=3
    spanID=4 parentID=5 start=6 duration=7 attributes=9 {key=1, value=2 {string=1 | double=3}} type=10
    """
    fs = fields(buf)
    table = [_s(v) for n, wt, v in fs if n == 1 and wt == 2]

    def st(i: object) -> str:
        return table[i] if isinstance(i, int) and 0 <= i < len(table) else ""

    tp: dict = {"spans": []}
    for n, wt, v in fs:
        if n == 3:
            tp["language"] = st(v)
        elif n == 5:
            tp["tracer_version"] = st(v)
        elif n == 7:
            tp["env"] = st(v)
        elif n == 9:
            tp["app_version"] = st(v)
        elif n == 11 and wt == 2:
            chunk = fields(v)
            trace_hex = next((cv.hex() for cn, cwt, cv in chunk if cn == 6 and cwt == 2), None)
            for cn, cwt, cv in chunk:
                if cn != 4 or cwt != 2:
                    continue
                span: dict = {"meta": {}, "metrics": {}, "links": [], "trace_id_128": trace_hex}
                if trace_hex:
                    span["trace_id"] = int(trace_hex[16:], 16)
                for sn, swt, sv in fields(cv):
                    if sn == 1:
                        span["service"] = st(sv)
                    elif sn == 2:
                        span["name"] = st(sv)
                    elif sn == 3:
                        span["resource"] = st(sv)
                    elif sn == 4:
                        span["span_id"] = sv
                    elif sn == 5:
                        span["parent_id"] = sv
                    elif sn == 10:
                        span["type"] = st(sv)
                    elif sn == 9 and swt == 2:
                        kv = {k: val for k, _, val in fields(sv)}
                        key = st(kv.get(1))
                        inner = {k: val for k, _, val in fields(kv.get(2, b""))}
                        if 1 in inner:
                            span["meta"][key] = st(inner[1])
                        elif 3 in inner:
                            import struct

                            span["metrics"][key] = struct.unpack("<d", inner[3].to_bytes(8, "little"))[0]
                tp["spans"].append(span)
    return tp


def decode_agent_payload(buf: bytes) -> dict:
    # AgentPayload: hostName=1 env=2 tracerPayloads=5 (legacy pb.Span) | idxTracerPayloads=11 (string-table format)
    # legacy TracerPayload: containerID=1 languageName=2 languageVersion=3 tracerVersion=4 runtimeID=5 chunks=6 tags=7
    # env=8 hostname=9 appVersion=10 ; TraceChunk: priority=1 origin=2 spans=3
    doc: dict = {"tracer_payloads": []}
    for num, wt, val in fields(buf):
        if num == 1:
            doc["hostname"] = _s(val)
        elif num == 2:
            doc["env"] = _s(val)
        elif num == 11 and wt == 2:
            doc["tracer_payloads"].append(_decode_idx_tracer_payload(val))
        elif num == 5 and wt == 2:
            tp: dict = {"spans": []}
            for tn, twt, tv in fields(val):
                if tn == 2:
                    tp["language"] = _s(tv)
                elif tn == 4:
                    tp["tracer_version"] = _s(tv)
                elif tn == 8:
                    tp["env"] = _s(tv)
                elif tn == 10:
                    tp["app_version"] = _s(tv)
                elif tn == 6 and twt == 2:
                    for cn, cwt, cv in fields(tv):
                        if cn == 3 and cwt == 2:
                            tp["spans"].append(decode_span(cv))
            doc["tracer_payloads"].append(tp)
    return doc


def strings(buf: bytes, depth: int = 0) -> list[str]:
    """Every printable string in a protobuf message, recursively (metric names, tags, resources)."""
    out: list[str] = []
    try:
        for _, wt, val in fields(buf):
            if wt != 2:
                continue
            text = val.decode("utf-8", "strict") if val and all(32 <= c < 127 for c in val) else None
            if text:
                out.append(text)
            elif depth < 8 and val:
                out.extend(strings(val, depth + 1))
    except (ValueError, IndexError, UnicodeDecodeError):
        pass
    return out


def decompress(body: bytes, encoding: str) -> bytes:
    encoding = (encoding or "").lower()
    if encoding == "gzip":
        return gzip.decompress(body)
    if encoding == "deflate":
        return zlib.decompress(body)
    if encoding == "zstd":  # the Agent's default for traces/series/logs; stdlib from Python 3.14 (tap runs on 3.14)
        from compression import zstd

        return zstd.decompress(body)
    if encoding in ("", "identity"):
        return body
    raise ValueError(f"unsupported content-encoding {encoding}")


def multipart(body: bytes, content_type: str) -> dict:
    boundary = content_type.split("boundary=", 1)[1].strip('"').encode() if "boundary=" in content_type else b""
    parts: list[dict] = []
    event: object = None
    for chunk in body.split(b"--" + boundary):
        if b"\r\n\r\n" not in chunk:
            continue
        head, data = chunk.split(b"\r\n\r\n", 1)
        disp = head.decode("latin-1")
        name = disp.split('name="', 1)[1].split('"', 1)[0] if 'name="' in disp else "?"
        filename = disp.split('filename="', 1)[1].split('"', 1)[0] if 'filename="' in disp else None
        data = data.rstrip(b"\r\n")
        parts.append({"name": name, "filename": filename, "bytes": len(data)})
        if name == "event" or filename == "event.json":
            try:
                event = json.loads(data)
            except ValueError:
                event = None
    return {"parts": parts, "event": event}


def summarize(path: str, headers: dict, body: bytes) -> dict:
    doc: dict = {"path": path, "bytes": len(body), "content_type": headers.get("content-type"), "content_encoding": headers.get("content-encoding")}
    try:
        if path.startswith("/api/v2/profile"):
            doc["profile"] = multipart(body, headers.get("content-type") or "")
            return doc
        raw = decompress(body, headers.get("content-encoding") or "")
        if path == "/api/v0.2/traces":
            doc["traces"] = decode_agent_payload(raw)
            if os.environ.get("TAP_KEEP_RAW"):
                import base64

                doc["raw_b64"] = base64.b64encode(raw).decode()
        elif path in ("/api/v2/series", "/api/beta/sketches", "/api/v1/series"):
            doc["strings"] = sorted(
                set(s for s in strings(raw) if s.startswith(("hello.", "env:", "service:", "version:", "outcome", "cache.result", "order.status", "status:")))
            )
            if path == "/api/v1/series":
                doc["strings"] = sorted({m.get("metric") for m in json.loads(raw).get("series", [])} - {None})
        elif path == "/api/v2/logs":
            items = json.loads(raw)
            doc["log_count"] = len(items) if isinstance(items, list) else 1
    except Exception as exc:  # recording must never break forwarding
        doc["decode_error"] = f"{type(exc).__name__}: {exc}"
    return doc


class Handler(BaseHTTPRequestHandler):
    server_version = "eh-dd-tap/1.0"

    def log_message(self, fmt, *args):
        return

    def _send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> bytes:
        if (self.headers.get("Transfer-Encoding") or "").lower() == "chunked":
            data = b""
            while True:
                size = int(self.rfile.readline().strip().split(b";")[0], 16)
                if size == 0:
                    self.rfile.readline()
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/_tap":
            with _lock:
                return self._send(200, json.dumps({"records": list(_records)}).encode())
        if path == "/healthz":
            return self._send(200, b'{"ok":true}')
        if path == "/api/v1/validate":
            return self._send(200, b'{"valid":true}')
        return self._forward("GET", b"")

    def do_DELETE(self):
        if self.path == "/_tap":
            with _lock:
                _records.clear()
            return self._send(200, b'{"ok":true}')
        return self._send(404, b"{}")

    def do_POST(self):
        body = self._body()
        headers = {k.lower(): v for k, v in self.headers.items()}
        record = summarize(self.path.split("?")[0], headers, body)
        record["api_key_present"] = bool(headers.get("dd-api-key"))
        with _lock:
            _records.append(record)
        return self._forward("POST", body)

    def _forward(self, method: str, body: bytes) -> None:
        keep = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length", "transfer-encoding", "connection")}
        req = urllib.request.Request(UPSTREAM + self.path, data=body if method == "POST" else None, method=method, headers=keep)  # noqa: S310 - UPSTREAM is the local mock intake
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:  # noqa: S310
                return self._send(resp.status, resp.read(), resp.headers.get("Content-Type") or "application/json")
        except urllib.error.HTTPError as exc:
            return self._send(exc.code, exc.read() or b"{}")
        except OSError as exc:
            return self._send(502, json.dumps({"error": str(exc)}).encode())


def main() -> None:
    ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()  # noqa: S104


if __name__ == "__main__":
    main()
