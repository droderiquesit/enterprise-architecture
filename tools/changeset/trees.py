"""File-tree abstractions so fingerprints can be computed for the working tree or any git commit.

Content identity uses git blob ids (sha1 of ``blob <len>\\0<content>``) in both implementations,
so a fingerprint computed from a commit equals the fingerprint of the same checked-out files.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
from pathlib import Path
from typing import Dict, Optional

# Never part of any fingerprint: generated, local or cache files.
IGNORED_DIR_NAMES = {".git", ".terraform", "node_modules", "__pycache__", ".pytest_cache", "bin", "obj", ".venv", "dist"}
IGNORED_FILE_NAMES = {"terraform.tfvars.json", "contracts.auto.tfvars.json", "artifacts.auto.tfvars.json", ".DS_Store"}


def _ignored(rel: str) -> bool:
    parts = rel.split("/")
    if any(p in IGNORED_DIR_NAMES for p in parts[:-1]):
        return True
    name = parts[-1]
    return name in IGNORED_FILE_NAMES or name.endswith((".tfplan", ".pyc")) or name.endswith(".tfstate")


def git_blob_id(data: bytes) -> str:
    h = hashlib.sha1()
    h.update(b"blob %d\0" % len(data))
    h.update(data)
    return h.hexdigest()


def git(repo: Path, *args: str, check: bool = True) -> str:
    proc = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


class Tree:
    """Read-only view of repository files."""

    label = "tree"

    def files(self) -> Dict[str, str]:  # path -> blob id
        raise NotImplementedError

    def read_bytes(self, path: str) -> Optional[bytes]:
        raise NotImplementedError

    def read_text(self, path: str) -> Optional[str]:
        data = self.read_bytes(path)
        return None if data is None else data.decode("utf-8", errors="replace")

    def exists(self, path: str) -> bool:
        return path in self.files()

    def list_dir(self, directory: str) -> Dict[str, str]:
        directory = directory.rstrip("/")
        prefix = directory + "/" if directory else ""
        return {p: b for p, b in self.files().items() if p.startswith(prefix)}

    def is_dir(self, directory: str) -> bool:
        prefix = directory.rstrip("/") + "/"
        return any(p.startswith(prefix) for p in self.files())


class WorkTree(Tree):
    """The checked-out working tree (tracked + untracked-but-not-ignored files when in git)."""

    def __init__(self, root: Path):
        self.root = Path(root).resolve()
        self.label = f"worktree:{self.root}"
        self._files: Optional[Dict[str, str]] = None

    def _list(self) -> list[str]:
        if (self.root / ".git").exists():
            try:
                out = git(self.root, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
                return sorted({p for p in out.split("\0") if p})
            except RuntimeError:
                pass
        result = []
        for dirpath, dirnames, filenames in os.walk(self.root):
            dirnames[:] = [d for d in dirnames if d not in IGNORED_DIR_NAMES]
            for f in filenames:
                result.append(Path(dirpath, f).relative_to(self.root).as_posix())
        return sorted(result)

    def files(self) -> Dict[str, str]:
        if self._files is None:
            files: Dict[str, str] = {}
            for rel in self._list():
                if _ignored(rel):
                    continue
                full = self.root / rel
                if not full.is_file():  # deleted but still in the index
                    continue
                files[rel] = git_blob_id(full.read_bytes())
            self._files = files
        return self._files

    def read_bytes(self, path: str) -> Optional[bytes]:
        full = self.root / path
        return full.read_bytes() if full.is_file() else None


class GitTree(Tree):
    """Files of a git commit (no checkout needed)."""

    def __init__(self, repo: Path, rev: str):
        self.repo = Path(repo).resolve()
        self.rev = git(self.repo, "rev-parse", "--verify", f"{rev}^{{commit}}").strip()
        self.label = f"git:{self.rev[:12]}"
        self._files: Optional[Dict[str, str]] = None
        self._cache: Dict[str, bytes] = {}

    def files(self) -> Dict[str, str]:
        if self._files is None:
            out = git(self.repo, "ls-tree", "-r", "-z", "--full-tree", self.rev)
            files = {}
            for entry in out.split("\0"):
                if not entry:
                    continue
                meta, path = entry.split("\t", 1)
                _mode, typ, sha = meta.split()
                if typ != "blob" or _ignored(path):
                    continue
                files[path] = sha
            self._files = files
        return self._files

    def read_bytes(self, path: str) -> Optional[bytes]:
        sha = self.files().get(path)
        if sha is None:
            return None
        if sha not in self._cache:
            proc = subprocess.run(["git", "-C", str(self.repo), "cat-file", "blob", sha], capture_output=True)
            if proc.returncode != 0:
                raise RuntimeError(proc.stderr.decode())
            self._cache[sha] = proc.stdout
        return self._cache[sha]
