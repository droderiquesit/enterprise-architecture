"""Fixtures: tools/secrets/mock_dsv.py (DSV API) + a fake Azure identity server (IMDS, IDENTITY_ENDPOINT, Entra token).

Black-box conformance suite of the static Go binary (2.x). It was written against the 1.x Python dsv_fetch.py and
proved the Go port identical (CLI, messages, exit codes, output bytes); 1.x was retired in package 4.0.0, so the suite
runs the binary only (test id suffix [go]):
  $DSV_FETCH_BIN when set (e.g. a release file), else built once per session with ../build.sh --toolchain local
  (skipped when neither a binary nor Go is available).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
IMAGE_DIR = HERE.parent
REPO = HERE.parents[3]
sys.path.insert(0, str(REPO / "tools" / "secrets"))
sys.path.insert(0, str(IMAGE_DIR))

import mock_dsv
from fake_identity import IdentityServer

MIRID = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-eh-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-eh-dev-otel"
CLIENT_ID = "11111111-2222-3333-4444-555555555555"
API_VALUE = "dd-api-key-VALUE-8d2f61"
APP_VALUE = "dd-app-key-VALUE-1a77"
ODD_VALUE = 'we"ird $HOME `x` \\ ünï ${DD_API_KEY}'
CLIENT_SECRET = "client-secret-VALUE-0e0e"
ALL_VALUES = (API_VALUE, APP_VALUE, CLIENT_SECRET)

CFG = {
    "users": {MIRID: {"read": ["eh/dev/datadog-*", "eh/dev/odd"]}, "local": {"read": ["eh/dev/*"]}},
    "clients": {"local-client": {"secret": CLIENT_SECRET, "identity": "local"}},
    "secrets": {
        "eh/dev/datadog-api-key": {"value": API_VALUE},
        "eh/dev/datadog-app-key": {"value": APP_VALUE, "site": "datadoghq.eu"},
        "eh/dev/odd": {"value": ODD_VALUE, "multiline": "a\nb"},
        "eh/dev/other": {"value": "not-for-otel"},
    },
}


@pytest.fixture
def dsv():
    httpd, state = mock_dsv.serve(json.loads(json.dumps(CFG)))
    yield f"http://127.0.0.1:{httpd.server_address[1]}/v1", state
    httpd.shutdown()


@pytest.fixture
def identity():
    srv = IdentityServer(MIRID)
    yield srv
    srv.httpd.shutdown()


def base_env(**extra: str) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k in ("PATH", "LANG", "LC_ALL", "SYSTEMROOT")}
    env.update(extra)
    return env


VERSION = (IMAGE_DIR / "VERSION").read_text().strip()
_IMPLS = ["go"]


class Impl:
    """The implementation under test: `argv` prefix, `name` ("go") and the version it reports."""

    name = "go"
    argv: list[str] = []
    version = VERSION


IMPL = Impl()


def _go_binary(tmp_root: Path) -> str | None:
    if os.environ.get("DSV_FETCH_BIN"):
        return os.environ["DSV_FETCH_BIN"]
    go = shutil.which("go") or ("/usr/local/go/bin/go" if Path("/usr/local/go/bin/go").exists() else None)
    if not go:
        return None
    out = tmp_root / ("dsv-fetch.exe" if os.name == "nt" else "dsv-fetch")
    env = {**os.environ, "PATH": f"{Path(go).parent}{os.pathsep}{os.environ.get('PATH', '')}"}
    subprocess.run(
        ["bash", str(IMAGE_DIR / "build.sh"), "--toolchain", "local", "--target", f"{'windows' if os.name == 'nt' else 'linux'}/amd64", "--binary", str(out)],
        check=True, env=env, capture_output=True, timeout=600,
    )
    return str(out)


@pytest.fixture(scope="session")
def go_binary(tmp_path_factory) -> str | None:
    return _go_binary(tmp_path_factory.mktemp("dsv-fetch-bin"))


@pytest.fixture(params=_IMPLS, autouse=True)
def impl(request) -> Impl:
    """Selects the implementation every `run()` in the test uses."""
    binary = request.getfixturevalue("go_binary")
    if not binary:
        pytest.skip("no dsv-fetch binary (set DSV_FETCH_BIN or install Go)")
    IMPL.name, IMPL.argv, IMPL.version = "go", [binary], VERSION
    return IMPL


def run(args: list[str], env: dict[str, str], stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run([*IMPL.argv, *args], env=env, input=stdin, capture_output=True, text=True, timeout=60)
