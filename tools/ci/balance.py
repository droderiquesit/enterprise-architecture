"""Duration-based sharding and leg packing (multi-agent fan-out).

Units: one per suite to execute; a pytest suite whose estimate exceeds the target leg time is split by test FILE
into k shards (longest-processing-time-first over per-file durations), because xdist `--dist loadfile` inside a
leg keeps module/session fixtures per file. Legs: units grouped by toolchain (an agent sets up one toolchain), the
number of legs per group proportional to its estimated time, capped by `max_legs`; units are packed into legs
LPT-first. Gate suites get their own leg so cheap failures surface in about a minute.

Durations: tools/ci/timings.json (committed, measured locally) overlaid with timings recorded by previous runs
(<cache>/timings.json, exponentially weighted) - stable when nothing is known, adaptive when it is.
"""

from __future__ import annotations

import heapq
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

DEFAULTS = {"component:terraform": 25.0, "component:dotnet": 90.0, "component:node": 60.0, "component:python": 45.0,
            "module": 12.0, "pytest_file": 3.0, "script": 20.0, "dotnet": 60.0, "leg_overhead": 60.0}
TIMINGS_FILE = Path(__file__).with_name("timings.json")


@dataclass
class Unit:
    suite: str
    toolchain: str
    tier: str
    seconds: float
    files: Optional[List[str]] = None     # pytest shard: the files of this shard (None = whole suite)
    shard: str = ""                       # "i/n" for sharded suites

    @property
    def name(self) -> str:
        return f"{self.suite}#{self.shard}" if self.shard else self.suite


@dataclass
class Leg:
    name: str
    toolchain: str
    units: List[Unit] = field(default_factory=list)

    @property
    def seconds(self) -> float:
        return sum(u.seconds for u in self.units)


def load_timings(extra: Optional[Path] = None) -> dict:
    doc = {"suites": {}, "files": {}}
    for p in (TIMINGS_FILE, extra):
        if p and Path(p).exists():
            try:
                d = json.loads(Path(p).read_text())
            except ValueError:
                continue
            doc["suites"].update(d.get("suites") or {})
            doc["files"].update(d.get("files") or {})
    return doc


def merge_timings(old: dict, new: dict, weight: float = 0.5) -> dict:
    """EWMA of observed durations (new observations weigh `weight`). Sorted keys: deterministic file."""
    out = {"suites": dict(old.get("suites") or {}), "files": dict(old.get("files") or {})}
    for section in ("suites", "files"):
        for k, v in (new.get(section) or {}).items():
            prev = out[section].get(k)
            out[section][k] = round(v if prev is None else prev * (1 - weight) + v * weight, 2)
        out[section] = dict(sorted(out[section].items()))
    return out


def estimate(suite, timings: dict, files: Optional[List[str]] = None) -> float:
    if suite.id in timings["suites"]:
        return float(timings["suites"][suite.id])
    if suite.kind == "pytest" and files:
        return sum(timings["files"].get(f, DEFAULTS["pytest_file"]) for f in files)
    if suite.kind == "component":
        return DEFAULTS.get(f"component:{suite.toolchain}", 45.0)
    return DEFAULTS.get(suite.kind, 30.0)


def lpt(items: List[tuple], n: int) -> List[List[tuple]]:
    """Longest processing time first: (weight, key, payload) items into n bins of near-equal weight. Deterministic."""
    bins: List[List[tuple]] = [[] for _ in range(max(1, n))]
    heap = [(0.0, i) for i in range(len(bins))]
    for item in sorted(items, key=lambda x: (-x[0], x[1])):
        load, i = heapq.heappop(heap)
        bins[i].append(item)
        heapq.heappush(heap, (load + item[0], i))
    return bins


def units_for(suite, timings: dict, target: float, files: Optional[List[str]] = None) -> List[Unit]:
    est = estimate(suite, timings, files)
    if suite.kind != "pytest" or not files or est <= target or len(files) < 2:
        return [Unit(suite.id, suite.toolchain, suite.tier, round(est, 1))]
    k = min(len(files), math.ceil(est / target))
    per_file = [(timings["files"].get(f, est / len(files)), f, f) for f in files]
    out = []
    for i, b in enumerate(lpt(per_file, k), 1):
        if b:
            out.append(Unit(suite.id, suite.toolchain, suite.tier, round(sum(x[0] for x in b), 1),
                            files=sorted(x[2] for x in b), shard=f"{i}/{k}"))
    return out


def pack(units: List[Unit], target: float, max_legs: int) -> List[Leg]:
    gates = [u for u in units if u.tier == "gate"]
    rest = [u for u in units if u.tier != "gate"]
    legs: List[Leg] = []
    if gates:
        legs.append(Leg("gates", "terraform" if any(u.toolchain == "terraform" for u in gates) else gates[0].toolchain,
                        sorted(gates, key=lambda u: u.name)))
    groups: Dict[str, List[Unit]] = {}
    for u in rest:
        groups.setdefault(u.toolchain, []).append(u)
    budget = max(1, max_legs - len(legs))
    total = sum(u.seconds for u in rest) or 1.0
    wanted = {tc: max(1, math.ceil(sum(u.seconds for u in us) / target)) for tc, us in groups.items()}
    if sum(wanted.values()) > budget:      # scale down proportionally, at least one leg per toolchain
        wanted = {tc: max(1, int(budget * sum(u.seconds for u in us) / total)) for tc, us in groups.items()}
    for tc in sorted(groups):
        n = min(wanted[tc], len(groups[tc]))
        bins = lpt([(u.seconds, u.name, u) for u in groups[tc]], n)
        for i, b in enumerate(bins, 1):
            if b:
                legs.append(Leg(f"{tc}_{i}", tc, sorted((x[2] for x in b), key=lambda u: u.name)))
    return legs
