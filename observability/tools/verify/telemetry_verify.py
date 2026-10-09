#!/usr/bin/env python3
"""Verify that one user journey produced complete, correlated, de-duplicated telemetry in Datadog.

Checks (each polled with bounded exponential backoff until it passes or --max-wait expires):
  rum_resource_trace   RUM resource event of the frontend carrying _dd.trace_id (browser -> backend correlation)
  apm_journey          the journey trace contains spans of every --journey-service plus a database span
  logs_pipeline        logs of the journey services arrived through the log pipeline (--pipeline-tag)
  logs_trace_corr      at least one pipeline log is correlated to the journey trace (trace_id / dd.trace_id)
  logs_no_duplicates   the unique marker log line exists exactly --expected-marker-count times (no double shipping)
  required_tags        journey spans and logs carry the required unified tags (--required-tag)
  infra_metrics        every --infra-metric has at least one non-null point in the window

APIs (all read-only): POST /api/v2/rum/events/search, POST /api/v2/spans/events/search (300 req/h),
POST /api/v2/logs/events/search, GET /api/v1/query. Auth: DD-API-KEY + DD-APPLICATION-KEY from the
environment (DD_API_KEY / DD_APP_KEY); keys are never printed or written to the evidence file.

Exit codes: 0 all selected checks passed; 1 at least one check failed; 2 usage/configuration error;
3 Datadog API authentication/authorization error.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable, Protocol

TOOL_VERSION = "1.0.0"
ALL_CHECKS = ["rum_resource_trace", "apm_journey", "logs_pipeline", "logs_trace_corr", "logs_no_duplicates",
              "required_tags", "infra_metrics"]


class AuthError(Exception):
    pass


class Transport(Protocol):
    def __call__(self, method: str, path: str, body: dict | None, query: dict | None) -> dict: ...


def http_transport(site: str, api_key: str, app_key: str, timeout: float = 30.0) -> Transport:
    base = f"https://api.{site}"

    def call(method: str, path: str, body: dict | None, query: dict | None) -> dict:
        url = base + path + ("?" + urllib.parse.urlencode(query) if query else "")
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "DD-API-KEY": api_key, "DD-APPLICATION-KEY": app_key,
            "Content-Type": "application/json", "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (https only)
                return json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                raise AuthError(f"{method} {path}: HTTP {exc.code}") from None
            if exc.code == 429:
                return {"_rate_limited": True}
            raise RuntimeError(f"{method} {path}: HTTP {exc.code}") from None

    return call


# --------------------------------------------------------------------------- id helpers
def hex_to_dd_decimal(trace_id_hex: str) -> str:
    """Datadog's dd.trace_id log attribute is the decimal of the LOW 64 bits of the W3C 128-bit trace id."""
    return str(int(trace_id_hex[-16:], 16))


def normalize_trace_id(value: str) -> tuple[str | None, str]:
    """Return (hex32 or None, decimal low-64) for a hex or decimal trace id."""
    value = str(value).strip().lower()
    if len(value) in (16, 32) and all(c in "0123456789abcdef" for c in value) and not value.isdigit():
        return (value.rjust(32, "0"), hex_to_dd_decimal(value))
    if value.isdigit():
        return (None, value if int(value) < 2**64 else str(int(value) & (2**64 - 1)))
    if len(value) == 32 and all(c in "0123456789abcdef" for c in value):
        return (value, hex_to_dd_decimal(value))
    raise ValueError(f"not a trace id: {value}")


def same_trace(a: str, b: str) -> bool:
    try:
        return normalize_trace_id(a)[1] == normalize_trace_id(b)[1]
    except ValueError:
        return False


def tags_of(obj: dict) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for t in obj.get("tags", []) or []:
        k, _, v = str(t).partition(":")
        out.setdefault(k, set()).add(v)
    for k in ("service", "env", "version"):
        if obj.get(k):
            out.setdefault(k, set()).add(str(obj[k]))
    return out


# --------------------------------------------------------------------------- results
@dataclass
class CheckResult:
    name: str
    status: str = "fail"  # pass | fail | skipped
    attempts: int = 0
    details: str = ""
    evidence: dict = field(default_factory=dict)


@dataclass
class Config:
    env: str
    frontend_service: str | None
    journey_services: list[str]
    pipeline_tag: str
    marker: str | None
    marker_query: str
    expected_marker_count: int
    required_tags: list[str]
    infra_metrics: list[str]
    window_minutes: int
    max_wait: float
    initial_interval: float
    max_interval: float
    rum_query: str | None
    entry_span_query: str | None
    checks: list[str]


class Verifier:
    def __init__(self, cfg: Config, transport: Transport, clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], None] = time.sleep, now: Callable[[], float] = time.time):
        self.cfg, self.t, self.clock, self.sleep, self.now = cfg, transport, clock, sleep, now
        self.state: dict[str, Any] = {"trace_id": None, "spans": [], "logs": []}

    # ------------------------------------------------------------ API wrappers
    def _window(self) -> tuple[str, str]:
        return f"now-{self.cfg.window_minutes}m", "now"

    def search_rum(self, query: str, limit: int = 50) -> list[dict]:
        frm, to = self._window()
        r = self.t("POST", "/api/v2/rum/events/search",
                   {"filter": {"query": query, "from": frm, "to": to}, "page": {"limit": limit}, "sort": "-timestamp"}, None)
        return r.get("data", []) or []

    def search_spans(self, query: str, limit: int = 100) -> list[dict]:
        frm, to = self._window()
        r = self.t("POST", "/api/v2/spans/events/search", {"data": {"type": "search_request", "attributes": {
            "filter": {"query": query, "from": frm, "to": to}, "page": {"limit": limit}, "sort": "-timestamp"}}}, None)
        return r.get("data", []) or []

    def search_logs(self, query: str, limit: int = 100) -> list[dict]:
        frm, to = self._window()
        r = self.t("POST", "/api/v2/logs/events/search",
                   {"filter": {"query": query, "from": frm, "to": to}, "page": {"limit": limit}, "sort": "-timestamp"}, None)
        return r.get("data", []) or []

    def query_metric(self, query: str) -> list[dict]:
        to = int(self.now())
        frm = to - self.cfg.window_minutes * 60
        r = self.t("GET", "/api/v1/query", None, {"from": frm, "to": to, "query": query})
        return r.get("series", []) or []

    # ------------------------------------------------------------ polling
    def poll(self, name: str, fn: Callable[[CheckResult], bool]) -> CheckResult:
        res = CheckResult(name)
        deadline = self.clock() + self.cfg.max_wait
        interval = self.cfg.initial_interval
        while True:
            res.attempts += 1
            try:
                if fn(res):
                    res.status = "pass"
                    return res
            except AuthError:
                raise
            except TerminalFailure as exc:  # waiting cannot fix it: fail now, keep the evidence
                res.status = "fail"
                res.details = str(exc)
                return res
            except Exception as exc:  # transient API/parse errors are retried until the deadline
                res.details = f"error: {exc}"
            if self.clock() + interval > deadline:
                res.status = "fail"
                return res
            self.sleep(interval)
            interval = min(interval * 2, self.cfg.max_interval)

    # ------------------------------------------------------------ checks
    def _svc_query(self) -> str:
        return "service:(" + " OR ".join(self.cfg.journey_services) + ")"

    def check_rum(self, res: CheckResult) -> bool:
        q = self.cfg.rum_query or f"@type:resource service:{self.cfg.frontend_service} env:{self.cfg.env}"
        events = self.search_rum(q)
        for ev in events:
            attrs = (ev.get("attributes") or {}).get("attributes") or {}
            tid = (attrs.get("_dd") or {}).get("trace_id") or attrs.get("_dd.trace_id")
            if tid:
                self.state["trace_id"] = str(tid)
                res.evidence = {"rum_event_id": ev.get("id"), "trace_id": str(tid), "resource_url": (attrs.get("resource") or {}).get("url")}
                res.details = "RUM resource event correlated to a backend trace"
                return True
        res.details = f"{len(events)} RUM resource events, none with _dd.trace_id"
        return False

    def _ensure_trace(self) -> str | None:
        if self.state["trace_id"]:
            return self.state["trace_id"]
        q = self.cfg.entry_span_query or f"service:{self.cfg.journey_services[0]} env:{self.cfg.env}"
        spans = self.search_spans(q, limit=10)
        if spans:
            self.state["trace_id"] = str((spans[0].get("attributes") or {}).get("trace_id"))
        return self.state["trace_id"]

    def check_apm(self, res: CheckResult) -> bool:
        tid = self._ensure_trace()
        if not tid:
            res.details = "no journey trace found yet"
            return False
        spans = self.search_spans(f"trace_id:{tid} env:{self.cfg.env}", limit=200)
        self.state["spans"] = spans
        services = {(s.get("attributes") or {}).get("service") for s in spans}
        db_spans = [s for s in spans if _is_db_span(s)]
        missing = [svc for svc in self.cfg.journey_services if svc not in services]
        res.evidence = {"trace_id": tid, "span_count": len(spans), "services": sorted(x for x in services if x),
                        "db_span_count": len(db_spans)}
        if missing or not db_spans:
            res.details = f"missing services {missing}" + ("" if db_spans else "; no database span")
            return False
        res.details = "journey trace spans all services and a database call"
        return True

    def check_logs_pipeline(self, res: CheckResult) -> bool:
        logs = self.search_logs(f"{self._svc_query()} env:{self.cfg.env} {self.cfg.pipeline_tag}")
        self.state["logs"] = logs
        seen = {(lg.get("attributes") or {}).get("service") for lg in logs}
        missing = [s for s in self.cfg.journey_services if s not in seen]
        res.evidence = {"log_count": len(logs), "services": sorted(x for x in seen if x), "pipeline_tag": self.cfg.pipeline_tag}
        if missing:
            res.details = f"no pipeline logs yet for {missing}"
            return False
        res.details = "logs of every journey service arrived via the pipeline"
        return True

    def check_logs_corr(self, res: CheckResult) -> bool:
        tid = self._ensure_trace()
        if not tid:
            res.details = "no journey trace to correlate"
            return False
        hex_id, dec = normalize_trace_id(tid)
        parts = [f"@dd.trace_id:{dec}"] + ([f"@trace_id:{hex_id}"] if hex_id else [])
        logs = self.search_logs(f"env:{self.cfg.env} {self.cfg.pipeline_tag} (" + " OR ".join(parts) + ")")
        matched = []
        for lg in logs:
            a = (lg.get("attributes") or {}).get("attributes") or {}
            cand = a.get("dd", {}).get("trace_id") if isinstance(a.get("dd"), dict) else a.get("dd.trace_id")
            cand = cand or a.get("trace_id")
            if cand and same_trace(str(cand), tid):
                matched.append(lg.get("id"))
        res.evidence = {"trace_id": tid, "correlated_log_ids": matched[:10]}
        if not matched:
            res.details = "no pipeline log carries the journey trace id"
            return False
        res.details = f"{len(matched)} logs correlated to the journey trace"
        return True

    def check_duplicates(self, res: CheckResult) -> bool:
        if not self.cfg.marker:
            res.status = "skipped"
            res.details = "no --marker given"
            return True
        q = self.cfg.marker_query.format(marker=self.cfg.marker, env=self.cfg.env)
        logs = self.search_logs(q, limit=10)
        res.evidence = {"query": q, "count": len(logs), "expected": self.cfg.expected_marker_count}
        if len(logs) > self.cfg.expected_marker_count:
            res.details = f"DUPLICATES: marker seen {len(logs)} times (expected {self.cfg.expected_marker_count})"
            # duplicates never resolve by waiting: stop polling by raising a terminal condition
            raise TerminalFailure(res.details)
        if len(logs) < self.cfg.expected_marker_count:
            res.details = f"marker seen {len(logs)} times so far"
            return False
        res.details = "marker log line delivered exactly once"
        return True

    def check_tags(self, res: CheckResult) -> bool:
        if not self.state["spans"]:
            self.check_apm(CheckResult("apm_journey"))
        if not self.state["logs"]:
            self.check_logs_pipeline(CheckResult("logs_pipeline"))
        problems = []
        for kind, items in (("span", self.state["spans"]), ("log", self.state["logs"])):
            for it in items:
                a = it.get("attributes") or {}
                if kind == "span" and a.get("service") not in self.cfg.journey_services:
                    continue
                present = tags_of(a)
                missing = [t for t in self.cfg.required_tags if t not in present]
                if missing:
                    problems.append({"kind": kind, "id": it.get("id"), "service": a.get("service"), "missing": missing})
        checked = len(self.state["spans"]) + len(self.state["logs"])
        res.evidence = {"checked": checked, "violations": problems[:20], "required": self.cfg.required_tags}
        if checked == 0:
            res.details = "nothing to check yet"
            return False
        if problems:
            res.details = f"{len(problems)} items miss required tags"
            raise TerminalFailure(res.details)
        res.details = f"{checked} spans/logs carry {self.cfg.required_tags}"
        return True

    def check_infra(self, res: CheckResult) -> bool:
        missing = []
        found = {}
        for metric in self.cfg.infra_metrics:
            q = metric if "{" in metric else f"avg:{metric}{{*}}"
            series = self.query_metric(q)
            points = [p for s in series for p in (s.get("pointlist") or []) if len(p) > 1 and p[1] is not None]
            if points:
                found[metric] = len(points)
            else:
                missing.append(metric)
        res.evidence = {"found": found, "missing": missing}
        if missing:
            res.details = f"no datapoints yet for {missing}"
            return False
        res.details = "all infrastructure metrics present"
        return True

    def run(self) -> list[CheckResult]:
        plan = {
            "rum_resource_trace": self.check_rum, "apm_journey": self.check_apm,
            "logs_pipeline": self.check_logs_pipeline, "logs_trace_corr": self.check_logs_corr,
            "logs_no_duplicates": self.check_duplicates, "required_tags": self.check_tags,
            "infra_metrics": self.check_infra,
        }
        results = []
        for name in ALL_CHECKS:
            if name not in self.cfg.checks:
                results.append(CheckResult(name, status="skipped", details="not selected"))
                continue
            if name == "rum_resource_trace" and not self.cfg.frontend_service:
                results.append(CheckResult(name, status="skipped", details="no --frontend-service"))
                continue
            if name == "infra_metrics" and not self.cfg.infra_metrics:
                results.append(CheckResult(name, status="skipped", details="no --infra-metric"))
                continue
            try:
                r = self.poll(name, plan[name])
            except TerminalFailure as exc:
                r = CheckResult(name, status="fail", attempts=1, details=str(exc))
            if name == "logs_no_duplicates" and not self.cfg.marker:
                r.status = "skipped"
            results.append(r)
        return results


class TerminalFailure(Exception):
    """A failure that waiting cannot fix (duplicates, missing tags)."""


def _is_db_span(span: dict) -> bool:
    a = span.get("attributes") or {}
    inner = a.get("attributes") or {}
    custom = a.get("custom") or {}
    return (a.get("type") in ("sql", "db", "redis", "cassandra", "mongodb", "elasticsearch")
            or "db.system" in inner or "db.system" in custom
            or (isinstance(custom.get("db"), dict) and "system" in custom["db"]))


# --------------------------------------------------------------------------- CLI
def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--site", default=os.environ.get("DD_SITE", "datadoghq.com"))
    ap.add_argument("--env", required=True)
    ap.add_argument("--frontend-service")
    ap.add_argument("--journey-service", action="append", required=True, help="entry service first; repeatable")
    ap.add_argument("--pipeline-tag", default="telemetry.pipeline:fluent-bit",
                    help="tag the log pipeline adds to every record (Fluent Bit config)")
    ap.add_argument("--marker", help="unique marker emitted once by the traffic generator")
    ap.add_argument("--marker-query", default='env:{env} "{marker}"')
    ap.add_argument("--expected-marker-count", type=int, default=1)
    ap.add_argument("--required-tag", action="append", default=None, help="default: env, service, version")
    ap.add_argument("--infra-metric", action="append", default=[], help="metric or full query; repeatable")
    ap.add_argument("--window-minutes", type=int, default=30)
    ap.add_argument("--max-wait", type=float, default=600, help="seconds per check (bounded polling)")
    ap.add_argument("--initial-interval", type=float, default=10)
    ap.add_argument("--max-interval", type=float, default=60)
    ap.add_argument("--rum-query")
    ap.add_argument("--entry-span-query")
    ap.add_argument("--checks", default=",".join(ALL_CHECKS))
    ap.add_argument("--evidence", default="telemetry-evidence.json")
    return ap


def main(argv: list[str] | None = None, transport: Transport | None = None,
         sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> int:
    args = build_parser().parse_args(argv)
    checks = [c.strip() for c in args.checks.split(",") if c.strip()]
    unknown = [c for c in checks if c not in ALL_CHECKS]
    if unknown:
        print(f"ERROR: unknown checks {unknown}", file=sys.stderr)
        return 2
    if args.max_wait <= 0 or args.max_wait > 3600:
        print("ERROR: --max-wait must be in (0, 3600]", file=sys.stderr)
        return 2
    if transport is None:
        api_key, app_key = os.environ.get("DD_API_KEY"), os.environ.get("DD_APP_KEY")
        if not api_key or not app_key:
            print("ERROR: DD_API_KEY and DD_APP_KEY must be set (read-only app key is sufficient)", file=sys.stderr)
            return 2
        transport = http_transport(args.site, api_key, app_key)
    cfg = Config(env=args.env, frontend_service=args.frontend_service, journey_services=args.journey_service,
                 pipeline_tag=args.pipeline_tag, marker=args.marker, marker_query=args.marker_query,
                 expected_marker_count=args.expected_marker_count,
                 required_tags=args.required_tag or ["env", "service", "version"],
                 infra_metrics=args.infra_metric, window_minutes=args.window_minutes, max_wait=args.max_wait,
                 initial_interval=args.initial_interval, max_interval=args.max_interval, rum_query=args.rum_query,
                 entry_span_query=args.entry_span_query, checks=checks)
    started = datetime.now(timezone.utc).isoformat()
    try:
        results = Verifier(cfg, transport, clock=clock, sleep=sleep).run()
    except AuthError as exc:
        print(f"ERROR: Datadog API rejected the credentials: {exc}", file=sys.stderr)
        return 3
    failed = [r for r in results if r.status == "fail"]
    evidence = {
        "tool": "observability/tools/verify/telemetry_verify.py", "tool_version": TOOL_VERSION,
        "started_at": started, "finished_at": datetime.now(timezone.utc).isoformat(),
        "site": args.site, "env": args.env,
        "inputs": {k: v for k, v in vars(args).items() if k not in ("evidence",)},
        "result": "fail" if failed else "pass",
        "checks": [r.__dict__ for r in results],
    }
    with open(args.evidence, "w", encoding="utf-8") as fh:
        json.dump(evidence, fh, indent=2, sort_keys=True)
    for r in results:
        print(f"[{r.status.upper():7}] {r.name:20} attempts={r.attempts} {r.details}")
    print(f"evidence -> {args.evidence}; result: {evidence['result']}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
