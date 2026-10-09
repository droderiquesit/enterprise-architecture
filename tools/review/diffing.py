"""Line diffs of base/head texts (pure Python, difflib). Used by rules (added/removed lines) and the AI excerpt."""

from __future__ import annotations

import difflib
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

from .model import FileChange


@dataclass
class LineDiff:
    added: List[Tuple[int, str]] = field(default_factory=list)     # (head line number, text)
    removed: List[Tuple[int, str]] = field(default_factory=list)   # (base line number, text)

    @property
    def changed_lines(self) -> int:
        return len(self.added) + len(self.removed)


def _lines(text: Optional[str]) -> List[str]:
    return [] if not text else text.splitlines()


def line_diff(ch: FileChange) -> LineDiff:
    a, b = _lines(ch.base_text), _lines(ch.head_text)
    d = LineDiff()
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag in ("replace", "delete"):
            d.removed.extend((i + 1, a[i]) for i in range(i1, i2))
        if tag in ("replace", "insert"):
            d.added.extend((j + 1, b[j]) for j in range(j1, j2))
    return d


def unified(ch: FileChange, context: int = 3) -> str:
    a, b = _lines(ch.base_text), _lines(ch.head_text)
    old = f"a/{ch.old_path or ch.path}" if ch.base_text is not None else "/dev/null"
    new = f"b/{ch.path}" if ch.head_text is not None else "/dev/null"
    return "\n".join(difflib.unified_diff(a, b, old, new, n=context, lineterm=""))
