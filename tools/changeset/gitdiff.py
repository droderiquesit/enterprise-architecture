"""Git helpers for PR mode: merge-base resolution and rename-aware diffs."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

from .trees import git


@dataclass(frozen=True)
class Change:
    status: str          # A, M, D, R, C, T
    path: str            # new path (or deleted path for D)
    old_path: Optional[str] = None  # for R/C

    @property
    def paths(self) -> List[str]:
        return [p for p in (self.old_path, self.path) if p]


def resolve_target_ref(repo: Path, target: str) -> str:
    """`origin/<target>` when it exists (CI), else the local branch/ref (tests, local runs)."""
    target = target.removeprefix("refs/heads/")
    for cand in (f"origin/{target}", f"refs/remotes/origin/{target}", target):
        if git(repo, "rev-parse", "--verify", "--quiet", f"{cand}^{{commit}}", check=False).strip():
            return cand
    raise RuntimeError(f"target branch '{target}' not found (fetch it: git fetch origin {target})")


def merge_base(repo: Path, target_ref: str, head: str = "HEAD") -> str:
    out = git(repo, "merge-base", target_ref, head, check=False).strip()
    if not out:
        raise RuntimeError(f"no merge-base between {target_ref} and {head} (shallow clone? use fetchDepth: 0)")
    return out


def diff(repo: Path, base: str, head: str = "HEAD") -> List[Change]:
    out = git(repo, "diff", "--name-status", "-z", "-M", "--no-color", f"{base}..{head}")
    tokens = [t for t in out.split("\0")]
    changes: List[Change] = []
    i = 0
    while i < len(tokens):
        st = tokens[i]
        if not st:
            i += 1
            continue
        code = st[0]
        if code in ("R", "C"):
            old, new = tokens[i + 1], tokens[i + 2]
            changes.append(Change(code, new, old))
            i += 3
        else:
            changes.append(Change(code, tokens[i + 1]))
            i += 2
    return changes


def rev_parse(repo: Path, rev: str) -> str:
    return git(repo, "rev-parse", rev).strip()
