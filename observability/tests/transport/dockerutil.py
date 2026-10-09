"""Tiny docker CLI helpers for the transport tests (no docker SDK dependency)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
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
REPO = PACKAGE.parent
DSV_FETCH_SRC = PACKAGE / "images" / "dsv-fetch"
DSV_FETCH_IMAGE = os.environ.get("DSV_FETCH_IMAGE", "dsv-fetch:dev")
# secret values the tests expect to arrive at the mock intake; delivered through DSV (mock) + dsv-fetch only
TEST_SECRETS = {"DD_API_KEY": "test-not-a-real-key", "FLB_FORWARD_SHARED_KEY": "test-shared-key"}
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


def ensure_dsv_fetch_image() -> str:
    """The real dsv-fetch image (observability/images/dsv-fetch); built locally when missing."""
    if subprocess.run(["docker", "image", "inspect", DSV_FETCH_IMAGE], capture_output=True).returncode != 0:
        sh("docker", "build", "-q", "-t", DSV_FETCH_IMAGE, str(DSV_FETCH_SRC))
    return DSV_FETCH_IMAGE


def dsv_ref(name: str) -> str:
    return f"dsv://eh/test/{name.lower().replace('_', '-')}#value"


def dsv_fetch_init(out_dir: Path, values: dict[str, str], fmt: str = "env-yaml", extra: list[str] | None = None) -> Path:
    """Exactly what the init containers do: store `values` in a mock DSV (tools/secrets/mock_dsv.py), then run the
    dsv-fetch IMAGE `init --format <fmt>` with one --map NAME=dsv://... per value into out_dir (mounted as
    /dsv-secrets). Auth: DSV_AUTH=client_credentials (the managed-identity flows are unit-tested by dsv-fetch)."""
    if str(REPO) not in sys.path:
        sys.path.insert(0, str(REPO))
    from tools.secrets.mock_dsv import serve  # repository test tool (not shipped in the package)

    cfg = {
        "clients": {"transport-tests": {"secret": "transport-tests-secret", "identity": "obs-collector-test"}},
        "users": {"obs-collector-test": {"read": ["eh/test/*"]}},
        "secrets": {dsv_ref(n).split("://", 1)[1].split("#")[0]: {"value": v} for n, v in values.items()},
    }
    srv, state = serve(cfg)
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
        out_dir.chmod(0o777)  # the image runs as 65532
        argv = ["docker", "run", "--rm", "--network", "host", "--read-only", "-v", f"{out_dir}:/dsv-secrets",
                "-e", "DSV_AUTH=client_credentials", "-e", "DSV_CLIENT_ID=transport-tests",
                "-e", "DSV_CLIENT_SECRET=transport-tests-secret",
                "-e", f"DSV_BASE_URL=http://127.0.0.1:{srv.server_address[1]}/v1",
                ensure_dsv_fetch_image(), "init", "--out", "/dsv-secrets", "--format", fmt, *(extra or [])]
        for n in values:
            argv += ["--map", f"{n}={dsv_ref(n)}"]
        sh(*argv)
    finally:
        srv.shutdown()
    return out_dir


def fluent_bit_secrets(tmp: Path, **values: str) -> str:
    """docker -v spec of a /dsv-secrets dir holding fluentbit-env.yaml written by dsv-fetch from the mock DSV."""
    d = dsv_fetch_init(tmp / f"dsv-{len(list(tmp.glob('dsv-*')))}", {**TEST_SECRETS, **values})
    assert (d / "fluentbit-env.yaml").exists()
    return f"{d}:/dsv-secrets:ro"


def fluent_bit_env(**overrides: str) -> dict[str, str]:
    """Non-secret Fluent Bit env (secrets come from the dsv-fetch env file, see fluent_bit_secrets)."""
    env = {
        "FLB_STATE_DIR": "/tmp/flb",
        "FLB_DD_HOST": "intake",
        "FLB_DD_PORT": "8080",
        "FLB_DD_TLS": "off",  # mock intake speaks plain HTTP; every real deployment sets on
        "FLB_DD_SOURCE": "csharp",
        "FLB_DD_SERVICE": "hello-orders-api",
        "FLB_DD_TAGS": "env:test,team:observability,application:enterprise-hello",
        "FLB_FORWARD_TLS": "off",
        "FLB_FORWARD_TLS_VERIFY": "off",
        "FLB_FORWARD_TLS_CRT": "",
        "FLB_FORWARD_TLS_KEY": "",
        "FLB_CANARY_INTERVAL_SEC": "2",  # 60 in deployments
    }
    env.update(overrides)
    return env
