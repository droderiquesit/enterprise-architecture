"""Deterministic test sharding for large suites (no plugin): TEST_SHARD="<i>/<n>" (1-based, e.g. from
System.JobPositionInPhase / System.TotalJobsInPhase of a `parallel: n` job) keeps the tests whose node id hashes
to shard i. Stable across runs and machines (sha256 of the node id), independent of collection order, and the union
of all shards is the full suite (tests/tools/test_pr_scaling.py proves it).

    # conftest.py
    from tools.pipeline.shard import filter_items
    def pytest_collection_modifyitems(config, items):
        filter_items(config, items)
"""

from __future__ import annotations

import hashlib
import os
from typing import Iterable, List, Optional, Tuple


def parse(spec: Optional[str]) -> Optional[Tuple[int, int]]:
    if not spec or "/" not in spec:
        return None
    i, n = (int(x) for x in spec.split("/", 1))
    if n <= 1:
        return None
    if not 1 <= i <= n:
        raise ValueError(f"TEST_SHARD {spec}: shard index must be 1..{n}")
    return i, n


def shard_of(nodeid: str, n: int) -> int:
    return int(hashlib.sha256(nodeid.encode()).hexdigest()[:8], 16) % n + 1


def keep(nodeids: Iterable[str], spec: Optional[str]) -> List[str]:
    p = parse(spec)
    if p is None:
        return list(nodeids)
    i, n = p
    return [x for x in nodeids if shard_of(x, n) == i]


def filter_items(config, items) -> None:
    p = parse(os.environ.get("TEST_SHARD"))
    if p is None:
        return
    i, n = p
    selected = [it for it in items if shard_of(it.nodeid, n) == i]
    deselected = [it for it in items if shard_of(it.nodeid, n) != i]
    if deselected:
        config.hook.pytest_deselected(items=deselected)
        items[:] = selected
