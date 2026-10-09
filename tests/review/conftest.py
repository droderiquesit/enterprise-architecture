import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
for p in (str(ROOT), str(HERE)):
    if p not in sys.path:
        sys.path.insert(0, p)

# Trusted files copied from the real repository into every fixture repo (the reviewer reads them from the base).
TRUSTED = [
    ".review/policy.yaml",
    "catalog/components.yaml",
    "catalog/schemas/component.schema.json",
    "observability/schemas/onboarding-manifest.v1.schema.json",
    "observability/onboarding/dev/hello-bff.yaml",
]
BASE_FILES = {
    "docs/guide.md": "# Guide\n\nSome text.\n",
    "foundation/identity/main.tf": 'resource "azurerm_resource_group" "this" {\n  name     = "rg"\n  location = "swedencentral"\n}\n',
    "applications/services/worker/requirements.txt": "httpx==0.28.1\npydantic==2.14.0\nfastapi==0.143.0\n",
    "applications/services/worker/app.py": "def main():\n    return 1\n",
    "azure-pipelines.yml": "trigger: none\n",
    "platform/shared/main.tf": (
        'resource "azurerm_storage_account" "st" {\n  name = "st"\n  public_network_access_enabled = false\n'
        '  lifecycle {\n    prevent_destroy = true\n  }\n}\n\nresource "azurerm_container_registry" "acr" {\n  name = "acr"\n}\n'
    ),
}

GIT_ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True, env={**os.environ, **GIT_ENV}).stdout


class Repo:
    def __init__(self, path: Path):
        self.path = path

    def write(self, files: dict) -> None:
        for rel, content in files.items():
            p = self.path / rel
            if content is None:
                p.unlink()
                continue
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(content if isinstance(content, bytes) else content.encode())

    def commit(self, files: dict, msg: str = "change") -> str:
        self.write(files)
        git(self.path, "add", "-A")
        git(self.path, "commit", "-q", "-m", msg)
        return git(self.path, "rev-parse", "HEAD").strip()

    def branch(self, name: str, start: str = "main") -> None:
        git(self.path, "checkout", "-q", "-B", name, start)


def make_repo(path: Path) -> Repo:
    path.mkdir(parents=True, exist_ok=True)
    git(path, "init", "-q", "-b", "main")
    r = Repo(path)
    for rel in TRUSTED:
        (path / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / rel, path / rel)
    r.commit(BASE_FILES, "base")
    return r


@pytest.fixture
def repo(tmp_path) -> Repo:
    return make_repo(tmp_path / "repo")
