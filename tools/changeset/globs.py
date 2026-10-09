"""Repository-relative glob matching with `**` support and `!negation` lists."""

from __future__ import annotations

import functools
import re
from typing import Iterable


@functools.lru_cache(maxsize=4096)
def _compile(pattern: str) -> re.Pattern[str]:
    pattern = pattern.strip().lstrip("/")
    out = []
    i = 0
    n = len(pattern)
    while i < n:
        c = pattern[i]
        if c == "*":
            if i + 1 < n and pattern[i + 1] == "*":
                # '**' : any number of path segments (incl. zero)
                i += 2
                if i < n and pattern[i] == "/":
                    i += 1
                    out.append("(?:.*/)?")
                else:
                    out.append(".*")
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            j = pattern.find("]", i)
            if j == -1:
                out.append(re.escape(c))
            else:
                out.append(pattern[i : j + 1])
                i = j
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(out) + "$")


def match(pattern: str, path: str) -> bool:
    """True when `path` (posix, repo-relative) matches `pattern`.

    A pattern without glob characters also matches everything below it when it names a directory.
    """
    if not any(ch in pattern for ch in "*?["):
        p = pattern.rstrip("/")
        return path == p or path.startswith(p + "/")
    return bool(_compile(pattern).match(path))


def match_any(patterns: Iterable[str], path: str) -> bool:
    """Gitignore-like evaluation: later `!pattern` entries exclude earlier matches."""
    result = False
    for pat in patterns:
        if pat.startswith("!"):
            if result and match(pat[1:], path):
                result = False
        elif not result and match(pat, path):
            result = True
    return result


def under(path: str, directory: str) -> bool:
    directory = directory.rstrip("/")
    return path == directory or path.startswith(directory + "/")
