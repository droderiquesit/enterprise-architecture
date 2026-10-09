"""Process-level setup: dsv:// app settings -> values (Delinea DSV, managed identity), JSON logs, OTel.

Same pattern as hello-functions (host.json telemetryMode OpenTelemetry, PYTHON_ENABLE_OPENTELEMETRY=true,
OTEL_EXPORTER_OTLP_ENDPOINT -> observability OTel gateway). DD_SERVICE / OTEL_SERVICE_NAME = eh-pr-reviewer.
Host-read settings (AzureWebJobsStorage, ReviewQueue) are identity-based - the host cannot resolve dsv://."""

from __future__ import annotations

import sys
from pathlib import Path

from hello_common.config import service_info
from hello_common.logging import configure_logging
from hello_common.secrets import resolve_env
from hello_common.telemetry import setup_telemetry

_done = False
SERVICE = "eh-pr-reviewer"


def ensure_path() -> None:
    """The package bundles tools/review + tools/changeset next to function_app.py (build.sh); in the repository
    they live at the repo root."""
    here = Path(__file__).resolve().parent.parent
    for cand in (here, *here.parents):
        if (cand / "tools" / "review" / "engine.py").is_file():
            if str(cand) not in sys.path:
                sys.path.insert(0, str(cand))
            return


def configure() -> None:
    global _done
    if _done:
        return
    ensure_path()
    resolve_env()  # WEBHOOK_SECRET, ANTHROPIC_API_KEY: dsv://<prefix>/<env>/<name>#value
    info = service_info(SERVICE)
    configure_logging(info, keep_existing_handlers=True)
    setup_telemetry(info)
    _done = True
