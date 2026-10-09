"""Typed app settings of eh-pr-reviewer (all set by foundation/pr-reviewer; secrets are dsv:// references that
hello_common.secrets.resolve_env() resolves in-process at start-up with the Function's managed identity)."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import List, MutableMapping, Optional

from tools.review.webhook import Allowlist


def _int(env: MutableMapping[str, str], name: str, default: int, lo: int, hi: int) -> int:
    try:
        v = int(env.get(name, default))
    except ValueError:
        v = default
    return max(lo, min(hi, v))


@dataclass
class Settings:
    ado_base_url: str
    organization: str
    project: str
    project_id: str
    allow: Allowlist
    reviewer_id: Optional[str]
    webhook_username: str
    webhook_secrets: List[str] = field(repr=False)
    replay_window_seconds: int = 600
    queue_name: str = "pr-review"
    queue_service_uri: str = ""
    lock_container_uri: str = ""
    client_id: Optional[str] = None
    recheck_seconds: int = 120
    max_rechecks: int = 30
    ado_auth: str = "managed_identity"      # managed_identity | static (tests/local fake server only)

    @classmethod
    def from_env(cls, env: Optional[MutableMapping[str, str]] = None) -> "Settings":
        e = os.environ if env is None else env
        secrets = [s for s in (e.get("WEBHOOK_SECRET", ""), e.get("WEBHOOK_SECRET_PREVIOUS", "")) if s and not s.startswith("dsv://")]
        return cls(
            ado_base_url=e.get("ADO_BASE_URL", "https://dev.azure.com").rstrip("/"),
            organization=e.get("ADO_ORGANIZATION", ""),
            project=e.get("ADO_PROJECT", ""),
            project_id=e.get("ADO_PROJECT_ID", "").lower(),
            allow=Allowlist.from_settings(e.get("ADO_PROJECT_ID", ""), e.get("ADO_REPOSITORY_IDS", ""), e.get("ADO_ACCOUNT_IDS", "")),
            reviewer_id=e.get("ADO_REVIEWER_ID") or None,
            webhook_username=e.get("WEBHOOK_USERNAME", "eh-review"),
            webhook_secrets=secrets,
            replay_window_seconds=_int(e, "WEBHOOK_REPLAY_WINDOW_SECONDS", 600, 60, 3600),
            queue_name=e.get("REVIEW_QUEUE_NAME", "pr-review"),
            queue_service_uri=e.get("ReviewQueue__queueServiceUri", ""),
            lock_container_uri=e.get("REVIEW_LOCK_CONTAINER_URI", ""),
            client_id=e.get("AZURE_CLIENT_ID") or None,
            recheck_seconds=_int(e, "REVIEW_RECHECK_SECONDS", 120, 30, 3600),
            max_rechecks=_int(e, "REVIEW_MAX_RECHECKS", 30, 0, 200),
            ado_auth=e.get("ADO_AUTH", "managed_identity"),
        )

    def problems(self) -> List[str]:
        out = []
        for name, val in (("ADO_ORGANIZATION", self.organization), ("ADO_PROJECT", self.project), ("ADO_PROJECT_ID", self.project_id)):
            if not val:
                out.append(f"{name} not set")
        if not self.allow.repository_ids:
            out.append("ADO_REPOSITORY_IDS not set")
        if not self.webhook_secrets:
            out.append("WEBHOOK_SECRET not resolved")
        if self.ado_auth not in ("managed_identity", "static"):
            out.append("ADO_AUTH invalid")
        return out
