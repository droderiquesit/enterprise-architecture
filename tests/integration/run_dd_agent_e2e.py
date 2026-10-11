#!/usr/bin/env python3
"""Datadog-Agent variant of the local e2e run: TELEMETRY_SDK=datadog through a REAL Datadog Agent (7.84.2).

Stack: tests/integration/datadog_agent/docker-compose.yml (project eh-dd); checks: CHECKS below; details:
tests/integration/README.md "Datadog Agent variant".

Usage: python3 tests/integration/run_dd_agent_e2e.py [--keep] [--reuse] [--rebuild]
Evidence: docs/evidence/local/<UTC>-datadog-agent/ + docs/evidence/local/LATEST-datadog-agent.md
Status produced: locally-verified (real Datadog Agent, mock intake) - nothing reaches Datadog.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import traceback
import uuid
from pathlib import Path

from e2elib import http, image_exists, logger, poll, sh, utc_iso, utc_stamp

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
COMPOSE_DIR = HERE / "datadog_agent"
PROJECT = "eh-dd"
VERSION = "0.1.0-e2e"
EVIDENCE_ROOT = REPO / "docs" / "evidence" / "local"
CATALOG = "http://127.0.0.1:18182"
ORDERS = "http://127.0.0.1:18183"
TAP = "http://127.0.0.1:18191"
INTAKE = "http://127.0.0.1:18190"
DERIVED = f"hello-orders-api-ddtrace:{VERSION}"

CHECKS = [
    ("dd-1", "Datadog Agent 7.84.2 healthy; catalog-api and orders-api serving"),
    ("dd-2", "traces from ddtrace (Python) and dd-trace-dotnet reached the intake through the Agent"),
    ("dd-3", "distributed trace .NET -> Python with one 128-bit trace id, correct parenting, traceparent response header"),
    ("dd-4", "Activity-based custom span (Hello.App 'send order-events') recorded by the Datadog .NET tracer"),
    ("dd-5", "health probes are not traced (Python probe filter)"),
    ("dd-6", "log correlation: Agent-collected logs carry the ids of received traces (both services)"),
    ("dd-7", "hello.* custom metrics via DogStatsD -> Agent -> series intake (both services, bounded tags)"),
    ("dd-8", "Continuous Profiler: Python and .NET profiles through the Agent profiling proxy"),
    ("dd-9", "datadog mode runs no OpenTelemetry SDK / OTLP exporter"),
    ("dd-10", "API key on every Agent payload; nothing sent to a real Datadog endpoint"),
]


log = logger("dd-e2e")


def compose(*args: str, check: bool = True) -> str:
    return sh("docker", "compose", "-p", PROJECT, "-f", str(COMPOSE_DIR / "docker-compose.yml"), *args, check=check, timeout=1800).stdout


def build(rebuild: bool) -> None:
    missing = [s for s in ("catalog-api", "orders-api") if rebuild or not image_exists(f"hello-{s}:{VERSION}")]
    if missing:
        log(f"building {missing} from the current source")
        sh(str(HERE / "build_images.sh"), *missing, capture=False)
    if rebuild or missing or not image_exists(DERIVED):
        log(f"building {DERIVED} (Datadog .NET tracer home, sha256-verified download)")
        args = ["docker", "build", "-q", "-f", str(COMPOSE_DIR / "Dockerfile.orders-api-ddtrace"),
                "--build-arg", f"BASE=hello-orders-api:{VERSION}", "-t", DERIVED]
        proxy = os.environ.get("HTTPS_PROXY")
        if proxy:
            args += ["--network", "host", "--build-arg", f"HTTPS_PROXY={proxy}", "--build-arg", f"https_proxy={proxy}"]
        ca = os.environ.get("CA_BUNDLE") or ("/root/.ccr/ca-bundle.crt" if Path("/root/.ccr/ca-bundle.crt").exists() else "")
        if ca:
            args += ["--secret", f"id=ca_bundle,src={ca}"]
        sh(*args, str(COMPOSE_DIR), timeout=1800)


def wait(fn, seconds: int, interval: float = 2) -> bool:
    try:
        return bool(poll(fn, seconds, interval))
    except TimeoutError:
        return False


def wait_http(url: str, seconds: int) -> bool:
    return wait(lambda: http("GET", url, timeout=3)[0] == 200, seconds)


def journey() -> dict:
    out: dict = {"requests": []}

    def rec(name: str, status: int, extra: dict | None = None) -> None:
        out["requests"].append({"name": name, "status": status, **(extra or {})})

    for path in ("/healthz", "/readyz", "/healthz"):
        rec(f"catalog GET {path}", http("GET", CATALOG + path)[0])
    rec("catalog GET /products", http("GET", CATALOG + "/products?limit=5")[0])
    for _ in range(2):
        status, hdrs, _ = http("GET", CATALOG + "/products/SKU-0003")
        rec("catalog GET /products/SKU-0003", status, {"x_cache": hdrs.get("X-Cache") or hdrs.get("x-cache")})
    orders = []
    for i in range(2):
        key = f"dd-e2e-{uuid.uuid4().hex[:16]}"
        status, hdrs, body = http(
            "POST", ORDERS + "/orders", {"sku": f"SKU-000{i + 1}", "quantity": 2, "customer_ref": f"dd-e2e-{i}"}, {"Idempotency-Key": key}
        )
        rec("orders POST /orders", status, {"traceparent": hdrs.get("traceparent")})
        if isinstance(body, dict) and body.get("id"):
            orders.append(body["id"])
        if i == 0:
            rec(
                "orders POST /orders (idempotent replay)",
                http("POST", ORDERS + "/orders", {"sku": "SKU-0001", "quantity": 2, "customer_ref": "dd-e2e-0"}, {"Idempotency-Key": key})[0],
            )
    rec("orders GET /orders", http("GET", ORDERS + "/orders?limit=5")[0])
    rec("orders GET /healthz", http("GET", ORDERS + "/healthz")[0])
    out["orders"] = orders
    return out


def tap_records() -> list[dict]:
    return http("GET", TAP + "/_tap", timeout=20)[2]["records"]


def all_spans(records: list[dict]) -> list[dict]:
    spans = []
    for r in records:
        if r["path"] != "/api/v0.2/traces":
            continue
        for tp in (r.get("traces") or {}).get("tracer_payloads", []):
            for s in tp["spans"]:
                spans.append({**s, "language": tp.get("language"), "tracer_version": tp.get("tracer_version"), "payload_env": tp.get("env")})
    return spans


def intake_logs() -> list[dict]:
    events = http("GET", INTAKE + "/_received", timeout=20)[2]["events"]
    out = []
    for e in events:
        try:
            line = json.loads(e.get("message") or "")
        except ValueError:
            continue
        if isinstance(line, dict):
            out.append({"agent_service": e.get("service"), "ddsource": e.get("ddsource"), "ddtags": e.get("ddtags"), "line": line})
    return out


def ready(records: list[dict], logs: list[dict]) -> bool:
    spans = all_spans(records)
    langs = {s["language"] for s in spans}
    families = {((r.get("profile") or {}).get("event") or {}).get("family") for r in records if r["path"].startswith("/api/v2/profile")}
    series = {x for r in records if r["path"] in ("/api/v2/series", "/api/beta/sketches") for x in r.get("strings", [])}
    services = {lg["line"].get("service") for lg in logs if lg["line"].get("dd.trace_id")}
    return (
        {"python", ".NET"} <= langs
        and {"python", "dotnet"} <= families
        and {"hello.catalog.cache.requests", "hello.orders.created"} <= series
        and {"hello-catalog-api", "hello-orders-api"} <= services
    )


def evaluate(meta: dict, records: list[dict], logs: list[dict], container_logs: dict[str, str], journey_doc: dict) -> dict:
    res: dict = {}

    def put(cid: str, ok: bool | None, detail: object) -> None:
        res[cid] = {"check": dict(CHECKS)[cid], "result": "pass" if ok else ("skip" if ok is None else "fail"), "detail": detail}

    spans = all_spans(records)
    put(
        "dd-1",
        meta.get("agent_healthy") and meta.get("catalog_ready") and meta.get("orders_ready"),
        {k: meta.get(k) for k in ("agent_version", "agent_healthy", "catalog_ready", "orders_ready")},
    )

    py = [s for s in spans if s["language"] == "python" and s.get("service") == "hello-catalog-api"]
    net = [s for s in spans if s["language"] == ".NET" and (s.get("service") or "").startswith("hello-orders-api")]
    trace_posts = [r for r in records if r["path"] == "/api/v0.2/traces"]
    put(
        "dd-2",
        bool(py and net),
        {
            "trace_payloads": len(trace_posts),
            "python_spans": len(py),
            "dotnet_spans": len(net),
            "tracer_versions": sorted({f"{s['language']} {s['tracer_version']}" for s in spans}),
            "env": sorted({s["payload_env"] for s in spans if s.get("payload_env")}),
            "python_resources": sorted({str(s.get("resource")) for s in py})[:10],
            "dotnet_resources": sorted({str(s.get("resource")) for s in net})[:10],
        },
    )

    by_trace: dict[str, list[dict]] = {}
    for s in spans:
        by_trace.setdefault(s.get("trace_id_128") or str(s.get("trace_id")), []).append(s)
    distributed = []
    for tid, group in by_trace.items():
        server = [s for s in group if s["language"] == ".NET" and s.get("name") == "aspnet_core.request" and s.get("resource") == "POST /orders"]
        client = [s for s in group if s["language"] == ".NET" and s.get("name") == "http.request" and "catalog-api" in (s.get("resource") or "")]
        catalog = [s for s in group if s["language"] == "python" and s.get("meta", {}).get("span.kind") == "server"]
        if server and client and catalog:
            parented = any(c.get("parent_id") == cl.get("span_id") for c in catalog for cl in client)
            distributed.append(
                {
                    "trace_id": tid,
                    "catalog_parented_by_orders_client": parented,
                    "spans": [(s["language"], s.get("service"), s.get("name"), s.get("resource")) for s in group],
                }
            )
    # the traceparent response header of POST /orders names the Datadog trace (not ASP.NET Core's own Activity)
    tp_ids = [r["traceparent"].split("-")[1] for r in journey_doc.get("requests", []) if r.get("traceparent") and r["name"] == "orders POST /orders"]
    tp_match = bool(tp_ids) and all(t in by_trace for t in tp_ids)
    put(
        "dd-3",
        any(d["catalog_parented_by_orders_client"] for d in distributed) and tp_match,
        {"traces": distributed[:2], "count": len(distributed), "response_traceparent_trace_ids": tp_ids, "response_traceparent_is_datadog_trace": tp_match},
    )

    activity = [s for s in net if s.get("resource") == "send order-events" and s.get("meta", {}).get("otel.library.name") == "Hello.App"]
    same_trace = [a for a in activity if any(d["trace_id"] == (a.get("trace_id_128") or str(a.get("trace_id"))) for d in distributed)]
    put(
        "dd-4",
        bool(same_trace),
        {
            "activity_spans": len(activity),
            "in_distributed_trace": len(same_trace),
            "example": {k: activity[0].get(k) for k in ("name", "resource", "service")}
            | {"meta": {k: v for k, v in activity[0]["meta"].items() if k.startswith(("otel.", "messaging.", "span.kind"))}}
            if activity
            else None,
        },
    )

    probes = [s for s in py if any(p in ((s.get("resource") or "") + (s.get("meta", {}).get("http.url") or "")) for p in ("/healthz", "/readyz"))]
    put("dd-5", not probes and bool(py), {"python_probe_spans": len(probes), "probe_requests_sent": 3})

    trace_ids = {s.get("trace_id_128") for s in spans if s.get("trace_id_128")}
    low_ids = {str(s.get("trace_id")) for s in spans if s.get("trace_id") is not None}
    correlated: dict[str, int] = {}
    mismatched = []
    for lg in logs:
        line = lg["line"]
        if not line.get("dd.trace_id"):
            continue
        svc = line.get("service")
        if (
            line.get("trace_id") in trace_ids
            and line.get("dd.trace_id") in low_ids
            and int(line["trace_id"], 16) & 0xFFFFFFFFFFFFFFFF == int(line["dd.trace_id"])
        ):
            correlated[svc] = correlated.get(svc, 0) + 1
        else:
            mismatched.append({k: line.get(k) for k in ("service", "message", "trace_id", "dd.trace_id")})
    no_span_lines = [lg["line"] for lg in logs if "telemetry mode" in str(lg["line"].get("message"))]
    omitted = bool(no_span_lines) and all("trace_id" not in ln and "dd.trace_id" not in ln for ln in no_span_lines)
    agent_tagged = sorted({(str(lg["agent_service"]), str(lg["ddsource"])) for lg in logs})
    put(
        "dd-6",
        correlated.get("hello-catalog-api", 0) > 0 and correlated.get("hello-orders-api", 0) > 0 and omitted,
        {
            "correlated_lines": correlated,
            "lines_with_ids_not_matching_a_received_trace": len(mismatched),
            "examples_unmatched": mismatched[:3],
            "startup_lines_without_ids": omitted,
            "agent_service_source": agent_tagged,
        },
    )

    series_posts = [r for r in records if r["path"] in ("/api/v2/series", "/api/beta/sketches")]
    strings = sorted({x for r in series_posts for x in r.get("strings", [])})
    hello = sorted(x for x in strings if x.startswith("hello."))
    bad = [x for x in strings if any(k in x for k in ("order_id", "customer_ref", "user_id", "dd-e2e-"))]
    put(
        "dd-7",
        {"hello.catalog.cache.requests", "hello.orders.created"} <= set(hello) and "env:e2e-dd" in strings and not bad,
        {"hello_metrics": hello, "env_tags": [x for x in strings if x.startswith("env:")], "forbidden_tags": bad, "series_payloads": len(series_posts)},
    )

    profiles = [r for r in records if r["path"].startswith("/api/v2/profile")]
    fam: dict[str, dict] = {}
    for r in profiles:
        ev = (r.get("profile") or {}).get("event") or {}
        family = ev.get("family")
        if family:
            tags = ev.get("tags_profiler") or ""
            fam.setdefault(
                family,
                {
                    "uploads": 0,
                    "parts": sorted({p["name"] for p in r["profile"]["parts"]}),
                    "service_tag": next((t for t in tags.split(",") if t.startswith("service:")), None),
                    "attachments": ev.get("attachments"),
                },
            )
            fam[family]["uploads"] += 1
    mock_profiles = [o for o in http("GET", INTAKE + "/_received", timeout=20)[2]["others"] if o["path"].startswith("/api/v2/profile")]
    put("dd-8", "python" in fam and "dotnet" in fam and bool(mock_profiles), {"families": fam, "profile_posts_at_mock_intake": len(mock_profiles)})

    cat_log, ord_log = container_logs.get("catalog-api", ""), container_logs.get("orders-api", "")
    py_mode = next((json.loads(x[x.index("{") :]) for x in cat_log.splitlines() if "telemetry mode" in x and "{" in x), {})
    net_mode = next((json.loads(x[x.index("{") :]) for x in ord_log.splitlines() if "telemetry mode" in x and "{" in x), {})
    otlp_attempts = [x for x in (cat_log + ord_log).splitlines() if "otlp-must-not-be-used" in x or "Failed to export" in x]
    put(
        "dd-9",
        py_mode.get("apm.tracer") == "enabled"
        and py_mode.get("apm.profiler") == "enabled"
        and net_mode.get("otel_sdk") is False
        and net_mode.get("apm_tracer_attached") is True
        and not otlp_attempts,
        {
            "python": {k: py_mode.get(k) for k in ("message", "apm.tracer", "apm.tracer_source", "apm.profiler")},
            "dotnet": {k: net_mode.get(k) for k in ("message", "apm_tracer_attached", "apm_metrics", "otel_sdk")},
            "otlp_export_attempts": otlp_attempts[:3],
        },
    )

    posts = records
    keyless = [r["path"] for r in posts if not r.get("api_key_present") and not r["path"].startswith("/api/v2/profile")]
    profile_keyless = [r["path"] for r in profiles if not r.get("api_key_present")]
    agent_log = container_logs.get("datadog-agent", "")
    real_sends = [x for x in agent_log.splitlines() if "datadoghq.com" in x and ("Could not send payload" in x or "Successfully posted" in x)]
    put(
        "dd-10",
        not keyless and not profile_keyless and not real_sends,
        {
            "payloads": len(posts),
            "without_api_key": keyless + profile_keyless,
            "sends_to_real_datadog": real_sends[:3],
            "paths": sorted({r["path"] for r in posts}),
        },
    )
    return res


def write_evidence(meta: dict, results: dict, records: list[dict], logs: list[dict], journey_doc: dict, container_logs: dict[str, str]) -> Path:  # noqa: PLR0917
    ev = EVIDENCE_ROOT / f"{utc_stamp()}-datadog-agent"
    ev.mkdir(parents=True, exist_ok=True)
    passed = sum(1 for r in results.values() if r["result"] == "pass")
    summary = {"meta": meta, "passed": passed, "total": len(CHECKS), "results": results, "journey": journey_doc}
    (ev / "summary.json").write_text(json.dumps(summary, indent=2, default=str))
    (ev / "tap_records.json").write_text(json.dumps(records, indent=1, default=str))
    (ev / "agent_collected_logs.json").write_text(json.dumps(logs, indent=1, default=str))
    for name, text in container_logs.items():
        (ev / f"container-{name}.log").write_text(text[-400_000:])
    lines = [
        "# Local e2e evidence - Datadog Agent variant (LATEST)",
        "",
        f"- run: `{ev.relative_to(REPO)}` ({meta.get('started')} -> {meta.get('finished')})",
        "- status vocabulary (ADR-0001 §11): **locally-verified** (real Datadog Agent 7.84.2 + mock intake). Nothing was deployed and no data reached Datadog.",
        f"- result: **{passed}/{len(CHECKS)} checks passed**",
        f"- tracers: {', '.join(results.get('dd-2', {}).get('detail', {}).get('tracer_versions', []) or [])}; images: {meta.get('images')}",
        "- command: `python3 tests/integration/run_dd_agent_e2e.py`",
        "",
        "| check | result | what |",
        "|---|---|---|",
    ]
    for cid, what in CHECKS:
        r = results.get(cid, {"result": "not run"})
        lines.append(f"| {cid} | {r['result']} | {what} |")
    lines += [
        "",
        "Details: `summary.json` (per-check detail), `tap_records.json` (decoded Agent payloads), `agent_collected_logs.json`, `container-*.log`.",
        "",
    ]
    (EVIDENCE_ROOT / "LATEST-datadog-agent.md").write_text("\n".join(lines))
    return ev


def run(keep: bool = False, reuse: bool = False, rebuild: bool = False) -> dict:
    meta: dict = {"started": utc_iso()}
    results: dict = {}
    records: list[dict] = []
    logs: list[dict] = []
    journey_doc: dict = {}
    container_logs: dict[str, str] = {}
    try:
        if not reuse:
            build(rebuild)
            compose("down", "-v", "--remove-orphans", check=False)
            log("starting stack")
            compose("up", "-d")
        meta["agent_healthy"] = wait(lambda: sh("docker", "inspect", "-f", "{{.State.Health.Status}}", f"{PROJECT}-datadog-agent-1",
                                                check=False).stdout.strip() == "healthy", 180, 3)
        meta["agent_version"] = compose("exec", "-T", "datadog-agent", "agent", "version", "-n", check=False).strip()[-80:]
        meta["catalog_ready"] = wait_http(CATALOG + "/readyz", 120)
        meta["orders_ready"] = wait_http(ORDERS + "/readyz", 120)
        meta["images"] = {
            ref: sh("docker", "image", "inspect", "-f", "{{.Id}}", ref, check=False).stdout.strip()[:19]
            for ref in (f"hello-catalog-api:{VERSION}", DERIVED, "datadog/agent:7.84.2")
        }
        http("DELETE", TAP + "/_tap")
        http("DELETE", INTAKE + "/_received")
        log("journey")
        journey_doc = journey()
        log("waiting for traces, logs, metrics and profiles to flush through the Agent (<= 150 s)")
        if wait(lambda: ready(tap_records(), intake_logs()), 150, 5):
            time.sleep(5)
        records, logs = tap_records(), intake_logs()
        # start-up lines were emitted before the reset: re-read them from the container output for dd-6/dd-9
        for svc in ("catalog-api", "orders-api", "datadog-agent", "tap"):
            container_logs[svc] = compose("logs", "--no-color", "--no-log-prefix", svc, check=False)
        startup = [
            json.loads(x)
            for x in (container_logs["catalog-api"] + "\n" + container_logs["orders-api"]).splitlines()
            if x.startswith("{") and "telemetry mode" in x
        ]
        logs += [{"agent_service": None, "ddsource": "container-stdout", "ddtags": None, "line": s} for s in startup]
        results = evaluate(meta, records, logs, container_logs, journey_doc)
    except Exception as exc:  # report, then tear down
        meta["error"] = f"{type(exc).__name__}: {exc}"
        meta["traceback"] = traceback.format_exc()[-3000:]
        log(f"ERROR {meta['error']}")
    finally:
        meta["finished"] = utc_iso()
        ev = write_evidence(meta, results, records, logs, journey_doc, container_logs)
        if not keep:
            compose("down", "-v", "--remove-orphans", check=False)
    for cid, _ in CHECKS:
        r = results.get(cid)
        log(f"{cid:6} {r['result'] if r else 'not run':5} {dict(CHECKS)[cid]}")
    passed = sum(1 for r in results.values() if r["result"] == "pass")
    log(f"{passed}/{len(CHECKS)} passed; evidence {ev.relative_to(REPO)}; summary docs/evidence/local/LATEST-datadog-agent.md")
    return {"meta": meta, "results": results, "evidence_dir": str(ev)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keep", action="store_true", help="leave the stack running")
    ap.add_argument("--reuse", action="store_true", help="use a running stack (started with --keep)")
    ap.add_argument("--rebuild", action="store_true", help="rebuild catalog-api, orders-api and the tracer image first")
    a = ap.parse_args()
    out = run(keep=a.keep, reuse=a.reuse, rebuild=a.rebuild)
    ok = not out["meta"].get("error") and len(out["results"]) == len(CHECKS) and all(r["result"] == "pass" for r in out["results"].values())
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
