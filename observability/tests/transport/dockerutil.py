"""Tiny docker CLI helpers for the transport tests (no docker SDK dependency)."""

from __future__ import annotations

import json
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
PACKAGE = HERE.parent.parent  # observability/
FLB_CONFIG = PACKAGE / "config" / "fluent-bit"
OTEL_CONFIG = PACKAGE / "config" / "otel"

FLUENT_BIT_IMAGE = "fluent/fluent-bit:5.1.3"
OTELCOL_IMAGE = "otel/opentelemetry-collector-contrib:0.162.0"
PYTHON_IMAGE = "python:3.13-slim"
KAFKA_IMAGE = "apache/kafka:4.1.0"


def sh(*args: str, check: bool = True, input_text: str | None = None) -> str:
    res = subprocess.run(list(args), capture_output=True, text=True, input=input_text)
    if check and res.returncode != 0:
        raise RuntimeError(f"command failed ({res.returncode}): {' '.join(args)}\n{res.stdout}\n{res.stderr}")
    return res.stdout + res.stderr


class Stack:
    """A throw-away docker network plus containers, removed on close()."""

    def __init__(self, name: str) -> None:
        self.id = f"eh-{name}-{uuid.uuid4().hex[:6]}"
        self.containers: list[str] = []
        sh("docker", "network", "create", self.id)

    def run(self, name: str, image: str, *args: str, env: dict[str, str] | None = None,
            volumes: list[str] | None = None, ports: list[str] | None = None,
            entrypoint: str | None = None, cmd: list[str] | None = None, user: str | None = None) -> str:
        cname = f"{self.id}-{name}"
        argv = ["docker", "run", "-d", "--name", cname, "--network", self.id, "--network-alias", name]
        for k, v in (env or {}).items():
            argv += ["-e", f"{k}={v}"]
        for v in volumes or []:
            argv += ["-v", v]
        for p in ports or []:
            argv += ["-p", p]
        if entrypoint is not None:
            argv += ["--entrypoint", entrypoint]
        if user is not None:
            argv += ["--user", user]
        argv += list(args)
        argv.append(image)
        argv += cmd or []
        sh(*argv)
        self.containers.append(cname)
        return cname

    def host_port(self, cname: str, port: int) -> int:
        out = sh("docker", "port", cname, str(port)).strip().splitlines()[0]
        return int(out.rsplit(":", 1)[1])

    def logs(self, cname: str) -> str:
        return sh("docker", "logs", cname, check=False)

    def close(self) -> None:
        for c in self.containers:
            sh("docker", "rm", "-f", "-v", c, check=False)
        sh("docker", "network", "rm", self.id, check=False)


def http_json(url: str, method: str = "GET", timeout: float = 5.0):
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - local test endpoint
        return json.loads(r.read() or b"null")


def http_status(url: str, timeout: float = 5.0) -> int:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:  # noqa: S310 - local test endpoint
            return r.status
    except urllib.error.HTTPError as exc:
        return exc.code


def wait_for(predicate, timeout: float = 60.0, interval: float = 1.0, what: str = "condition"):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            last = predicate()
            if last:
                return last
        except Exception as exc:  # noqa: BLE001 - retried until timeout
            last = exc
        time.sleep(interval)
    raise TimeoutError(f"timed out waiting for {what}; last={last!r}")


def start_mock_intake(stack: Stack, name: str = "intake") -> tuple[str, str]:
    cname = stack.run(
        name, PYTHON_IMAGE,
        volumes=[f"{HERE / 'mock_intake'}:/mock:ro"],
        ports=["127.0.0.1::8080"],
        cmd=["python", "-u", "/mock/mock_intake.py"],
    )
    base = f"http://127.0.0.1:{stack.host_port(cname, 8080)}"
    wait_for(lambda: http_json(f"{base}/healthz")["ok"], 60, what="mock intake")
    return cname, base


def received(base: str) -> dict:
    return http_json(f"{base}/_received")


def fluent_bit_env(**overrides: str) -> dict[str, str]:
    env = {
        "FLB_STATE_DIR": "/tmp/flb",
        "FLB_DD_HOST": "intake",
        "FLB_DD_PORT": "8080",
        "FLB_DD_TLS": "off",  # mock intake speaks plain HTTP; every real deployment sets on
        "DD_API_KEY": "test-not-a-real-key",
        "FLB_DD_SOURCE": "csharp",
        "FLB_DD_SERVICE": "hello-orders-api",
        "FLB_DD_TAGS": "env:test,team:observability,application:enterprise-hello",
        "FLB_FORWARD_TLS": "off",
        "FLB_FORWARD_TLS_VERIFY": "off",
        "FLB_FORWARD_TLS_CRT": "",
        "FLB_FORWARD_TLS_KEY": "",
        "FLB_FORWARD_SHARED_KEY": "test-shared-key",
    }
    env.update(overrides)
    return env
