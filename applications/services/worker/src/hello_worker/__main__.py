"""Entrypoint: `python -m hello_worker` - consumer loop + health HTTP server in one asyncio loop.
SIGTERM/SIGINT stop receiving, drain in-flight messages (SHUTDOWN_GRACE_SECONDS) and close."""

from __future__ import annotations

import asyncio
import logging
import signal
import time

from hello_common.app import create_app
from hello_common.config import service_info
from hello_common.telemetry import shutdown_telemetry

from . import settings as settings_mod
from .sinks import MemorySink, TableSink
from .sources import MemorySource, ServiceBusSource
from .worker import Worker

log = logging.getLogger("hello_worker")


def build(settings=None):
    s = settings or settings_mod.load()
    info = service_info("hello-worker")
    source = MemorySource() if s.messaging_mode == "memory" else ServiceBusSource(s)
    sink = MemorySink() if s.table_mode == "memory" else TableSink(s)
    worker = Worker(source, sink, entity=s.entity, max_concurrency=s.max_concurrency, receive_batch=s.receive_batch,
                    receive_wait=s.receive_wait, max_attempts=s.max_attempts, processing_timeout=s.processing_timeout,
                    shutdown_grace=s.shutdown_grace, retry_delay_base=s.retry_delay_base)

    def loop_alive() -> dict:
        age = time.monotonic() - worker.last_loop
        if worker.stopping:
            raise RuntimeError("shutting down")
        if age > s.receive_wait * 4 + 30:
            raise RuntimeError(f"receive loop stalled for {age:.0f}s")
        if not source.healthy():
            raise RuntimeError("message source unhealthy")
        return {"stats": dict(worker.stats)}

    app = create_app(info, readiness={"consumer": loop_alive, "sink": sink.ping})
    return s, app, worker, source, sink


async def amain() -> None:
    import uvicorn

    s, app, worker, source, sink = build()
    await sink.open()
    await source.open()
    server = uvicorn.Server(uvicorn.Config(app, host="0.0.0.0", port=s.port, log_config=None, access_log=False))  # noqa: S104
    server.install_signal_handlers = lambda: None  # we own signals
    loop = asyncio.get_running_loop()

    def _stop(signame: str) -> None:
        log.info("signal received; stopping", extra={"signal": signame})
        worker.stop()
        server.should_exit = True

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _stop, sig.name)
    log.info("worker starting", extra={"entity": s.entity, "max_concurrency": s.max_concurrency, "messaging_mode": s.messaging_mode, "table_mode": s.table_mode})
    try:
        await asyncio.gather(worker.run(), server.serve())
    finally:
        await source.close()
        await sink.close()
        log.info("worker stopped", extra={"stats": dict(worker.stats)})
        shutdown_telemetry()


def main() -> None:
    asyncio.run(amain())


if __name__ == "__main__":
    main()
