"""API and browser journeys. Every journey is one root span; outbound calls carry W3C traceparent
(httpx instrumentation) and a `User-Agent: hello-traffic/<version>` + `X-Synthetic: hello-traffic` marker."""

from __future__ import annotations

import logging
import random
import time
import uuid
from dataclasses import dataclass
from typing import Any

import httpx
from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode

from hello_common.http import create_client

log = logging.getLogger("hello_traffic")
tracer = trace.get_tracer("hello_traffic")
TERMINAL = {"Fulfilled", "Failed"}


@dataclass
class JourneyResult:
    kind: str
    ok: bool
    duration_ms: float
    detail: str = ""
    order_id: str | None = None
    final_status: str | None = None


def synthetic_headers(version: str) -> dict[str, str]:
    return {"User-Agent": f"hello-traffic/{version}", "X-Synthetic": "hello-traffic"}


def discover_api_base(frontend_url: str, client: httpx.Client) -> str:
    r = client.get(frontend_url.rstrip("/") + "/config.json")
    r.raise_for_status()
    base = r.json().get("apiBaseUrl") or ""
    if base.startswith("/") or not base:
        base = frontend_url.rstrip("/") + base
    return base.rstrip("/")


def _order_id(body: Any) -> str:
    if isinstance(body, dict):
        o = body.get("order", body)
        return str(o.get("id") or o.get("order_id") or "")
    return ""


def api_journey(
    client: httpx.Client,
    skus: list[str],
    *,
    order_timeout: float = 90.0,
    poll_interval: float = 2.0,
    roundtrip_adapters: bool = False,
    rng: random.Random | None = None,
    sleep=time.sleep,
) -> JourneyResult:
    rng = rng or random.Random()
    started = time.perf_counter()
    with tracer.start_as_current_span("journey api", attributes={"journey": "api"}) as span:
        try:
            products = client.get("/api/catalog/products")
            products.raise_for_status()
            sku = rng.choice(skus)
            client.get(f"/api/catalog/products/{sku}").raise_for_status()
            key = str(uuid.uuid4())
            created = client.post(
                "/api/orders",
                json={"sku": sku, "quantity": rng.randint(1, 3), "customer_ref": f"synthetic-{rng.randint(1, 50):03d}"},
                headers={"Idempotency-Key": key},
            )
            created.raise_for_status()
            order_id = _order_id(created.json())
            if not order_id:
                raise ValueError("order id missing in response")
            status = "Pending"
            deadline = time.monotonic() + order_timeout
            while time.monotonic() < deadline:
                r = client.get(f"/api/orders/{order_id}")
                if r.status_code == 200:
                    status = str(r.json().get("status", status))
                    if status in TERMINAL:
                        break
                sleep(poll_interval)
            if roundtrip_adapters:
                adapters = client.get("/api/adapters")
                if adapters.status_code == 200 and isinstance(adapters.json(), list) and adapters.json():
                    a = rng.choice(adapters.json())
                    client.post(a.get("roundtrip_path") or f"/api/adapters/{a['family']}/roundtrip", json={})
            ok = status == "Fulfilled"
            span.set_attribute("app.order_status", status)
            if not ok:
                span.set_status(Status(StatusCode.ERROR, f"order ended {status}"))
            return JourneyResult("api", ok, (time.perf_counter() - started) * 1000, f"order {status}", order_id, status)
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, type(exc).__name__))
            return JourneyResult("api", False, (time.perf_counter() - started) * 1000, f"{type(exc).__name__}: {str(exc)[:160]}")


def browser_journey(
    frontend_url: str,
    *,
    order_timeout: float = 90.0,
    headless: bool = True,
    executable_path: str | None = None,
    rng: random.Random | None = None,
    user_agent: str = "hello-traffic",
) -> JourneyResult:
    """Chromium journey through the real UI: products -> order -> wait for terminal status.
    The page's own Datadog RUM (when configured) records this as a real browser session."""
    from playwright.sync_api import sync_playwright

    rng = rng or random.Random()
    started = time.perf_counter()
    with tracer.start_as_current_span("journey browser", attributes={"journey": "browser"}) as span:
        try:
            with sync_playwright() as pw:
                browser = pw.chromium.launch(headless=headless, executable_path=executable_path)
                try:
                    context = browser.new_context(user_agent=f"Mozilla/5.0 (X11; Linux x86_64) Chrome {user_agent}")
                    page = context.new_page()
                    page.set_default_timeout(30_000)
                    page.goto(frontend_url, wait_until="domcontentloaded")
                    page.get_by_test_id("product-list").wait_for()
                    buttons = page.locator("[data-testid^='order-SKU-']")
                    count = buttons.count()
                    if count == 0:
                        raise RuntimeError("no products rendered")
                    buttons.nth(rng.randrange(count)).click()
                    page.get_by_test_id("quantity-input").fill(str(rng.randint(1, 3)))
                    page.get_by_test_id("place-order").click()
                    page.wait_for_url("**/#/orders/*")
                    order_id = page.url.rsplit("/", 1)[-1]
                    status_el = page.get_by_test_id("order-status")
                    page.wait_for_function(
                        "() => ['Fulfilled','Failed'].includes(document.querySelector(\"[data-testid='order-status']\")?.dataset.status)",
                        timeout=order_timeout * 1000,
                    )
                    status = status_el.get_attribute("data-status") or "Unknown"
                    context.close()
                finally:
                    browser.close()
            ok = status == "Fulfilled"
            span.set_attribute("app.order_status", status)
            if not ok:
                span.set_status(Status(StatusCode.ERROR, f"order ended {status}"))
            return JourneyResult("browser", ok, (time.perf_counter() - started) * 1000, f"order {status}", order_id, status)
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, type(exc).__name__))
            return JourneyResult("browser", False, (time.perf_counter() - started) * 1000, f"{type(exc).__name__}: {str(exc)[:160]}")


def make_api_client(base_url: str, version: str) -> httpx.Client:
    return create_client(base_url, timeout=10.0, retries=2, headers=synthetic_headers(version))
