"""Environment-driven configuration helpers shared by every Enterprise Hello Python service.

Common environment variables (see the application interface spec):

DD_ENV, DD_SERVICE, DD_VERSION        unified service tagging (env / service / version)
OTEL_SERVICE_NAME                     fallback for the service name
GIT_COMMIT, BUILD_TIME                reported by GET /version
PORT                                  HTTP listen port (default 8080)
LOG_LEVEL, LOG_FILE_PATH              logging (see hello_common.logging)
FAULTS_ENABLED, FAULT_TOKEN           fault injection (see hello_common.faults)
AZURE_CLIENT_ID                       user-assigned managed identity client id
"""

from __future__ import annotations

import os
import platform
from dataclasses import dataclass, field

_TRUE = {"1", "true", "yes", "on"}
_FALSE = {"0", "false", "no", "off", ""}


class ConfigError(ValueError):
    """Raised when a required or malformed environment variable is found."""


def env_str(name: str, default: str | None = None, *, required: bool = False) -> str | None:
    value = os.environ.get(name)
    if value is None or value == "":
        if required:
            raise ConfigError(f"environment variable {name} is required")
        return default
    return value


def env_int(name: str, default: int, *, minimum: int | None = None, maximum: int | None = None) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        value = default
    else:
        try:
            value = int(raw.strip())
        except ValueError as exc:
            raise ConfigError(f"environment variable {name} must be an integer, got {raw!r}") from exc
    if minimum is not None and value < minimum:
        raise ConfigError(f"environment variable {name} must be >= {minimum}")
    if maximum is not None and value > maximum:
        raise ConfigError(f"environment variable {name} must be <= {maximum}")
    return value


def env_float(name: str, default: float, *, minimum: float | None = None, maximum: float | None = None) -> float:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        value = default
    else:
        try:
            value = float(raw.strip())
        except ValueError as exc:
            raise ConfigError(f"environment variable {name} must be a number, got {raw!r}") from exc
    if minimum is not None and value < minimum:
        raise ConfigError(f"environment variable {name} must be >= {minimum}")
    if maximum is not None and value > maximum:
        raise ConfigError(f"environment variable {name} must be <= {maximum}")
    return value


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    lowered = raw.strip().lower()
    if lowered in _TRUE:
        return True
    if lowered in _FALSE:
        return False
    raise ConfigError(f"environment variable {name} must be a boolean, got {raw!r}")


def env_choice(name: str, default: str, choices: set[str] | frozenset[str] | tuple[str, ...]) -> str:
    value = (os.environ.get(name) or default).strip().lower()
    if value not in choices:
        raise ConfigError(f"environment variable {name} must be one of {sorted(choices)}, got {value!r}")
    return value


@dataclass(frozen=True)
class ServiceInfo:
    """Identity of the running service; drives logs, the OTel resource and GET /version."""

    service: str
    version: str
    env: str
    commit: str = "unknown"
    build_time: str = "unknown"
    runtime: str = field(default_factory=lambda: f"python {platform.python_version()}")

    def version_document(self) -> dict[str, str]:
        return {
            "service": self.service,
            "version": self.version,
            "commit": self.commit,
            "build_time": self.build_time,
            "runtime": self.runtime,
        }


def service_info(default_service: str, *, service_override_var: str | None = None) -> ServiceInfo:
    """Build ServiceInfo from DD_* / OTEL_* variables.

    ``service_override_var`` lets a service honour an extra variable that wins over DD_SERVICE
    (hello-dbadapter uses DB_SERVICE_NAME).
    """
    service = None
    if service_override_var:
        service = env_str(service_override_var)
    service = service or env_str("DD_SERVICE") or env_str("OTEL_SERVICE_NAME") or default_service
    return ServiceInfo(
        service=service,
        version=env_str("DD_VERSION") or env_str("SERVICE_VERSION") or "0.0.0-dev",
        env=env_str("DD_ENV") or "local",
        commit=env_str("GIT_COMMIT") or "unknown",
        build_time=env_str("BUILD_TIME") or "unknown",
    )


def listen_port(default: int = 8080) -> int:
    return env_int("PORT", default, minimum=1, maximum=65535)
