"""Component ownership: registry `owners`, defaulting to environments/branching.yaml owners_by_layer."""

from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Tuple

import yaml

REPO = Path(__file__).resolve().parents[2]


def branching_doc(repo: Path = REPO) -> dict:
    p = Path(repo) / "environments/branching.yaml"
    return (yaml.safe_load(p.read_text()) or {}) if p.exists() else {}


def owners_for(component, doc: dict) -> List[str]:
    return list(component.owners) or list((doc.get("owners_by_layer") or {}).get(component.layer) or [])


def path_patterns(component) -> List[str]:
    """Repository paths owned by a component: its root plus non-negated `inputs` globs (as directory prefixes)."""
    out = [f"/{component.path.strip('/')}/"]
    for g in component.inputs:
        if g.startswith("!") or g.startswith("**"):
            continue  # negations / repo-wide globs (docs: **/*.md) are not ownership
        base = g.split("*", 1)[0]
        if base.endswith("/"):
            out.append("/" + base.lstrip("/"))
        elif "*" not in g:
            out.append("/" + g.lstrip("/"))
    return sorted(set(out))


def ownership(registry, doc: dict) -> List[Tuple[str, List[str], str]]:
    """[(path pattern, owners, source)] sorted so that more specific paths come later (last match wins)."""
    entries: Dict[str, Tuple[List[str], str]] = {}
    for g in doc.get("global_owners") or []:
        for path in g["paths"]:
            entries[path] = (sorted(g["owners"]), "global")
    for c in registry:
        owners = owners_for(c, doc)
        if not owners:
            continue
        for pat in path_patterns(c):
            prev = entries.get(pat)
            merged = sorted(set(owners) | set(prev[0] if prev and prev[1] != "global" else []))
            entries[pat] = (merged, c.id if not prev or prev[1] == "global" else f"{prev[1]},{c.id}")
    return sorted(((p, o, src) for p, (o, src) in entries.items()), key=lambda e: (e[0].rstrip("/").count("/"), e[0]))
