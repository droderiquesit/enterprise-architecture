"""Fail fast: cancel the whole run when a cheap gate fails, so expensive sibling jobs stop burning agents.

Jobs of one stage cannot depend on a gate without waiting for it; instead every expensive leg starts immediately
and the gate job, on failure, cancels the build (Builds - Update, status=cancelling) with System.AccessToken
(the build service identity may cancel its own runs). Without an Azure DevOps context it is a no-op.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable, Optional


def cancel_run(http: Optional[Callable] = None) -> bool:
    base, project = os.environ.get("SYSTEM_COLLECTIONURI", ""), os.environ.get("SYSTEM_TEAMPROJECT", "")
    build, token = os.environ.get("BUILD_BUILDID", ""), os.environ.get("SYSTEM_ACCESSTOKEN", "")
    if not (base and project and build and token):
        print("failfast: no Azure DevOps context - nothing to cancel")
        return True
    url = f"{base.rstrip('/')}/{urllib.parse.quote(project)}/_apis/build/builds/{build}?api-version=7.1"
    body = {"status": "cancelling"}
    if http:
        return bool(http("PATCH", url, body))
    req = urllib.request.Request(url, method="PATCH", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15):
            print("##vso[task.logissue type=warning]gate failed: run cancelled (fail fast)")
            return True
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        print(f"##vso[task.logissue type=warning]failfast: could not cancel the run: {exc}")
        return False
