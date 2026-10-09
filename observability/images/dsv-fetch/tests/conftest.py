"""Fixtures: tools/secrets/mock_dsv.py (DSV API) + a fake Azure identity server (IMDS, IDENTITY_ENDPOINT, Entra token)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
IMAGE_DIR = HERE.parent
REPO = HERE.parents[3]
SCRIPT = IMAGE_DIR / "dsv_fetch.py"
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


def run(args: list[str], env: dict[str, str], stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], env=env, input=stdin, capture_output=True, text=True, timeout=60)
