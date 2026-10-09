"""Environment:
FRONTEND_URL                 https://<swa or nginx host>/ (browser journeys; also used to discover apiBaseUrl
                             from FRONTEND_URL/config.json when API_BASE_URL is unset)
API_BASE_URL                 hello-bff base URL for API journeys (optional, see above)
TRAFFIC_RPS                  API journeys per second (default 0.2; max 5)
TRAFFIC_DURATION_SECONDS     run length (default 60; hard max 600)
TRAFFIC_BROWSER_JOURNEYS     Playwright Chromium journeys per run (default 2; max 20; 0 disables)
TRAFFIC_ORDER_TIMEOUT_SECONDS wait for Fulfilled/Failed (default 90)
TRAFFIC_MAX_ERROR_RATIO      exit 1 when failed/total exceeds it (default 0.5)
TRAFFIC_SKUS                 comma list (default SKU-0001..SKU-0020)
TRAFFIC_ROUNDTRIP_ADAPTERS   true|false - include adapter roundtrips in API journeys (default false)
"""

from __future__ import annotations

from dataclasses import dataclass, field

from hello_common.config import env_bool, env_float, env_int, env_str


@dataclass(frozen=True)
class Settings:
    frontend_url: str | None
    api_base_url: str | None
    rps: float
    duration: int
    browser_journeys: int
    order_timeout: int
    max_error_ratio: float
    roundtrip_adapters: bool
    skus: list[str] = field(default_factory=list)


def load() -> Settings:
    skus = [s.strip() for s in (env_str("TRAFFIC_SKUS") or "").split(",") if s.strip()] or [f"SKU-{i:04d}" for i in range(1, 21)]
    return Settings(
        frontend_url=env_str("FRONTEND_URL"),
        api_base_url=env_str("API_BASE_URL"),
        rps=env_float("TRAFFIC_RPS", 0.2, minimum=0.0, maximum=5.0),
        duration=env_int("TRAFFIC_DURATION_SECONDS", 60, minimum=0, maximum=600),
        browser_journeys=env_int("TRAFFIC_BROWSER_JOURNEYS", 2, minimum=0, maximum=20),
        order_timeout=env_int("TRAFFIC_ORDER_TIMEOUT_SECONDS", 90, minimum=5, maximum=600),
        max_error_ratio=env_float("TRAFFIC_MAX_ERROR_RATIO", 0.5, minimum=0.0, maximum=1.0),
        roundtrip_adapters=env_bool("TRAFFIC_ROUNDTRIP_ADAPTERS", False),
        skus=skus,
    )
