"""CLI: python -m hello_jobs <seed|reconcile-trigger|process-batch-items|daily-aggregate>

Every run is one root span (`job <command>`), emits JSON logs (hello_common), prints a summary log line and
exits 0 on success, 1 on failure, 2 on usage errors. Telemetry is flushed before exit (short-lived process)."""

from __future__ import annotations

import argparse
import logging
import sys

from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode

from hello_common.config import service_info
from hello_common.logging import configure_logging
from hello_common.telemetry import meter, setup_telemetry, shutdown_telemetry

from . import commands

COMMANDS = ("seed", "reconcile-trigger", "process-batch-items", "daily-aggregate")
log = logging.getLogger("hello_jobs")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="hello_jobs", description="Enterprise Hello jobs")
    parser.add_argument("command", choices=COMMANDS)
    args = parser.parse_args(argv)
    info = service_info("hello-jobs")
    configure_logging(info)
    setup_telemetry(info)
    runs = meter("hello_jobs").create_counter("hello.jobs.runs", unit="{run}", description="Job runs by command and outcome")
    tracer = trace.get_tracer("hello_jobs")
    code = 0
    with tracer.start_as_current_span(f"job {args.command}", attributes={"command": args.command}) as span:
        try:
            if args.command == "seed":
                summary = commands.seed()
            elif args.command == "reconcile-trigger":
                summary = commands.reconcile_trigger()
            elif args.command == "process-batch-items":
                summary = commands.run_async(commands.process_batch_items())
            else:
                summary = commands.daily_aggregate()
            log.info("job completed", extra={"summary": summary, "command": args.command})
            runs.add(1, {"command": args.command, "outcome": "success"})
        except Exception as exc:
            code = 1
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, type(exc).__name__))
            log.error("job failed", exc_info=True, extra={"command": args.command})
            runs.add(1, {"command": args.command, "outcome": "failure"})
    shutdown_telemetry()
    return code


if __name__ == "__main__":
    sys.exit(main())
