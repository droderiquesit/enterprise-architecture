"""Real Chromium (Playwright) journey through the built hello-frontend bundle against a fake BFF over HTTP.
Requires: frontend `npm run build` output (services/frontend/dist) and a Chromium (PW_CHROMIUM_EXECUTABLE or
Playwright-managed browsers). Marked integration."""

import os
import socket
import threading
import time
from pathlib import Path

import pytest
import uvicorn
from fake_bff import build
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from hello_traffic.journeys import api_journey, browser_journey, make_api_client

DIST = Path(__file__).resolve().parents[2] / "frontend" / "dist"
LOCAL_CHROMIUM = "/opt/pw-browsers/chromium-1194/chrome-linux/chrome"
EXE = os.environ.get("PW_CHROMIUM_EXECUTABLE") or (LOCAL_CHROMIUM if os.path.exists(LOCAL_CHROMIUM) else None)

pytestmark = [pytest.mark.integration, pytest.mark.skipif(not (DIST / "index.html").exists(), reason="frontend dist not built")]


def _port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _serve(app, port):
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_config=None))
    t = threading.Thread(target=server.run, daemon=True)
    t.start()
    for _ in range(100):
        if server.started:
            return server
        time.sleep(0.05)
    raise RuntimeError("server did not start")


@pytest.fixture(scope="module")
def stack():
    bff_port, fe_port = _port(), _port()
    bff = build()
    fe = FastAPI()
    config = {"env": "it", "service": "hello-frontend", "version": "1.0.0", "apiBaseUrl": f"http://127.0.0.1:{bff_port}"}
    fe.add_api_route("/config.json", lambda: JSONResponse(config))
    fe.mount("/", StaticFiles(directory=DIST, html=True))
    servers = [_serve(bff, bff_port), _serve(fe, fe_port)]
    yield bff, f"http://127.0.0.1:{fe_port}/", f"http://127.0.0.1:{bff_port}"
    for s in servers:
        s.should_exit = True


def test_browser_journey_through_real_ui(stack):
    bff, fe_url, _ = stack
    r = browser_journey(fe_url, order_timeout=30, executable_path=EXE)
    assert r.ok, r.detail
    assert r.final_status == "Fulfilled" and r.order_id
    paths = [x["path"] for x in bff.state.requests if x["method"] != "OPTIONS"]
    assert "/api/catalog/products" in paths and "/api/orders" in paths and any(p.startswith("/api/orders/") for p in paths)


def test_api_journey_over_http(stack):
    bff, _, api = stack
    with make_api_client(api, "it") as c:
        r = api_journey(c, ["SKU-0003"], poll_interval=0.05)
    assert r.ok and r.final_status == "Fulfilled"
    post = [x for x in bff.state.requests if x["method"] == "POST" and x["path"] == "/api/orders"][-1]
    assert post["headers"]["traceparent"].startswith("00-")  # httpx OTel instrumentation propagates W3C context
    assert post["headers"]["user-agent"] == "hello-traffic/it"
