"""Fingerprint-keyed test result cache: testcache/<fingerprint>.json = a recorded PASS of that exact input.

Backends (tools.changeset.store): a local directory (PR builds: restored/saved with Cache@2; local runs:
.ci-cache/) or the `testcache` blob container of the state storage account (credentialed main/test/prod runs,
shared by both pipelines and all branches). Only passes are stored; a failure is never cached. Shards of one suite
record parts (<fp>.part-<files hash>.json); `promote` turns a complete set of passed parts into the suite entry.
Full runs (nightly, release/*) ignore hits and re-run everything (cache poisoning lives at most until then).
"""

from __future__ import annotations

import datetime as dt
import hashlib
import os
from typing import Iterable, List, Optional

from tools.changeset.store import Store, open_store

DEFAULT_DIR = ".ci-cache/testcache"


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def part_id(files: Optional[Iterable[str]]) -> str:
    return hashlib.sha256("\n".join(sorted(files or [])).encode()).hexdigest()[:16]


class ResultCache:
    def __init__(self, store: Optional[Store]):
        self.store = store

    @classmethod
    def open(cls, location: Optional[str]) -> "ResultCache":
        return cls(open_store(location or os.environ.get("CI_TEST_CACHE") or DEFAULT_DIR))

    def hit(self, fingerprint: str) -> Optional[dict]:
        if not self.store or not fingerprint:
            return None
        doc = self.store.get_json(f"{fingerprint}.json")
        return doc if doc and doc.get("result") == "passed" and doc.get("fingerprint") == fingerprint else None

    def record(self, suite: str, fingerprint: str, seconds: float, files: Optional[List[str]] = None,
               run: str = "") -> None:
        if not self.store or not fingerprint:
            return
        key = f"{fingerprint}.json" if files is None else f"{fingerprint}.part-{part_id(files)}.json"
        self.store.put_json(key, {"suite": suite, "fingerprint": fingerprint, "result": "passed",
                                  "seconds": round(seconds, 2), "files": sorted(files) if files else None,
                                  "run": run or os.environ.get("BUILD_BUILDID", "local"), "at": _now()})

    def promote(self, suite: str, fingerprint: str, parts: List[List[str]], run: str = "") -> bool:
        """All shard parts passed -> suite-level entry. Returns True when promoted."""
        if not self.store:
            return False
        docs = [self.store.get_json(f"{fingerprint}.part-{part_id(p)}.json") for p in parts]
        if not docs or not all(d and d.get("result") == "passed" for d in docs):
            return False
        self.record(suite, fingerprint, sum(d.get("seconds", 0) for d in docs), None, run)
        return True
