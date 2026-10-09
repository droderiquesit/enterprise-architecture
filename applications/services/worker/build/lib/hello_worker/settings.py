"""hello-worker configuration (environment).

MESSAGING_MODE        servicebus (default) | memory (tests/local)
SERVICEBUS_FQDN       <namespace>.servicebus.windows.net (managed identity via AZURE_CLIENT_ID)
SERVICEBUS_CONNECTION_STRING  emulator/local only (overrides FQDN)
SB_TOPIC / SB_SUBSCRIPTION    default order-events / notifications
SB_QUEUE              consume a queue instead of a topic subscription (optional)
MAX_CONCURRENCY       in-flight messages (default 8)          RECEIVE_BATCH (default 10)
RECEIVE_WAIT_SECONDS  max wait per receive call (default 5)   PREFETCH (default 20)
MAX_DELIVERY_ATTEMPTS dead-letter after this many attempts (default 5; keep below the subscription's
                      MaxDeliveryCount so the worker records the reason)
LOCK_RENEW_MAX_SECONDS AutoLockRenewer ceiling per message (default 300)
PROCESSING_TIMEOUT_SECONDS per-message processing timeout (default 30)
RETRY_DELAY_BASE_SECONDS pause before abandoning a failed message: base*2^(attempt-1), max 10 s (default 0.5)
SHUTDOWN_GRACE_SECONDS wait for in-flight messages on SIGTERM (default 25)
TABLE_MODE            table (default) | memory
TABLES_ENDPOINT       https://<account>.table.core.windows.net (Entra) | TABLES_CONNECTION_STRING (Azurite)
TABLE_NAME            default notifications
PORT                  health server port (default 8081): /healthz /readyz /version
"""

from __future__ import annotations

from dataclasses import dataclass

from hello_common.config import env_choice, env_float, env_int, env_str


@dataclass(frozen=True)
class Settings:
    messaging_mode: str
    sb_fqdn: str | None
    sb_connection_string: str | None
    topic: str
    subscription: str
    queue: str | None
    max_concurrency: int
    receive_batch: int
    receive_wait: int
    prefetch: int
    max_attempts: int
    lock_renew_max: int
    processing_timeout: int
    shutdown_grace: int
    retry_delay_base: float
    table_mode: str
    tables_endpoint: str | None
    tables_connection_string: str | None
    table_name: str
    port: int

    @property
    def entity(self) -> str:
        return self.queue or f"{self.topic}/subscriptions/{self.subscription}"


def load() -> Settings:
    return Settings(
        messaging_mode=env_choice("MESSAGING_MODE", "servicebus", {"servicebus", "memory"}),
        sb_fqdn=env_str("SERVICEBUS_FQDN"),
        sb_connection_string=env_str("SERVICEBUS_CONNECTION_STRING"),
        topic=env_str("SB_TOPIC", "order-events"),
        subscription=env_str("SB_SUBSCRIPTION", "notifications"),
        queue=env_str("SB_QUEUE"),
        max_concurrency=env_int("MAX_CONCURRENCY", 8, minimum=1, maximum=256),
        receive_batch=env_int("RECEIVE_BATCH", 10, minimum=1, maximum=100),
        receive_wait=env_int("RECEIVE_WAIT_SECONDS", 5, minimum=1, maximum=60),
        prefetch=env_int("PREFETCH", 20, minimum=0, maximum=1000),
        max_attempts=env_int("MAX_DELIVERY_ATTEMPTS", 5, minimum=1, maximum=100),
        lock_renew_max=env_int("LOCK_RENEW_MAX_SECONDS", 300, minimum=30, maximum=3600),
        processing_timeout=env_int("PROCESSING_TIMEOUT_SECONDS", 30, minimum=1, maximum=600),
        shutdown_grace=env_int("SHUTDOWN_GRACE_SECONDS", 25, minimum=1, maximum=300),
        retry_delay_base=env_float("RETRY_DELAY_BASE_SECONDS", 0.5, minimum=0.0, maximum=10.0),
        table_mode=env_choice("TABLE_MODE", "table", {"table", "memory"}),
        tables_endpoint=env_str("TABLES_ENDPOINT"),
        tables_connection_string=env_str("TABLES_CONNECTION_STRING"),
        table_name=env_str("TABLE_NAME", "notifications"),
        port=env_int("PORT", 8081, minimum=1, maximum=65535),
    )
