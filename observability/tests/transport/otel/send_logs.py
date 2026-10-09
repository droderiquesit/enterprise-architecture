"""Send synthetic OTLP log records (as the Azure Functions host does when OTEL_EXPORTER_OTLP_ENDPOINT is set),
over gRPC and HTTP. Exit code 0 only if every export call succeeded (i.e. the gateway ACCEPTED the logs)."""

import logging
import sys

from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter as GrpcLogExporter
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter as HttpLogExporter
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import SimpleLogRecordProcessor
from opentelemetry.sdk.resources import Resource

RESULTS = []


class Recording:
    """Wraps an exporter and records each export result."""

    def __init__(self, inner):
        self.inner = inner

    def export(self, batch):
        r = self.inner.export(batch)
        RESULTS.append((type(self.inner).__name__, getattr(r, "name", str(r))))
        return r

    def shutdown(self):
        return self.inner.shutdown()

    def force_flush(self, timeout_millis=30000):
        return True


def main(grpc_endpoint: str, http_endpoint: str) -> int:
    res = Resource.create({"service.name": "hello-durable", "deployment.environment.name": "test"})
    for exp in (GrpcLogExporter(endpoint=grpc_endpoint, insecure=True), HttpLogExporter(endpoint=f"{http_endpoint}/v1/logs")):
        provider = LoggerProvider(resource=res)
        provider.add_log_record_processor(SimpleLogRecordProcessor(Recording(exp)))
        log = logging.getLogger(f"Host.Function.{type(exp).__name__}")
        log.propagate = False
        log.setLevel(logging.INFO)
        handler = LoggingHandler(level=logging.INFO, logger_provider=provider)
        log.addHandler(handler)
        for i in range(3):
            log.info("Executed 'Functions.OrderProcessing' (Succeeded) otlp-log-%d", i)
        log.removeHandler(handler)
        provider.shutdown()
    print(RESULTS)
    return 0 if len(RESULTS) == 6 and all(r[1] == "SUCCESS" for r in RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
