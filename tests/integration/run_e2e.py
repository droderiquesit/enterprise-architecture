#!/usr/bin/env python3
"""Enterprise Hello - LOCAL end-to-end integration run (docker compose + Chromium) with real telemetry plumbing.

Evidence label: "locally-verified (docker, mock Datadog intake)". Nothing here talks to Datadog or Azure.

    python3 tests/integration/run_e2e.py                 # build images if missing, up, journey, checks, evidence, down
    python3 tests/integration/run_e2e.py --keep          # leave the stack running afterwards (debugging)
    python3 tests/integration/run_e2e.py --rebuild       # rebuild every app image from the current source first
    python3 tests/integration/run_e2e.py --reuse         # reuse an already running stack (after --keep)
    E2E=1 pytest -v tests/integration/test_e2e.py        # same run, one pytest test per check

Requires: docker + compose v2, python3.13 with `playwright` (pip) and a Chromium build (PW_CHROMIUM_EXECUTABLE or
PLAYWRIGHT_BROWSERS_PATH, default /opt/pw-browsers). See tests/integration/README.md.
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Callable

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
COMPOSE_FILE = HERE / "docker-compose.yml"
PROJECT = "eh-e2e"
WORK = Path(os.environ.get("E2E_WORK_DIR", HERE / ".work")).resolve()
EVIDENCE_ROOT = REPO / "docs" / "evidence" / "local"
VERSION = os.environ.get("E2E_VERSION", "0.1.0-e2e")
LABEL = "locally-verified (docker, mock Datadog intake)"

FRONTEND = "http://localhost:18080"
BFF = "http://localhost:18081"
CATALOG = "http://localhost:18082"
ORDERS = "http://localhost:18083"
INVENTORY = "http://localhost:18084"
PARTNER = "http://localhost:18085"
ADAPTER = "http://localhost:18086"
WORKER = "http://localhost:18087"
DURABLE = "http://localhost:18088"
INTAKE = "http://localhost:18090"
GATEWAY_HEALTH = "http://localhost:18133"
FAULT_TOKEN = "e2e-fault-token-local-only"
RUM_INTAKE_GLOB = "https://browser-intake-datadoghq.com/**"

# service -> (compose service, expected ddsource, team tag) ; every app has its own Fluent Bit sidecar
APPS = {
    "hello-bff": ("bff", "csharp", "hello-web"),
    "hello-orders-api": ("orders-api", "csharp", "hello-orders"),
    "hello-inventory-api": ("inventory-api", "csharp", "hello-inventory"),
    "hello-durable": ("durable", "csharp", "hello-fulfillment"),
    "hello-catalog-api": ("catalog-api", "python", "hello-catalog"),
    "hello-partner-sim": ("partner-sim", "python", "hello-payments"),
    "hello-worker": ("worker", "python", "hello-notifications"),
    "hello-dbadapter-postgresql": ("dbadapter-postgresql", "python", "hello-data"),
}
IMAGES = ["bff", "orders-api", "inventory-api", "durable", "catalog-api", "dbadapter", "worker", "partner-sim", "frontend"]
SPAN_KIND = {1: "internal", 2: "server", 3: "client", 4: "producer", 5: "consumer"}
REQUIRED_RESOURCE_ATTRS = ["service.name", "service.version", "deployment.environment.name", "deployment.environment",
                           "service.namespace", "team", "domain", "tier", "application"]

CHECKS = [
    ("rum", "1. RUM view + resource + action events captured (Playwright route -> mock intake)"),
    ("trace_correlation", "2. Browser traceparent trace_id in hello-bff, hello-orders-api, hello-catalog-api spans + DB client span"),
    ("durable_workflow", "3. hello-durable orchestration/activity spans exist and are tied to the order's trace"),
    ("worker_consumer", "4. hello-worker servicebus.process consumer span links to the producer span"),
    ("logs_fluentbit", "5. Logs of every app arrive via Fluent Bit with ddsource/service/env/version + pipeline tag; journey logs carry the trace_id"),
    ("no_duplicates", "6. No duplicates: unique marker log count == 1 per service; no duplicated events/spans"),
    ("tags", "7. Required tags / resource attributes on spans, metrics, logs and RUM"),
    ("redaction", "8. Secret redaction at the intake (app path + Fluent Bit transport path)"),
    ("faults", "9. Fault injection: 201 + BFF errors + recovery after expiry; wrong token 403; FAULTS_ENABLED=false 404"),
    ("idempotency", "10. Idempotency-Key on POST /api/orders replays the same order"),
    ("exporter_transport", "11. OTel gateway datadog exporter delivers traces/metrics to the (mock) intake; OTLP logs not forwarded"),
]


# ----------------------------------------------------------------------------------------------- helpers
def log(msg: str) -> None:
    print(f"[e2e {dt.datetime.now(dt.UTC).strftime('%H:%M:%S')}] {msg}", flush=True)


def sh(*args: str, check: bool = True, env: dict | None = None, timeout: float | None = None) -> subprocess.CompletedProcess:
    res = subprocess.run(list(args), capture_output=True, text=True, env=env, timeout=timeout)
    if check and res.returncode != 0:
        raise RuntimeError(f"command failed ({res.returncode}): {' '.join(args)}\n{res.stdout[-3000:]}\n{res.stderr[-3000:]}")
    return res


def compose_env() -> dict:
    env = dict(os.environ)
    env.setdefault("E2E_WORK_DIR", str(WORK))
    env.setdefault("E2E_VERSION", VERSION)
    env.setdefault("E2E_GIT_COMMIT", git_commit())
    return env


def compose(*args: str, check: bool = True, timeout: float | None = 900) -> subprocess.CompletedProcess:
    return sh("docker", "compose", "-f", str(COMPOSE_FILE), "-p", PROJECT, *args, check=check, env=compose_env(), timeout=timeout)


def git_commit() -> str:
    try:
        return sh("git", "-C", str(REPO), "rev-parse", "--short", "HEAD").stdout.strip()
    except Exception:  # noqa: BLE001
        return "unknown"


def http(method: str, url: str, body: Any = None, headers: dict | None = None, timeout: float = 15.0) -> tuple[int, dict, Any]:
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        hdrs.setdefault("content-type", "application/json")
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - local test endpoints only
            raw = r.read()
            return r.status, dict(r.headers), _json_or_text(raw)
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), _json_or_text(exc.read())


def _json_or_text(raw: bytes) -> Any:
    try:
        return json.loads(raw or b"null")
    except ValueError:
        return raw.decode(errors="replace")


def poll(fn: Callable[[], Any], timeout: float, interval: float = 2.0, what: str = "condition") -> Any:
    deadline = time.time() + timeout
    last: Any = None
    while time.time() < deadline:
        try:
            last = fn()
            if last:
                return last
        except Exception as exc:  # noqa: BLE001 - retried until the deadline
            last = exc
        time.sleep(interval)
    raise TimeoutError(f"timed out after {timeout:.0f}s waiting for {what}; last={str(last)[:500]}")


def new_traceparent() -> tuple[str, str, str]:
    trace_id = uuid.uuid4().hex
    span_id = uuid.uuid4().hex[:16]
    return f"00-{trace_id}-{span_id}-01", trace_id, span_id


def dd_id(hex_id: str) -> str:
    """Datadog decimal id = low 64 bits of the W3C id."""
    return str(int(hex_id[-16:], 16))


# ----------------------------------------------------------------------------------------------- telemetry readers
def _attr_value(v: dict) -> Any:
    if not v:
        return None
    (k, val), = v.items()
    if k == "arrayValue":
        return [_attr_value(x) for x in val.get("values", [])]
    if k == "kvlistValue":
        return {a["key"]: _attr_value(a["value"]) for a in val.get("values", [])}
    if k == "intValue":
        return int(val)
    return val


def _attrs(lst: list | None) -> dict:
    return {a["key"]: _attr_value(a.get("value", {})) for a in (lst or [])}


def read_spans() -> list[dict]:
    path = WORK / "otel" / "traces.jsonl"
    spans: list[dict] = []
    if not path.exists():
        return spans
    for line in path.read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            doc = json.loads(line)
        except ValueError:
            continue  # partially flushed last line
        for rs in doc.get("resourceSpans", []):
            res = _attrs(rs.get("resource", {}).get("attributes"))
            for ss in rs.get("scopeSpans", []):
                scope = ss.get("scope", {}).get("name", "")
                for s in ss.get("spans", []):
                    spans.append({
                        "service": res.get("service.name"),
                        "resource": res,
                        "scope": scope,
                        "name": s.get("name"),
                        "kind": SPAN_KIND.get(s.get("kind", 0), str(s.get("kind"))),
                        "trace_id": s.get("traceId", ""),
                        "span_id": s.get("spanId", ""),
                        "parent_span_id": s.get("parentSpanId", ""),
                        "attributes": _attrs(s.get("attributes")),
                        "links": [{"trace_id": ln.get("traceId", ""), "span_id": ln.get("spanId", "")} for ln in s.get("links", []) or []],
                        "status": s.get("status", {}),
                        "start": int(s.get("startTimeUnixNano", 0)),
                    })
    return spans


def read_metrics() -> list[dict]:
    """Flattened (resource attrs, metric name, datapoint attrs, value) for the metric file exporter output."""
    path = WORK / "otel" / "metrics.jsonl"
    out: list[dict] = []
    if not path.exists():
        return out
    for line in path.read_text(errors="replace").splitlines():
        try:
            doc = json.loads(line)
        except ValueError:
            continue
        for rm in doc.get("resourceMetrics", []):
            res = _attrs(rm.get("resource", {}).get("attributes"))
            for sm in rm.get("scopeMetrics", []):
                for m in sm.get("metrics", []):
                    for kind in ("sum", "gauge", "histogram", "exponentialHistogram"):
                        if kind in m:
                            for dp in m[kind].get("dataPoints", []):
                                val = dp.get("asDouble", dp.get("asInt", dp.get("count")))
                                out.append({"service": res.get("service.name"), "resource": res, "name": m.get("name"),
                                            "attributes": _attrs(dp.get("attributes")), "value": val})
    return out


def intake() -> dict:
    return http("GET", f"{INTAKE}/_received", timeout=30)[2]


def mask(s: str) -> str:
    return s[:4] + "***" if s else s


# ----------------------------------------------------------------------------------------------- stack lifecycle
def ensure_images(rebuild: bool) -> None:
    missing = [s for s in IMAGES if sh("docker", "image", "inspect", f"hello-{s}:{VERSION}", check=False).returncode != 0]
    todo = IMAGES if rebuild else missing
    if todo:
        log(f"building images from source: {', '.join(todo)}")
        res = subprocess.run([str(HERE / "build_images.sh"), *todo], env={**os.environ, "E2E_VERSION": VERSION})
        if res.returncode != 0:
            raise RuntimeError("image build failed")


def stack_up() -> None:
    if WORK.exists():
        shutil.rmtree(WORK)
    (WORK / "otel").mkdir(parents=True)
    (WORK / "otel").chmod(0o777)  # the collector image runs as uid 10001
    log("docker compose up -d")
    compose("up", "-d", "--remove-orphans", timeout=900)


def stack_down() -> None:
    log("docker compose down -v")
    compose("down", "-v", "--remove-orphans", check=False, timeout=300)


def wait_ready() -> dict:
    t0 = time.time()
    poll(lambda: http("GET", f"{INTAKE}/healthz")[0] == 200, 120, what="mock intake")
    poll(lambda: http("GET", GATEWAY_HEALTH)[0] == 200, 120, what="otel gateway health_check")
    poll(lambda: "Emulator Service is Successfully Up" in compose("logs", "servicebus-emulator", check=False).stdout, 300,
         interval=5, what="Service Bus emulator")
    for name, url in [("catalog-api", f"{CATALOG}/readyz"), ("orders-api", f"{ORDERS}/readyz"), ("inventory-api", f"{INVENTORY}/readyz"),
                      ("partner-sim", f"{PARTNER}/readyz"), ("dbadapter", f"{ADAPTER}/readyz"), ("bff", f"{BFF}/readyz"),
                      ("durable", f"{DURABLE}/api/healthz"), ("worker", f"{WORKER}/readyz"), ("frontend", f"{FRONTEND}/healthz")]:
        poll(lambda u=url: http("GET", u, timeout=5)[0] == 200, 240, what=f"{name} ready")
    # the Functions host binds HTTP before the Service Bus listener is up; wait for the trigger listener
    poll(lambda: "Job host started" in compose("logs", "durable", check=False).stdout, 240, interval=5, what="durable job host")
    return {"ready_after_s": round(time.time() - t0, 1)}


def seed() -> dict:
    st, _, body = http("POST", f"{INVENTORY}/inventory/seed")
    assert st in (200, 201), f"inventory seed {st} {body}"
    count = poll(lambda: (http("GET", f"{CATALOG}/products")[2] or {}).get("count", 0) >= 20 and
                 http("GET", f"{CATALOG}/products")[2]["count"], 60, what="catalog seeded (SEED_ON_STARTUP)")
    return {"inventory_seed": body, "catalog_products": count}


# ----------------------------------------------------------------------------------------------- browser journey
def browser_journey(ctx: dict) -> dict:
    from playwright.sync_api import sync_playwright

    exe = os.environ.get("PW_CHROMIUM_EXECUTABLE")
    if not exe:
        os.environ.setdefault("PLAYWRIGHT_BROWSERS_PATH", "/opt/pw-browsers")
    rum_requests: list[dict] = []
    api_requests: list[dict] = []
    console_errors: list[str] = []

    def on_rum(route, request):
        # RECORD the RUM batch, FORWARD it unchanged to the mock intake (same path + query), and answer the browser
        # with 202 + CORS (the SDK would otherwise retry and re-send the batch).
        url = request.url
        body = request.post_data_buffer or b""
        rum_requests.append({"url": url, "headers": request.headers, "body": body.decode("utf-8", errors="replace")})
        path = url.split("datadoghq.com", 1)[1]
        try:
            req = urllib.request.Request(f"{INTAKE}{path}", data=body, method="POST",
                                         headers={"content-type": request.headers.get("content-type", "text/plain")})
            with urllib.request.urlopen(req, timeout=10) as r:  # noqa: S310
                fwd = r.status
        except Exception as exc:  # noqa: BLE001
            fwd = f"error {exc}"
        rum_requests[-1]["forwarded_status"] = fwd
        route.fulfill(status=202, body="{}", headers={"access-control-allow-origin": "*", "content-type": "application/json"})

    def on_request(request):
        if request.url.startswith(BFF):
            api_requests.append({"method": request.method, "url": request.url, "traceparent": request.headers.get("traceparent")})

    out: dict = {}
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=exe) if exe else p.chromium.launch()
        context = browser.new_context(viewport={"width": 1280, "height": 900})
        context.route(RUM_INTAKE_GLOB, on_rum)
        page = context.new_page()
        page.on("request", on_request)
        page.on("console", lambda m: m.type == "error" and console_errors.append(m.text))
        t0 = time.time()
        page.goto(FRONTEND + "/")
        page.get_by_role("heading", name="Enterprise Hello").wait_for(timeout=30_000)
        page.get_by_test_id("product-list").wait_for(timeout=30_000)
        rows = page.locator("[data-testid^='product-row-']").count()
        page.get_by_test_id(f"order-{ctx['sku']}").click()
        page.get_by_test_id("quantity-input").fill(str(ctx["quantity"]))
        page.get_by_test_id("place-order").click()
        page.wait_for_url(re.compile(r".*#/orders/[0-9a-f-]{36}$"), timeout=30_000)
        order_id = page.url.rsplit("/", 1)[1]
        status_el = page.get_by_test_id("order-status")
        deadline = time.time() + 180
        status = None
        while time.time() < deadline:
            status = status_el.get_attribute("data-status")
            if status in ("Fulfilled", "Failed"):
                break
            time.sleep(1)
        timeline = page.get_by_test_id("timeline-item").all_inner_texts()
        footer = page.get_by_test_id("version-footer").inner_text()
        t_fulfilled = round(time.time() - t0, 1)
        # adapters roundtrip (hello-bff -> hello-dbadapter-postgresql -> PostgreSQL)
        page.locator("a[href='#/adapters']").click()
        page.get_by_test_id("adapter-postgresql").wait_for(timeout=30_000)
        page.get_by_test_id("adapter-postgresql").locator("button").click()
        page.get_by_test_id("adapter-result-postgresql").wait_for(timeout=30_000)
        adapter_result = page.get_by_test_id("adapter-result-postgresql").inner_text()
        page.locator("a[href='#/']").click()
        page.get_by_test_id("product-list").wait_for(timeout=30_000)
        # flush RUM batches (page hidden -> SDK flushes), then close (unload flush)
        page.evaluate("""() => { Object.defineProperty(document, 'visibilityState', {value: 'hidden', configurable: true});
                                 document.dispatchEvent(new Event('visibilitychange')); }""")
        try:
            poll(lambda: any('"type":"view"' in r["body"] for r in rum_requests) and
                 any('"type":"action"' in r["body"] for r in rum_requests), 45, interval=1, what="RUM view+action batches")
        except TimeoutError:
            pass
        page.close()
        context.close()
        browser.close()
    post = next((r for r in api_requests if r["method"] == "POST" and r["url"].endswith("/api/orders")), None)
    adapter_post = next((r for r in api_requests if r["method"] == "POST" and "/roundtrip" in r["url"]), None)
    products_get = next((r for r in api_requests if r["method"] == "GET" and r["url"].endswith("/api/catalog/products")), None)
    out.update({
        "order_id": order_id, "status": status, "timeline": timeline, "footer": footer, "product_rows": rows,
        "seconds_to_terminal_status": t_fulfilled, "adapter_result": adapter_result,
        "api_requests": api_requests, "rum_requests": rum_requests, "console_errors": console_errors[:20],
        "traceparent": post and post["traceparent"],
        "adapter_traceparent": adapter_post and adapter_post["traceparent"],
        "products_traceparent": products_get and products_get["traceparent"],
    })
    return out


# ----------------------------------------------------------------------------------------------- API side actions
def api_actions(ctx: dict) -> dict:
    out: dict = {}
    # --- check 6 marker for catalog-api: a uniquely named product upsert
    st, _, body = http("POST", f"{CATALOG}/products", {"sku": ctx["marker_sku"], "name": "E2E marker product", "unit_price": "1.00"})
    out["catalog_marker"] = {"status": st, "sku": ctx["marker_sku"]}

    # --- check 10: idempotency through the BFF
    key = str(uuid.uuid4())
    body = {"sku": "SKU-0005", "quantity": 1, "customer_ref": ctx["idem_customer"]}
    s1, h1, b1 = http("POST", f"{BFF}/api/orders", body, {"Idempotency-Key": key})
    s2, h2, b2 = http("POST", f"{BFF}/api/orders", body, {"Idempotency-Key": key})
    s3, _, b3 = http("POST", f"{BFF}/api/orders", {**body, "quantity": 2}, {"Idempotency-Key": key})

    def oid(b):
        return (b.get("order") or b).get("id") if isinstance(b, dict) else None

    out["idempotency"] = {
        "first": {"status": s1, "order_id": oid(b1)},
        "replay": {"status": s2, "order_id": oid(b2), "replayed_header": {k: v for k, v in h2.items() if "replay" in k.lower()}},
        "same_key_different_body": {"status": s3, "body": b3 if s3 >= 400 else {"order_id": oid(b3)}},
    }
    lst = http("GET", f"{BFF}/api/orders?limit=100")[2]
    items = lst.get("items", lst) if isinstance(lst, dict) else lst
    out["idempotency"]["orders_with_customer_ref"] = sum(1 for o in items or [] if o.get("customer_ref") == ctx["idem_customer"])

    # --- check 8a: app path - a fake secret inside a value the partner simulator logs (order_id)
    st, _, _ = http("POST", f"{PARTNER}/payments", {"order_id": f"{ctx['redact_marker']} password={ctx['fake_secret']}", "amount": "1.00"})
    out["redaction_app_post"] = st
    # --- check 8b: transport path - a raw line in partner-sim's shared log file that bypassed the in-process redactor
    line = json.dumps({
        "timestamp": dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z", "level": "info", "logger": "e2e.probe",
        "service": "hello-partner-sim", "env": "e2e", "version": VERSION,
        "message": f"{ctx['redact_marker']}-transport Authorization: Bearer {ctx['fake_jwt']} url=https://x.blob.core.windows.net/c?sv=1&sig={ctx['fake_secret']}",
        "client_secret": ctx["fake_secret"], "db": {"connection_string": f"Server=x;Password={ctx['fake_secret']}"},
    })
    res = compose("exec", "-T", "partner-sim", "python", "-c",
                  "import sys; open('/var/log/app/app.log','a').write(sys.argv[1] + '\\n')", line, check=False)
    out["redaction_transport_injected"] = res.returncode == 0

    # --- check 9: fault injection
    faults: dict = {}
    faults["wrong_token"] = http("POST", f"{ORDERS}/admin/faults", {"type": "http_500", "rate": 1.0, "duration_seconds": 30},
                                 {"X-Fault-Token": "wrong-token"})[0]
    faults["missing_token"] = http("POST", f"{ORDERS}/admin/faults", {"type": "http_500", "rate": 1.0, "duration_seconds": 30})[0]
    faults["disabled_service_catalog"] = http("POST", f"{CATALOG}/admin/faults", {"type": "http_500", "rate": 1.0, "duration_seconds": 30},
                                              {"X-Fault-Token": FAULT_TOKEN})[0]
    st, _, fb = http("POST", f"{ORDERS}/admin/faults", {"type": "http_500", "rate": 1.0, "duration_seconds": 30}, {"X-Fault-Token": FAULT_TOKEN})
    t_act = time.time()
    faults["activate"] = {"status": st, "body": fb}
    faults["list"] = http("GET", f"{ORDERS}/admin/faults", headers={"X-Fault-Token": FAULT_TOKEN})[2]
    tp, ctx["fault_trace_id"], _ = new_traceparent()
    s_err, _, b_err = http("GET", f"{BFF}/api/orders?limit=1", headers={"traceparent": tp})
    faults["bff_during_fault"] = {"status": s_err, "problem_type": b_err.get("type") if isinstance(b_err, dict) else None,
                                  "trace_id": ctx["fault_trace_id"]}
    errs = [http("GET", f"{BFF}/api/orders?limit=1")[0] for _ in range(3)]
    faults["bff_during_fault_more"] = errs

    def recovered():
        return http("GET", f"{BFF}/api/orders?limit=1")[0] == 200

    poll(recovered, 90, interval=2, what="BFF recovery after fault expiry")
    faults["recovered_after_s"] = round(time.time() - t_act, 1)
    faults["list_after"] = http("GET", f"{ORDERS}/admin/faults", headers={"X-Fault-Token": FAULT_TOKEN})[2]
    out["faults"] = faults
    return out


# ----------------------------------------------------------------------------------------------- checks
class Results:
    def __init__(self) -> None:
        self.items: dict[str, dict] = {}

    def set(self, cid: str, result: str, detail: Any, evidence: str | None = None) -> None:
        name = dict(CHECKS)[cid]
        self.items[cid] = {"id": cid, "check": name, "result": result, "detail": detail, "evidence": evidence}
        log(f"{result.upper():5} {name}")


def run_checks(ctx: dict, journey: dict, actions: dict, ev_dir: Path, res: Results) -> None:  # noqa: C901, PLR0912, PLR0915
    order_id = journey["order_id"]
    tp = journey.get("traceparent") or ""
    T = tp.split("-")[1] if tp.count("-") == 3 else None
    browser_span = tp.split("-")[2] if T else None
    ctx["trace_id"] = T

    def write(name: str, data: Any) -> str:
        (ev_dir / name).write_text(json.dumps(data, indent=2, default=str) + "\n")
        return name

    # ---------- wait (bounded) until the telemetry for the journey has landed
    def journey_spans_ready():
        sp = read_spans()
        names = {(s["service"], s["name"]) for s in sp}
        return (T and any(s["trace_id"] == T and s["service"] == "hello-catalog-api" for s in sp)
                and ("hello-worker", "servicebus.process") in names
                and any(s["name"] == "orchestration:OrderProcessing" for s in sp)) and sp

    try:
        spans = poll(journey_spans_ready, 90, interval=3, what="journey spans in gateway file exporter")
    except TimeoutError:
        spans = read_spans()

    def logs_ready():
        evs = intake()["events"]
        have = {e.get("service") for e in evs}
        markers = any(ctx["redact_marker"] in json.dumps(e) for e in evs)
        return set(APPS) <= have and markers and any(f"OrderProcessing for {order_id} completed" in (e.get("message") or "") for e in evs) and evs

    try:
        poll(logs_ready, 90, interval=3, what="logs of every app at the intake")
    except TimeoutError:
        pass
    time.sleep(8)  # late duplicates (Fluent Bit retries) would show up in this window
    rcv = intake()
    events = rcv["events"]
    spans = read_spans()
    metrics = read_metrics()
    log(f"telemetry: {len(events)} log events, {len(spans)} spans, {len(metrics)} metric points, {len(rcv['others'])} other intake requests")

    # ---------- 1. RUM
    rum_events: list[dict] = []
    for r in journey["rum_requests"]:
        for ln in r["body"].splitlines():
            try:
                rum_events.append(json.loads(ln))
            except ValueError:
                pass
    by_type = collections.Counter(e.get("type") for e in rum_events)
    forwarded_paths = collections.Counter(o["path"] for o in rcv["others"] if o["path"].startswith("/api/v2/rum"))
    res_events = [e for e in rum_events if e.get("type") == "resource" and str(e.get("resource", {}).get("url", "")).startswith(BFF)]
    post_res = [e for e in res_events if e["resource"].get("method") == "POST" and e["resource"]["url"].endswith("/api/orders")]
    rum_trace_ids = sorted({str(e.get("_dd", {}).get("trace_id")) for e in post_res})
    rum_trace_match = bool(T) and any(t in (str(int(T, 16)), dd_id(T)) for t in rum_trace_ids)
    first = {t: next((e for e in rum_events if e.get("type") == t), None) for t in ("view", "resource", "action")}
    rum_q = journey["rum_requests"][0]["url"].split("?", 1)[1] if journey["rum_requests"] else ""
    rum_ev = write("rum-events.sample.json", {
        "intercepted_requests": len(journey["rum_requests"]),
        "forwarded_to_mock_intake": dict(forwarded_paths),
        "forward_statuses": collections.Counter(str(r.get("forwarded_status")) for r in journey["rum_requests"]),
        "event_types": dict(by_type), "query_example": re.sub(r"dd-api-key=[^&]+", "dd-api-key=pub***", rum_q),
        "post_orders_resource__dd_trace_id": rum_trace_ids, "browser_traceparent": tp,
        "first_events": {t: _trim_rum(e) for t, e in first.items()},
    })
    ok = by_type.get("view", 0) >= 1 and len(res_events) >= 1 and by_type.get("action", 0) >= 1 and sum(forwarded_paths.values()) >= 1
    res.set("rum", "pass" if ok else "fail", {
        "event_types": dict(by_type), "bff_resource_events": len(res_events),
        "rum_requests_forwarded_to_mock": sum(forwarded_paths.values()),
        "post_orders_resource_trace_id_matches_traceparent": rum_trace_match}, rum_ev)

    # ---------- 2. trace correlation
    tspans = [s for s in spans if s["trace_id"] == T] if T else []
    services_in_t = sorted({s["service"] for s in tspans})
    db_spans = [s for s in tspans if s["scope"].endswith("SqlClient") or "psycopg" in s["scope"] or s["attributes"].get("db.system")
                or s["attributes"].get("db.system.name")]
    sql_spans = [s for s in db_spans if "SqlClient" in s["scope"] or "mssql" in str(s["attributes"].get("db.system", s["attributes"].get("db.system.name", "")))]
    pg_spans_t = [s for s in db_spans if "psycopg" in s["scope"] or "postgres" in str(s["attributes"].get("db.system", ""))]
    bff_server = [s for s in tspans if s["service"] == "hello-bff" and s["kind"] == "server" and s["name"].startswith("POST")]
    parent_ok = any(s["parent_span_id"] == browser_span for s in bff_server)
    # PostgreSQL client spans of the browser's product-list trace (cache-aside may serve the order's price from Redis)
    ptp = journey.get("products_traceparent") or ""
    PT = ptp.split("-")[1] if ptp.count("-") == 3 else None
    pg_products = [s for s in spans if PT and s["trace_id"] == PT and ("psycopg" in s["scope"])]
    redis_t = [s for s in tspans if "redis" in s["scope"]]
    need = {"hello-bff", "hello-orders-api", "hello-catalog-api"}
    ok = bool(T) and need <= set(services_in_t) and bool(sql_spans) and parent_ok
    tr_ev = write("trace-journey.json", {
        "browser_traceparent": tp, "trace_id": T, "services_in_trace": services_in_t,
        "bff_server_parent_is_browser_span": parent_ok,
        "spans": [_trim_span(s) for s in sorted(tspans, key=lambda s: s["start"])][:120],
        "products_list_trace": {"traceparent": ptp, "postgresql_spans": [_trim_span(s) for s in pg_products][:10]},
    })
    res.set("trace_correlation", "pass" if ok else "fail", {
        "trace_id": T, "services_in_trace": services_in_t, "bff_server_parent_is_browser_span": parent_ok,
        "sql_server_client_spans_in_trace": len(sql_spans), "postgresql_client_spans_in_trace": len(pg_spans_t),
        "redis_spans_in_trace": len(redis_t), "postgresql_client_spans_in_products_list_trace": len(pg_products),
        "span_count": len(tspans)}, tr_ev)

    # ---------- 3. durable workflow
    inst = f"order-{order_id}"
    dspans = [s for s in spans if s["service"] == "hello-durable"]
    inst_spans = [s for s in dspans if inst in json.dumps(s["attributes"])]
    d_traces = {s["trace_id"] for s in inst_spans}
    in_traces = [s for s in dspans if s["trace_id"] in d_traces]
    orch = [s for s in in_traces if s["name"] == "orchestration:OrderProcessing"]
    acts = collections.Counter(s["name"] for s in in_traces if s["name"].startswith("activity:"))
    linked = [s for s in spans if s["trace_id"] in d_traces and any(ln["trace_id"] == T for ln in s["links"])]
    tied = bool(T) and (T in d_traces or bool(linked))
    starter = [s for s in in_traces if s["name"] == "process order-events"]
    expected_acts = {"activity:ReserveInventory", "activity:ChargePayment", "activity:RecordFulfillment", "activity:UpdateOrderStatus"}
    d_sql = [s for s in in_traces if "SqlClient" in s["scope"]]
    d_http = collections.Counter((s["service"], s["name"]) for s in spans if s["trace_id"] in d_traces and s["kind"] == "server" and s["service"] != "hello-durable")
    ok = bool(orch) and expected_acts <= set(acts) and tied and journey["status"] == "Fulfilled"
    d_ev = write("durable-workflow.json", {
        "instance_id": inst, "order_status_in_browser": journey["status"], "timeline": journey["timeline"],
        "workflow_trace_ids": sorted(d_traces), "same_trace_as_browser": T in d_traces,
        "spans_linking_to_browser_trace": [_trim_span(s) for s in linked][:10],
        "starter_spans": [_trim_span(s) for s in starter], "orchestration_spans": [_trim_span(s) for s in orch],
        "activity_span_counts": dict(acts), "sql_spans_in_workflow_trace": [_trim_span(s) for s in d_sql][:10],
        "downstream_server_spans_in_workflow_trace": {f"{k[0]} {k[1]}": v for k, v in d_http.items()},
    })
    res.set("durable_workflow", "pass" if ok else "fail", {
        "instance_id": inst, "orchestration_spans": len(orch), "activities": dict(acts), "same_trace_as_browser": T in d_traces,
        "spans_with_link_to_browser_trace": len(linked), "status": journey["status"],
        "downstream_server_spans": {f"{k[0]} {k[1]}": v for k, v in d_http.items()}}, d_ev)

    # ---------- 4. worker consumer link
    producers = [s for s in tspans if s["kind"] == "producer" and s["service"] == "hello-orders-api"]
    prod_ids = {s["span_id"] for s in producers}
    wspans = [s for s in spans if s["service"] == "hello-worker" and s["name"] == "servicebus.process"]
    wlinked = [s for s in wspans if any(ln["trace_id"] == T for ln in s["links"])]
    link_to_producer = [s for s in wlinked if any(ln["span_id"] in prod_ids for ln in s["links"])]
    ok = bool(wlinked) and all(s["kind"] == "consumer" for s in wlinked) and bool(link_to_producer) and all(s["trace_id"] != T for s in wlinked)
    w_ev = write("worker-consumer.json", {"producer_spans": [_trim_span(s) for s in producers],
                                          "worker_process_spans_linked": [_trim_span(s) for s in wlinked]})
    res.set("worker_consumer", "pass" if ok else "fail", {
        "servicebus_process_spans": len(wspans), "linked_to_browser_trace": len(wlinked),
        "link_targets_a_producer_span": len(link_to_producer), "new_trace_not_parent": all(s["trace_id"] != T for s in wlinked),
        "producer_spans": sorted({s["name"] for s in producers})}, w_ev)

    # ---------- 5. logs via Fluent Bit
    per_svc: dict = {}
    problems: list[str] = []
    for svc, (_, src, team) in APPS.items():
        evs = [e for e in events if e.get("service") == svc]
        tags_ok = [e for e in evs if all(t in (e.get("ddtags") or "").split(",") for t in
                                         ("env:e2e", f"service:{svc}", f"version:{VERSION}", f"team:{team}", "telemetry.pipeline:fluent-bit"))]
        src_ok = [e for e in evs if e.get("ddsource") == src]
        per_svc[svc] = {"events": len(evs), "with_required_ddtags": len(tags_ok), "with_ddsource": len(src_ok)}
        if not evs or len(tags_ok) != len(evs) or len(src_ok) != len(evs):
            problems.append(f"{svc}: {per_svc[svc]}")
    journey_logs = [e for e in events if T and e.get("trace_id") == T]
    jl_services = sorted({e["service"] for e in journey_logs})
    bad_dd = [e for e in events if e.get("trace_id") and (e.get("dd.trace_id") != dd_id(e["trace_id"]) or
                                                          (e.get("span_id") and e.get("dd.span_id") != str(int(e["span_id"], 16))))]
    no_pipeline = [e for e in events if "telemetry.pipeline:fluent-bit" not in (e.get("ddtags") or "").split(",")]
    req_ok = all(r["path"] == "/api/v2/logs" and r["content_encoding"] == "gzip" and r["api_key_present"] for r in rcv["requests"])
    ok = not problems and {"hello-orders-api", "hello-catalog-api"} <= set(jl_services) and not bad_dd and not no_pipeline and req_ok
    l_ev = write("logs-sample.json", {
        "per_service": per_svc, "journey_trace_id": T, "journey_log_services": jl_services,
        "journey_logs": [_trim_log(e) for e in journey_logs][:40],
        "one_event_per_service": {svc: _trim_log(next((e for e in reversed(events) if e.get("service") == svc and e.get("trace_id")),
                                                      next((e for e in events if e.get("service") == svc), {}))) for svc in APPS},
        "intake_log_requests": len(rcv["requests"]), "all_requests_gzip_with_api_key": req_ok,
    })
    res.set("logs_fluentbit", "pass" if ok else "fail", {
        "per_service": per_svc, "journey_log_services_with_trace_id": jl_services,
        "dd_trace_id_mismatches": len(bad_dd), "events_without_pipeline_tag": len(no_pipeline), "problems": problems,
        "note": "hello-durable lines are the Functions host console stream (plain text, no trace_id); see README"}, l_ev)

    # ---------- 6. duplicates
    def count(pred) -> int:
        return sum(1 for e in events if pred(e))

    msg = lambda e: e.get("message") or ""  # noqa: E731
    markers = {
        "hello-orders-api": count(lambda e: e.get("service") == "hello-orders-api" and msg(e).startswith(f"Order {order_id} created")),
        "hello-catalog-api": count(lambda e: e.get("service") == "hello-catalog-api" and msg(e) == "product upserted" and e.get("sku") == ctx["marker_sku"]),
        "hello-inventory-api": count(lambda e: e.get("service") == "hello-inventory-api" and msg(e).startswith("Reservation") and order_id in msg(e)),
        "hello-partner-sim": count(lambda e: e.get("service") == "hello-partner-sim" and msg(e) == "payment processed" and e.get("order_id") == order_id),
        "hello-worker": count(lambda e: e.get("service") == "hello-worker" and msg(e) == "notification recorded" and e.get("order_id") == order_id),
        "hello-durable": count(lambda e: e.get("service") == "hello-durable" and f"OrderProcessing for {order_id} completed" in msg(e)),
        "hello-bff": count(lambda e: e.get("service") == "hello-bff" and e.get("trace_id") == ctx.get("fault_trace_id") and "Attempt: '2'" in msg(e)),
        "hello-dbadapter-postgresql": count(lambda e: e.get("service") == "hello-dbadapter-postgresql" and msg(e) == "POST /roundtrip 200"
                                            and e.get("trace_id") == _tid(journey.get("adapter_traceparent"))),
    }
    canon = collections.Counter(json.dumps(e, sort_keys=True) for e in events)
    dup_events = {k: v for k, v in canon.items() if v > 1}
    dup_json = {k: v for k, v in dup_events.items() if '"logger"' in k}
    # plain-text (hello-durable host console) records carry no app timestamp, so repeated host lines read in one
    # flush are byte-identical at the intake. Compare each repeated record with its multiplicity in the SOURCE file:
    # a transport duplicate is a record seen more often at the intake than it was written.
    src = compose("exec", "-T", "durable", "cat", "/var/log/app/app.log", check=False).stdout if dup_events else ""
    transport_dups = {}
    for k, v in dup_events.items():
        if k in dup_json:
            continue
        m = json.loads(k).get("message", "")
        written = src.count(m.rstrip("\n")) if m else 0
        if v > written:
            transport_dups[m[:200]] = {"at_intake": v, "in_source_file": written}
    span_keys = collections.Counter((s["trace_id"], s["span_id"]) for s in spans)
    dup_spans = [k for k, v in span_keys.items() if v > 1]
    ok = all(v == 1 for v in markers.values()) and not dup_json and not dup_spans and not transport_dups
    dup_ev = write("duplicates.json", {
        "marker_counts": markers, "marker_definitions": {
            "hello-orders-api": f"message startswith 'Order {order_id} created'",
            "hello-catalog-api": f"'product upserted' sku={ctx['marker_sku']} (direct POST /products)",
            "hello-inventory-api": f"'Reservation ... order {order_id}'", "hello-partner-sim": f"'payment processed' order_id={order_id}",
            "hello-worker": f"'notification recorded' order_id={order_id}", "hello-durable": f"'OrderProcessing for {order_id} completed'",
            "hello-bff": f"retry attempt 2 log of the single fault-window request trace {ctx.get('fault_trace_id')}",
            "hello-dbadapter-postgresql": f"'POST /roundtrip 200' of the browser roundtrip trace {_tid(journey.get('adapter_traceparent'))}"},
        "identical_events_total": sum(v - 1 for v in dup_events.values()),
        "identical_structured_app_events": sum(v - 1 for v in dup_json.values()),
        "identical_events_examples": [json.loads(k).get("message", "")[:160] for k in list(dup_events)[:5]],
        "identical_plaintext_events_more_often_at_intake_than_in_source_file": transport_dups,
        "duplicate_span_ids": len(dup_spans), "spans_total": len(spans), "log_events_total": len(events),
    })
    res.set("no_duplicates", "pass" if ok else "fail", {
        "marker_counts": markers, "identical_structured_app_events": sum(v - 1 for v in dup_json.values()),
        "repeated_plaintext_host_lines (also repeated in source file)": sum(v - 1 for v in dup_events.values()) - sum(v - 1 for v in dup_json.values()),
        "transport_duplicates_vs_source_file": len(transport_dups),
        "duplicate_span_ids": len(dup_spans)}, dup_ev)

    # ---------- 7. tags / resource attributes
    tag_report: dict = {}
    bad: list[str] = []
    for svc in APPS:
        ss = [s for s in spans if s["service"] == svc]
        scopes: dict = {}
        for s in ss:
            missing = [a for a in REQUIRED_RESOURCE_ATTRS if not s["resource"].get(a)]
            wrong = [a for a, v in (("service.version", VERSION), ("deployment.environment.name", "e2e")) if s["resource"].get(a) not in (None, v)]
            key = s["scope"]
            sc = scopes.setdefault(key, {"spans": 0, "missing": set(), "wrong": set()})
            sc["spans"] += 1
            sc["missing"].update(missing)
            sc["wrong"].update(wrong)
        tag_report[svc] = {k: {"spans": v["spans"], "missing": sorted(v["missing"]), "wrong": sorted(v["wrong"])} for k, v in scopes.items()}
        if not ss:
            bad.append(f"{svc}: no spans")
        for k, v in scopes.items():
            if v["missing"] or v["wrong"]:
                bad.append(f"{svc}/{k}: missing={sorted(v['missing'])} wrong={sorted(v['wrong'])}")
    m_services = collections.defaultdict(set)
    for m in metrics:
        m_services[m["service"]].add(m["name"])
    m_missing = {svc: [a for a in REQUIRED_RESOURCE_ATTRS if not next((m["resource"].get(a) for m in metrics if m["service"] == svc), None)]
                 for svc in APPS if svc in m_services}
    wf = [m for m in metrics if m["name"] == "hello.workflow.completed"]
    leaked = sorted({k for m in metrics if m["service"] in APPS for k, v in m["attributes"].items() if isinstance(v, str) and order_id in v})
    # RUM SDK v5+ carries unified tags in each event's `ddtags` (env/service/version from datadogRum.init)
    rum_core = [e for e in rum_events if e.get("type") in ("view", "resource", "action")]
    rum_ddtags = sorted({e.get("ddtags", "") for e in rum_core})
    rum_tags_ok = bool(rum_core) and all(all(t in (e.get("ddtags") or "").split(",") for t in ("env:e2e", "service:hello-frontend", f"version:{VERSION}"))
                                         for e in rum_core)
    rum_fields_ok = bool(rum_core) and all(e.get("service") == "hello-frontend" and e.get("version") == VERSION for e in rum_core)
    log_fields = {svc: sorted({k for e in events if e.get("service") == svc for k in ("env", "version", "dd.service", "dd.env", "dd.version") if k in e})
                  for svc in APPS}
    ok = not bad and not any(m_missing.values()) and rum_tags_ok and rum_fields_ok and not leaked
    t_ev = write("tags.json", {"required_resource_attributes": REQUIRED_RESOURCE_ATTRS, "spans_by_service_scope": tag_report,
                               "span_problems": bad, "metrics_services": {k: len(v) for k, v in m_services.items()},
                               "metrics_resource_missing": m_missing,
                               "hello.workflow.completed": [{"attributes": m["attributes"], "value": m["value"]} for m in wf][:10],
                               "metric_attributes_containing_order_id": leaked,
                               "rum_event_ddtags": rum_ddtags[:3], "rum_ddtags_ok": rum_tags_ok, "rum_event_service_version_ok": rum_fields_ok,
                               "log_unified_fields_present": log_fields})
    res.set("tags", "pass" if ok else "fail", {"span_problems": bad, "metrics_resource_missing": m_missing,
                                               "rum_tags_ok": rum_tags_ok and rum_fields_ok,
                                               "workflow_metric_points": len(wf), "order_id_in_metric_attributes": leaked}, t_ev)

    # ---------- 8. redaction
    blob = json.dumps(events)
    leaked_secret = ctx["fake_secret"] in blob or ctx["fake_jwt"] in blob
    app_ev = [e for e in events if ctx["redact_marker"] in json.dumps(e) and "-transport" not in (e.get("message") or "")]
    tr_ev_ = [e for e in events if f"{ctx['redact_marker']}-transport" in (e.get("message") or "")]
    redacted_app = bool(app_ev) and all("[REDACTED]" in json.dumps(e) for e in app_ev)
    redacted_tr = bool(tr_ev_) and all("[REDACTED]" in json.dumps(e) for e in tr_ev_) and \
        all(e.get("client_secret") == "[REDACTED]" for e in tr_ev_)
    ok = not leaked_secret and redacted_app and redacted_tr
    r_ev = write("redaction.json", {"fake_secret_masked": mask(ctx["fake_secret"]), "fake_secret_found_at_intake": leaked_secret,
                                    "app_path_events": [_trim_log(e) for e in app_ev][:5],
                                    "transport_path_events": [_trim_log(e) for e in tr_ev_][:5]})
    res.set("redaction", "pass" if ok else "fail", {"fake_secret_found_at_intake": leaked_secret, "app_path_events": len(app_ev),
                                                    "app_path_redacted": redacted_app, "transport_path_events": len(tr_ev_),
                                                    "transport_path_redacted": redacted_tr}, r_ev)

    # ---------- 9. faults
    f = actions["faults"]
    fault_spans = [s for s in spans if s["trace_id"] == ctx.get("fault_trace_id")]
    fault_logs = [e for e in events if e.get("trace_id") == ctx.get("fault_trace_id")]
    ok = (f["wrong_token"] == 403 and f["missing_token"] == 403 and f["disabled_service_catalog"] == 404 and f["activate"]["status"] == 201
          and f["bff_during_fault"]["status"] >= 500 and all(s >= 500 for s in f["bff_during_fault_more"]) and f["recovered_after_s"] <= 75
          and not (f["list_after"] or {}).get("faults"))
    f_ev = write("faults.json", {**f, "fault_trace_spans": [_trim_span(s) for s in fault_spans][:20],
                                 "fault_trace_logs": [_trim_log(e) for e in fault_logs][:20]})
    res.set("faults", "pass" if ok else "fail", {k: f[k] for k in ("wrong_token", "missing_token", "disabled_service_catalog")} | {
        "activate": f["activate"]["status"], "bff_during_fault": f["bff_during_fault"]["status"], "bff_more": f["bff_during_fault_more"],
        "recovered_after_s": f["recovered_after_s"], "fault_trace_spans": len(fault_spans), "fault_trace_logs": len(fault_logs)}, f_ev)

    # ---------- 10. idempotency
    i = actions["idempotency"]
    ok = (i["first"]["status"] in (200, 201, 202) and i["replay"]["status"] in (200, 201, 202) and i["first"]["order_id"]
          and i["first"]["order_id"] == i["replay"]["order_id"] and i["orders_with_customer_ref"] == 1)
    i_ev = write("idempotency.json", i)
    res.set("idempotency", "pass" if ok else "fail", i, i_ev)

    # ---------- 11. exporter transport
    others = collections.Counter(o["path"] for o in rcv["others"])
    accepted_logs = sum(float(m["value"] or 0) for m in metrics if m["name"] in ("otelcol_receiver_accepted_log_records", "otelcol_receiver_accepted_log_records_total"))
    ok = others.get("/api/v0.2/traces", 0) > 0 and (others.get("/api/v2/series", 0) + others.get("/api/beta/sketches", 0)) > 0 \
        and all(o["api_key_present"] for o in rcv["others"] if not o["path"].startswith("/api/v2/rum"))
    x_ev = write("intake-requests.json", {"log_requests": len(rcv["requests"]), "other_requests_by_path": dict(others),
                                          "gateway_otlp_log_records_accepted_and_dropped": accepted_logs})
    res.set("exporter_transport", "pass" if ok else "fail", {"other_requests_by_path": dict(others),
                                                             "gateway_otlp_log_records_accepted_then_dropped_by_nop": accepted_logs}, x_ev)


def _tid(tp: str | None) -> str | None:
    return tp.split("-")[1] if tp and tp.count("-") == 3 else None


def _trim_span(s: dict) -> dict:
    keep = ("http.request.method", "http.route", "http.response.status_code", "url.full", "server.address", "db.system", "db.system.name",
            "db.namespace", "db.operation.name", "messaging.system", "messaging.destination.name", "messaging.operation.type",
            "messaging.message.id", "durabletask.task.instance_id", "durabletask.type", "durabletask.task.name", "order.id")
    return {"service": s["service"], "scope": s["scope"], "name": s["name"], "kind": s["kind"], "trace_id": s["trace_id"],
            "span_id": s["span_id"], "parent_span_id": s["parent_span_id"], "links": s["links"],
            "attributes": {k: v for k, v in s["attributes"].items() if k in keep or k.startswith("durabletask")}}


def _trim_log(e: dict) -> dict:
    return {k: (v[:400] if isinstance(v, str) else v) for k, v in e.items() if k not in ("error.stack",)}


def _trim_rum(e: dict | None) -> dict | None:
    if not e:
        return None
    keep = {k: e.get(k) for k in ("type", "service", "version", "date", "source")}
    keep["view"] = {k: e.get("view", {}).get(k) for k in ("url", "name")}
    if e.get("type") == "resource":
        keep["resource"] = {k: e["resource"].get(k) for k in ("type", "method", "url", "status_code")}
        keep["_dd"] = {k: e.get("_dd", {}).get(k) for k in ("trace_id", "span_id")}
    if e.get("type") == "action":
        keep["action"] = {k: e["action"].get(k) for k in ("type",)} | {"target": e["action"].get("target", {}).get("name")}
    return keep


# ----------------------------------------------------------------------------------------------- evidence
def image_info() -> dict:
    out = {}
    for s in IMAGES:
        r = sh("docker", "image", "inspect", f"hello-{s}:{VERSION}", "--format",
               "{{.Id}} {{index .Config.Labels \"org.opencontainers.image.revision\"}} {{.Created}}", check=False)
        out[f"hello-{s}:{VERSION}"] = r.stdout.strip() if r.returncode == 0 else "missing"
    return out


def write_evidence(ev_dir: Path, meta: dict, res: Results) -> None:
    summary = {"label": LABEL, **meta, "results": list(res.items.values()),
               "totals": dict(collections.Counter(r["result"] for r in res.items.values()))}
    (ev_dir / "summary.json").write_text(json.dumps(summary, indent=2, default=str) + "\n")
    rel = ev_dir.relative_to(EVIDENCE_ROOT)
    lines = [
        "# Local end-to-end integration evidence (LATEST)",
        "",
        f"Status label: **{LABEL}**. This is NOT Datadog-verified and nothing was deployed: every Datadog endpoint is the",
        "local mock intake (`observability/tests/transport/mock_intake`), Azure Service Bus/Storage are the official emulators,",
        "Cosmos DB is replaced by hello-inventory-api `STORAGE_MODE=memory`. See `tests/integration/README.md`.",
        "",
        f"- Run: `{rel}` (UTC {meta['started_utc']} -> {meta['finished_utc']}), git `{meta['git_commit']}`, images `:{VERSION}` built from source",
        f"- Command: `{meta['command']}`",
        f"- Order: `{meta.get('order_id')}` final status `{meta.get('order_status')}`; browser trace `{meta.get('trace_id')}`",
        f"- Totals: {summary['totals']}",
        "",
        "| # | Check | Result | Evidence |",
        "|---|---|---|---|",
    ]
    for i, (cid, name) in enumerate(CHECKS, 1):
        r = res.items.get(cid, {"result": "not run", "evidence": None})
        evf = f"[{r['evidence']}]({rel}/{r['evidence']})" if r.get("evidence") else f"[summary.json]({rel}/summary.json)"
        lines.append(f"| {i} | {name.split('. ', 1)[-1]} | {r['result']} | {evf} |")
    lines += ["", "Known gaps (not covered locally): Cosmos DB (memory store), Entra ID auth (AUTH_MODE=none, SQL/PG password auth),",
              "Event Hubs/Kafka aggregator path for App Service/Functions logs (covered separately by observability/tests/transport),",
              "Azure Monitor diagnostic settings, real Datadog ingestion/indexing/UI (mock intake only).", ""]
    (EVIDENCE_ROOT / "LATEST.md").write_text("\n".join(lines))


# ----------------------------------------------------------------------------------------------- main
def run(keep: bool = False, rebuild: bool = False, reuse: bool = False) -> dict:
    started = dt.datetime.now(dt.UTC)
    stamp = started.strftime("%Y%m%dT%H%M%SZ")
    ev_dir = EVIDENCE_ROOT / stamp
    ev_dir.mkdir(parents=True, exist_ok=True)
    rnd = uuid.uuid4().hex[:8]
    ctx: dict = {
        "sku": f"SKU-{random.randint(6, 19):04d}", "quantity": 2,
        "marker_sku": f"E2E-MARKER-{rnd.upper()}", "idem_customer": f"cust-e2e-idem-{rnd}",
        "redact_marker": f"e2e-redact-{rnd}", "fake_secret": f"FAKE{uuid.uuid4().hex}", "fake_jwt": f"eyJFAKE{uuid.uuid4().hex}",
    }
    res = Results()
    meta: dict = {"started_utc": started.isoformat(timespec="seconds"), "git_commit": git_commit(), "version": VERSION,
                  "command": " ".join(["python3", "tests/integration/run_e2e.py", *sys.argv[1:]]) if __name__ == "__main__" else "pytest tests/integration/test_e2e.py"}
    journey: dict = {}
    try:
        if not reuse:
            ensure_images(rebuild)
            stack_up()
        meta["images"] = image_info()
        meta["readiness"] = wait_ready()
        meta["seed"] = seed()
        log(f"browser journey (sku={ctx['sku']})")
        journey = browser_journey(ctx)
        meta.update({"order_id": journey["order_id"], "order_status": journey["status"], "trace_id": _tid(journey.get("traceparent")),
                     "journey": {k: journey[k] for k in ("timeline", "footer", "product_rows", "seconds_to_terminal_status",
                                                         "adapter_result", "console_errors", "traceparent", "adapter_traceparent")}})
        meta["journey"]["api_requests"] = [{**r, "url": r["url"].replace(BFF, "")} for r in journey["api_requests"]]
        log(f"order {journey['order_id']} -> {journey['status']} in {journey['seconds_to_terminal_status']}s; API side actions (faults take ~35 s)")
        actions = api_actions(ctx)
        run_checks(ctx, journey, actions, ev_dir, res)
    except Exception as exc:  # noqa: BLE001 - recorded in the evidence, then re-raised via the exit code
        meta["error"] = f"{type(exc).__name__}: {exc}"
        log(f"ERROR {meta['error']}")
        try:
            ps = compose("ps", "-a", "--format", "{{.Service}} {{.State}} {{.Status}}", check=False).stdout
            meta["compose_ps"] = ps.splitlines()
        except Exception:  # noqa: BLE001
            pass
    finally:
        if not keep and not reuse:
            stack_down()
        elif not keep and reuse:
            log("--reuse without --keep: leaving the stack running (it was not started by this run)")
        meta["finished_utc"] = dt.datetime.now(dt.UTC).isoformat(timespec="seconds")
        write_evidence(ev_dir, meta, res)
        log(f"evidence: {ev_dir.relative_to(REPO)} ; summary: docs/evidence/local/LATEST.md")
    return {"meta": meta, "results": res.items, "evidence_dir": str(ev_dir)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keep", action="store_true", help="do not tear the stack down at the end")
    ap.add_argument("--rebuild", action="store_true", help="rebuild all app images from source before starting")
    ap.add_argument("--reuse", action="store_true", help="use an already running stack (started with --keep)")
    a = ap.parse_args()
    out = run(keep=a.keep, rebuild=a.rebuild, reuse=a.reuse)
    failed = [r for r in out["results"].values() if r["result"] == "fail"]
    missing = [cid for cid, _ in CHECKS if cid not in out["results"]]
    print(json.dumps({r["id"]: r["result"] for r in out["results"].values()}, indent=1))
    return 1 if failed or missing or out["meta"].get("error") else 0


if __name__ == "__main__":
    sys.exit(main())
