"""hello_common - shared runtime for Enterprise Hello Python services."""

# TELEMETRY_SDK=datadog: enable the Datadog tracer (unless injected) before any service imports FastAPI/httpx/
# psycopg/redis - this package is the first import of every entrypoint. No-op in the default otel mode.
from . import apm as _apm

_apm.bootstrap_from_env()

from .config import ConfigError, ServiceInfo, env_bool, env_choice, env_float, env_int, env_str, service_info  # noqa: E402

__all__ = [
    "ConfigError",
    "ServiceInfo",
    "env_bool",
    "env_choice",
    "env_float",
    "env_int",
    "env_str",
    "service_info",
]
__version__ = "1.0.0"
