"""Local git source: base..head of a checkout -> FileChanges (content read with `git cat-file`, never checked out)."""

from __future__ import annotations

from pathlib import Path

from tools.changeset.gitdiff import diff, rev_parse
from tools.changeset.trees import GitTree, WorkTree

from .model import FileChange

BINARY_SNIFF = 8000


def _text(tree, path: str, max_bytes: int):
    data = tree.read_bytes(path)
    if data is None:
        return None, False, False
    if len(data) > max_bytes:
        return None, False, True
    if b"\0" in data[:BINARY_SNIFF]:
        return None, True, False
    try:
        return data.decode("utf-8"), False, False
    except UnicodeDecodeError:
        return None, True, False


def git_changes(repo: Path, base: str, head: str | None, max_file_bytes: int = 512000) -> list[FileChange]:
    """head=None compares base with the working tree."""
    base_sha = rev_parse(repo, base)
    head_sha = rev_parse(repo, head) if head else None
    base_tree = GitTree(repo, base_sha)
    head_tree = GitTree(repo, head_sha) if head_sha else WorkTree(repo)
    out = []
    for ch in diff(repo, base_sha, head_sha):
        status = ch.status[0]
        fc = FileChange(path=ch.path, status="R" if status in ("R", "C") else status, old_path=ch.old_path)
        b1 = t1 = b2 = t2 = False
        if status != "A":
            fc.base_text, b1, t1 = _text(base_tree, ch.old_path or ch.path, max_file_bytes)
        if status != "D":
            fc.head_text, b2, t2 = _text(head_tree, ch.path, max_file_bytes)
        fc.binary, fc.too_large = b1 or b2, t1 or t2
        out.append(fc)
    return out
