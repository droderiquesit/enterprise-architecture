"""Helpers shared by the local e2e runners (run_e2e.py, run_dd_agent_e2e.py)."""

from __future__ import annotations

import datetime as dt
import json
import subprocess
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from pathlib import Path
from typing import Any


def logger(tag: str) -> Callable[[str], None]:
    def log(msg: str) -> None:
        print(f"[{tag} {dt.datetime.now(dt.UTC).strftime('%H:%M:%S')}] {msg}", flush=True)

    return log


def utc_iso() -> str:
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds")


def utc_stamp() -> str:
    return dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")


def sh(*args: str, check: bool = True, capture: bool = True, env: dict | None = None, cwd: Path | None = None,
       timeout: float | None = None) -> subprocess.CompletedProcess:
    res = subprocess.run(list(args), capture_output=capture, text=True, env=env, cwd=cwd, timeout=timeout, check=False)  # noqa: S603
    if check and res.returncode != 0:
        raise RuntimeError(f"command failed ({res.returncode}): {' '.join(args)}\n{(res.stdout or '')[-3000:]}\n{(res.stderr or '')[-3000:]}")
    return res


def _json_or_text(raw: bytes) -> Any:
    try:
        return json.loads(raw or b"null")
    except ValueError:
        return raw.decode(errors="replace")


def http(method: str, url: str, body: Any = None, headers: dict | None = None, timeout: float = 15.0) -> tuple[int, dict, Any]:
    """(status, headers, parsed JSON body or text); HTTP errors are returned, not raised."""
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        hdrs.setdefault("content-type", "application/json")
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)  # noqa: S310 - local test endpoints only
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310
            return r.status, dict(r.headers), _json_or_text(r.read())
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), _json_or_text(exc.read())


def poll(fn: Callable[[], Any], timeout: float, interval: float = 2.0, what: str = "condition") -> Any:
    """First truthy fn() result; exceptions count as not ready. TimeoutError after `timeout` seconds."""
    deadline = time.time() + timeout
    last: Any = None
    while time.time() < deadline:
        try:
            last = fn()
            if last:
                return last
        except Exception as exc:
            last = exc
        time.sleep(interval)
    raise TimeoutError(f"timed out after {timeout:.0f}s waiting for {what}; last={str(last)[:500]}")


def image_exists(ref: str) -> bool:
    return sh("docker", "image", "inspect", ref, check=False).returncode == 0
