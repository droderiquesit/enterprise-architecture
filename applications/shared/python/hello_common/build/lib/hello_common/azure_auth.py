"""Azure credential helpers (Entra ID / managed identity).

``AZURE_CLIENT_ID`` selects the user-assigned managed identity (also used by AKS workload identity).
``AZURE_CREDENTIAL_MODE``:
  * ``default`` (default) - DefaultAzureCredential(managed_identity_client_id=AZURE_CLIENT_ID),
    interactive/browser sources excluded. Works locally with ``az login``.
  * ``managed_identity`` - ManagedIdentityCredential(client_id=AZURE_CLIENT_ID) only (fastest in Azure).
  * ``workload_identity`` - WorkloadIdentityCredential (AKS federated token file).

``TokenCache`` caches an access token per scope and refreshes it 5 minutes before expiry; used
where a token is passed as a *password* (PostgreSQL, MySQL) rather than through an SDK.
"""

from __future__ import annotations

import os
import threading
import time
from typing import Any

SCOPE_OSSRDBMS = "https://ossrdbms-aad.database.windows.net/.default"  # PostgreSQL, MySQL, DocumentDB
SCOPE_REDIS = "https://redis.azure.com/.default"
SCOPE_SQL = "https://database.windows.net/.default"
SCOPE_STORAGE = "https://storage.azure.com/.default"
SCOPE_COSMOS_TEMPLATE = "https://{account}.documents.azure.com/.default"

_cred_lock = threading.Lock()
_cached: dict[str, Any] = {}


def credential_mode() -> str:
    return (os.environ.get("AZURE_CREDENTIAL_MODE") or "default").strip().lower()


def get_credential(*, async_: bool = False) -> Any:
    """Process-wide credential (sync or async flavour), created lazily."""
    key = f"{credential_mode()}:{'async' if async_ else 'sync'}"
    with _cred_lock:
        if key in _cached:
            return _cached[key]
        client_id = os.environ.get("AZURE_CLIENT_ID") or None
        mode = credential_mode()
        if async_:
            from azure.identity import aio as identity
        else:
            from azure import identity  # type: ignore[no-redef]
        if mode == "managed_identity":
            cred = identity.ManagedIdentityCredential(client_id=client_id)
        elif mode == "workload_identity":
            cred = identity.WorkloadIdentityCredential(client_id=client_id)
        else:
            cred = identity.DefaultAzureCredential(
                managed_identity_client_id=client_id,
                workload_identity_client_id=client_id,
                exclude_interactive_browser_credential=True,
            )
        _cached[key] = cred
        return cred


class TokenCache:
    """Thread-safe cached bearer token for one scope (sync credential)."""

    REFRESH_MARGIN_SECONDS = 300

    def __init__(self, scope: str, credential: Any | None = None, clock=time.time) -> None:
        self.scope = scope
        self._credential = credential
        self._clock = clock
        self._token: str | None = None
        self._expires_on = 0.0
        self._lock = threading.Lock()

    def get(self) -> str:
        with self._lock:
            if self._token is None or self._clock() >= self._expires_on - self.REFRESH_MARGIN_SECONDS:
                cred = self._credential or get_credential()
                access = cred.get_token(self.scope)
                self._token = access.token
                self._expires_on = float(access.expires_on)
            return self._token

    @property
    def expires_on(self) -> float:
        return self._expires_on
