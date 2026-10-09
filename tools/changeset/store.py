"""Pluggable object store for deployment records, contracts, plans and evidence.

    open_store("/path/to/dir")                                   -> LocalStore (tests, break-glass)
    open_store("file:///path/to/dir")                            -> LocalStore
    open_store("https://<acct>.blob.core.windows.net/<container>[/prefix]") -> BlobStore

BlobStore shells out to the Azure CLI with `--auth-mode login`, i.e. the Entra ID identity of the
AzureCLI@2 task (workload identity federation). Shared keys and SAS tokens are never used
(the state storage account has shared_access_key_enabled = false, ADR §4).
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import List, Optional
from urllib.parse import urlparse


class StoreError(Exception):
    pass


class Store:
    def get_bytes(self, key: str) -> Optional[bytes]:
        raise NotImplementedError

    def put_bytes(self, key: str, data: bytes, content_type: str = "application/json") -> None:
        raise NotImplementedError

    def list(self, prefix: str) -> List[str]:
        raise NotImplementedError

    def delete(self, key: str) -> None:
        raise NotImplementedError

    def get_json(self, key: str):
        data = self.get_bytes(key)
        return None if data is None else json.loads(data.decode("utf-8"))

    def put_json(self, key: str, obj) -> None:
        self.put_bytes(key, (json.dumps(obj, indent=2, sort_keys=True) + "\n").encode("utf-8"))

    def get_file(self, key: str, dest: Path) -> bool:
        data = self.get_bytes(key)
        if data is None:
            return False
        Path(dest).parent.mkdir(parents=True, exist_ok=True)
        Path(dest).write_bytes(data)
        return True

    def put_file(self, src: Path, key: str, content_type: str = "application/octet-stream") -> None:
        self.put_bytes(key, Path(src).read_bytes(), content_type)


class LocalStore(Store):
    def __init__(self, root: Path):
        self.root = Path(root)

    def _p(self, key: str) -> Path:
        p = (self.root / key).resolve()
        if self.root.resolve() not in p.parents and p != self.root.resolve():
            raise StoreError(f"key escapes store root: {key}")
        return p

    def get_bytes(self, key: str) -> Optional[bytes]:
        p = self._p(key)
        return p.read_bytes() if p.is_file() else None

    def put_bytes(self, key: str, data: bytes, content_type: str = "application/json") -> None:
        p = self._p(key)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(p.suffix + ".tmp")
        tmp.write_bytes(data)
        tmp.replace(p)

    def list(self, prefix: str) -> List[str]:
        base = self.root
        if not base.exists():
            return []
        out = []
        for f in base.rglob("*"):
            if f.is_file():
                rel = f.relative_to(base).as_posix()
                if rel.startswith(prefix) and not rel.endswith(".tmp"):
                    out.append(rel)
        return sorted(out)

    def delete(self, key: str) -> None:
        p = self._p(key)
        if p.is_file():
            p.unlink()

    def __repr__(self) -> str:
        return f"LocalStore({self.root})"


class BlobStore(Store):
    """Azure Blob container accessed through `az storage blob` with Entra ID auth."""

    def __init__(self, url: str):
        u = urlparse(url)
        host = u.netloc
        if not host.endswith(".blob.core.windows.net") and ".blob." not in host:
            raise StoreError(f"not a blob endpoint: {url}")
        self.account = host.split(".")[0]
        segments = [s for s in u.path.split("/") if s]
        if not segments:
            raise StoreError(f"blob URL must include a container: {url}")
        self.container = segments[0]
        self.prefix = "/".join(segments[1:])
        self.az = shutil.which("az")
        if not self.az:
            raise StoreError("Azure CLI (az) not found; BlobStore requires it")

    def _name(self, key: str) -> str:
        return f"{self.prefix}/{key}" if self.prefix else key

    def _az(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        cmd = [self.az, "storage", "blob", *args, "--account-name", self.account,
               "--container-name", self.container, "--auth-mode", "login", "--only-show-errors"]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if check and proc.returncode != 0:
            raise StoreError(f"az storage blob {args[0]} failed: {proc.stderr.strip()[:500]}")
        return proc

    def get_bytes(self, key: str) -> Optional[bytes]:
        with tempfile.TemporaryDirectory() as td:
            dest = Path(td) / "blob"
            proc = self._az("download", "--name", self._name(key), "--file", str(dest), check=False)
            if proc.returncode != 0:
                if "BlobNotFound" in proc.stderr or "ResourceNotFound" in proc.stderr or "does not exist" in proc.stderr:
                    return None
                raise StoreError(f"download {key} failed: {proc.stderr.strip()[:500]}")
            return dest.read_bytes()

    def put_bytes(self, key: str, data: bytes, content_type: str = "application/json") -> None:
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "blob"
            src.write_bytes(data)
            self._az("upload", "--name", self._name(key), "--file", str(src), "--overwrite", "true",
                     "--content-type", content_type)

    def list(self, prefix: str) -> List[str]:
        proc = self._az("list", "--prefix", self._name(prefix), "--query", "[].name", "--output", "json",
                        "--num-results", "*")
        names = json.loads(proc.stdout or "[]")
        strip = (self.prefix + "/") if self.prefix else ""
        return sorted(n[len(strip):] if strip and n.startswith(strip) else n for n in names)

    def delete(self, key: str) -> None:
        self._az("delete", "--name", self._name(key), check=False)

    def __repr__(self) -> str:
        return f"BlobStore({self.account}/{self.container}/{self.prefix})"


def open_store(location: Optional[str]) -> Optional[Store]:
    if not location:
        return None
    if location.startswith("https://"):
        return BlobStore(location)
    if location.startswith("file://"):
        return LocalStore(Path(urlparse(location).path))
    return LocalStore(Path(location))
