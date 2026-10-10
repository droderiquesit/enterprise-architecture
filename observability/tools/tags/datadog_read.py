"""Read-only Datadog API client for the tag tools (never writes to Datadog).

Allowed calls: GET on any path, POST only on the documented *search / query* endpoints that read data. Anything else
raises ReadOnlyViolation before a request is made. Keys come from the environment (DD_API_KEY / DD_APP_KEY; in pipelines
exported by tools/secrets/fetch.py from Delinea DSV, never written to disk). Offline mode serves recorded responses
from a fixtures directory (tests, demos): <dir>/<name>.json keyed by FIXTURE_NAMES.
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

READ_ONLY_POST = ("/api/v2/logs/events/search", "/api/v2/spans/events/search", "/api/v2/rum/events/search",
                  "/api/v2/logs/analytics/aggregate", "/api/v2/spans/analytics/aggregate", "/api/v2/query/scalar",
                  "/api/v2/query/timeseries")
FIXTURE_NAMES = {
    "/api/v1/monitor": "monitors",
    "/api/v1/slo": "slos",
    "/api/v1/hosts": "hosts",
    "/api/v2/logs/events/search": "logs_search",
    "/api/v2/spans/events/search": "spans_search",
}


class ReadOnlyViolation(RuntimeError):
    """A call that could modify Datadog was attempted."""


class ApiError(RuntimeError):
    pass


class DatadogReader:
    def __init__(self, site: str = "datadoghq.com", *, api_key: str | None = None, app_key: str | None = None,
                 fixtures: Path | None = None, timeout: float = 30.0, retries: int = 3) -> None:
        self.base = f"https://api.{site}"
        self.api_key = api_key if api_key is not None else os.environ.get("DD_API_KEY")
        self.app_key = app_key if app_key is not None else os.environ.get("DD_APP_KEY")
        self.fixtures = Path(fixtures) if fixtures else None
        self.timeout = timeout
        self.retries = retries
        self.calls: list[tuple[str, str]] = []
        if not self.fixtures and (not self.api_key or not self.app_key):
            raise ApiError("DD_API_KEY and DD_APP_KEY must be set (a read-only application key is sufficient)")

    def request(self, method: str, path: str, query: dict | None = None, body: dict | None = None) -> Any:
        method = method.upper()
        if method != "GET" and not (method == "POST" and path in READ_ONLY_POST):
            raise ReadOnlyViolation(f"{method} {path} is not a read-only call")
        self.calls.append((method, path))
        if self.fixtures is not None:
            return self._fixture(path, query, body)
        url = self.base + path + ("?" + urllib.parse.urlencode(query, doseq=True) if query else "")
        data = json.dumps(body).encode() if body is not None else None
        headers = {"DD-API-KEY": self.api_key, "DD-APPLICATION-KEY": self.app_key, "Accept": "application/json"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        delay = 2.0
        for attempt in range(self.retries + 1):
            req = urllib.request.Request(url, data=data, method=method, headers=headers)  # noqa: S310 - https Datadog API URL
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:  # noqa: S310 - https Datadog API URL
                    return json.loads(resp.read() or b"null")
            except urllib.error.HTTPError as exc:
                if exc.code in (429, 500, 502, 503, 504) and attempt < self.retries:
                    time.sleep(delay)
                    delay *= 2
                    continue
                raise ApiError(f"{method} {path}: HTTP {exc.code}") from None
            except urllib.error.URLError as exc:
                if attempt < self.retries:
                    time.sleep(delay)
                    delay *= 2
                    continue
                raise ApiError(f"{method} {path}: {exc.reason}") from None
        raise ApiError(f"{method} {path}: retries exhausted")

    def _fixture(self, path: str, query: dict | None, body: dict | None) -> Any:
        name = FIXTURE_NAMES.get(path)
        if name is None:
            raise ApiError(f"no fixture for {path}")
        f = self.fixtures / f"{name}.json"
        if not f.exists():
            return [] if name == "monitors" else {"data": []}
        doc = json.loads(f.read_text(encoding="utf-8"))
        # paged fixtures: {"pages": [page0, page1, ...]} selected by query page / offset
        if isinstance(doc, dict) and "pages" in doc:
            q = query or {}
            idx = int(q.get("page", 0)) if name == "monitors" else int(q.get("offset", 0)) // max(int(q.get("limit", 1000)), 1)
            pages = doc["pages"]
            return pages[idx] if idx < len(pages) else ([] if name == "monitors" else {"data": []})
        # search fixtures keyed by the query string ({"by_query": {"<query>": response}, "default": response})
        if isinstance(doc, dict) and "by_query" in doc:
            b = body or {}
            f = b.get("filter") or ((b.get("data") or {}).get("attributes") or {}).get("filter") or {}
            q = f.get("query") or (query or {}).get("filter", "")
            return doc["by_query"].get(q, doc.get("default", {"data": []}))
        return doc

    # ------------------------------------------------------------------ paged readers
    def monitors(self, page_size: int = 1000) -> list[dict]:
        out: list[dict] = []
        page = 0
        while True:
            batch = self.request("GET", "/api/v1/monitor", {"page": page, "page_size": page_size, "with_downtimes": "false"})
            if not batch:
                return out
            out.extend(batch)
            if len(batch) < page_size:
                return out
            page += 1

    def slos(self, limit: int = 1000) -> list[dict]:
        out: list[dict] = []
        offset = 0
        while True:
            doc = self.request("GET", "/api/v1/slo", {"limit": limit, "offset": offset})
            batch = (doc or {}).get("data") or []
            out.extend(batch)
            if len(batch) < limit:
                return out
            offset += limit
