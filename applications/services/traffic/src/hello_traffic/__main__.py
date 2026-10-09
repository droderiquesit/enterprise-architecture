"""python -m hello_traffic - one bounded run (ACA scheduled job). Exit 0 when the error ratio is acceptable."""

from __future__ import annotations

import logging
import sys

from hello_common.config import service_info
from hello_common.logging import configure_logging
from hello_common.telemetry import setup_telemetry, shutdown_telemetry

from . import settings as settings_mod
from .runner import run

log = logging.getLogger("hello_traffic")


def main() -> int:
    info = service_info("hello-traffic")
    configure_logging(info)
    setup_telemetry(info)
    code = 0
    try:
        summary = run(settings_mod.load(), info.version)
        log.info("traffic run completed", extra={"summary": summary})
        code = 0 if summary["ok"] else 1
    except Exception:
        log.error("traffic run failed", exc_info=True)
        code = 1
    shutdown_telemetry()
    return code


if __name__ == "__main__":
    sys.exit(main())
