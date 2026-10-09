"""The AI request goes through the REAL anthropic SDK (skipped when it is not installed) against a local stub of
POST /v1/messages: proves the kwargs serialise (beta header, fallbacks, output_config) and the response path works."""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

anthropic = pytest.importorskip("anthropic")

from tools.review.ai import AiReviewer
from tools.review.model import FileChange
from tools.review.policy import DEFAULTS


def test_real_sdk_request_and_response(tmp_path):
    seen = {}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            n = int(self.headers["Content-Length"])
            seen["path"], seen["beta"], seen["body"] = self.path, self.headers.get("anthropic-beta"), json.loads(self.rfile.read(n))
            text = json.dumps(
                {
                    "findings": [
                        {
                            "file": "app.py",
                            "line": 1,
                            "severity": "medium",
                            "category": "correctness",
                            "message": "Returns a constant.",
                            "suggestion": "Compute it.",
                        }
                    ]
                }
            )
            body = json.dumps(
                {
                    "id": "msg_1",
                    "type": "message",
                    "role": "assistant",
                    "model": seen["body"]["model"],
                    "content": [{"type": "text", "text": text}],
                    "stop_reason": "end_turn",
                    "stop_sequence": None,
                    "usage": {"input_tokens": 10, "output_tokens": 5},
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        client = anthropic.Anthropic(api_key="test-key", base_url=f"http://127.0.0.1:{srv.server_address[1]}", max_retries=0, timeout=10)
        cfg = dict(DEFAULTS["ai"], enabled=True)
        rev = AiReviewer(cfg, client=client, cache_dir=str(tmp_path))
        findings, meta = rev.review([FileChange("app.py", "M", base_text="x = 1\n", head_text="x = 2\n")], "head", "pol")
    finally:
        srv.shutdown()
    assert seen["path"].startswith("/v1/messages") and "server-side-fallback-2026-07-01" in seen["beta"]
    b = seen["body"]
    assert b["model"] == "claude-opus-5-5" and b["fallbacks"] == "default" and b["max_tokens"] == 8000
    assert b["output_config"]["format"]["type"] == "json_schema" and "thinking" not in b
    assert [f.rule for f in findings] == ["ai.correctness"] and meta["usage"]["input_tokens"] == 10
