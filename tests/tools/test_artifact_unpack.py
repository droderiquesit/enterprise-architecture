"""tools/deploy/artifacts.py unpack: a root that consumes a zip-package as files (obs-hosts <- img-dsv-fetch release)
gets it extracted only after the package sha256 AND the SHA256SUMS inside it verified."""

from __future__ import annotations

import hashlib
import sys
import zipfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from tools.deploy import artifacts  # noqa: E402


def _package(tmp: Path, tamper: bool = False) -> tuple[str, str]:
    files = {"dsv-fetch-linux-amd64": b"\x7fELF amd64", "dsv-fetch-linux-arm64": b"\x7fELF arm64", "dsv-fetch-windows-amd64.exe": b"MZ win"}
    sums = "".join(f"{hashlib.sha256(b).hexdigest()}  {n}\n" for n, b in sorted(files.items()))
    store = tmp / "packages"
    (store / "img-dsv-fetch").mkdir(parents=True)
    z = store / "img-dsv-fetch" / "src-0123.zip"
    with zipfile.ZipFile(z, "w") as zf:
        for n, b in files.items():
            zf.writestr(n, b + (b"x" if tamper and n.endswith("arm64") else b""))
        zf.writestr("SHA256SUMS", sums)
    return f"file://{store}/img-dsv-fetch/src-0123.zip", hashlib.sha256(z.read_bytes()).hexdigest()


def test_unpack_verifies_and_extracts(tmp_path):
    url, sha = _package(tmp_path)
    dest = tmp_path / "root" / ".dsv-fetch-release"
    names = artifacts.unpack_package(url, sha, dest)
    assert sorted(names) == ["dsv-fetch-linux-amd64", "dsv-fetch-linux-arm64", "dsv-fetch-windows-amd64.exe"]
    assert (dest / "SHA256SUMS").exists() and (dest / "dsv-fetch-linux-amd64").read_bytes() == b"\x7fELF amd64"


def test_unpack_rejects_wrong_package_sha(tmp_path):
    url, _ = _package(tmp_path)
    with pytest.raises(SystemExit, match="sha256 mismatch"):
        artifacts.unpack_package(url, "0" * 64, tmp_path / "d")
    assert not (tmp_path / "d").exists()


def test_unpack_rejects_sha256sums_mismatch(tmp_path):
    url, sha = _package(tmp_path, tamper=True)
    with pytest.raises(SystemExit, match="SHA256SUMS mismatch"):
        artifacts.unpack_package(url, sha, tmp_path / "d")
    assert not (tmp_path / "d").exists()


def test_unpack_only_for_declared_roots():
    assert artifacts.UNPACK["obs-hosts"] == [("img-dsv-fetch", ".dsv-fetch-release")]
    args = type("A", (), {"component": "platform-vm"})()
    assert artifacts.cmd_unpack(args) == 0  # no-op, nothing resolved
