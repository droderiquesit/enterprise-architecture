"""Pins of img-dsv-fetch agree everywhere: VERSION, versions.yaml images.dsv_fetch*, Dockerfile FROM lines, build.sh."""

from __future__ import annotations

import re

import pytest
import yaml
from conftest import IMAGE_DIR, REPO


@pytest.fixture(autouse=True)
def _once(impl):
    if impl.name != "go":
        pytest.skip("static check, runs once")


def _pins() -> dict:
    return yaml.safe_load((REPO / "versions.yaml").read_text())["images"]


def test_version_file_matches_versions_yaml():
    assert _pins()["dsv_fetch"] == f"dsv-fetch:{(IMAGE_DIR / 'VERSION').read_text().strip()}"
    assert re.fullmatch(r"2\.\d+\.\d+", (IMAGE_DIR / "VERSION").read_text().strip())


def test_dockerfile_and_build_script_use_the_pinned_digests():
    pins = _pins()
    froms = re.findall(r"(?m)^FROM\s+(?:--platform=\S+\s+)?(\S+)", (IMAGE_DIR / "Dockerfile").read_text())
    assert froms == [pins["dsv_fetch_builder"], pins["dsv_fetch_base"]]
    assert all(re.search(r"@sha256:[0-9a-f]{64}$", f) for f in froms)
    build = (IMAGE_DIR / "build.sh").read_text()
    assert f'GO_IMAGE="{pins["dsv_fetch_builder"]}"' in build
    go_version = re.search(r"golang:(\d+\.\d+\.\d+)-", pins["dsv_fetch_builder"]).group(1)
    assert f'GO_VERSION="{go_version}"' in build
    assert pins["dsv_fetch_base"].startswith("gcr.io/distroless/static-debian13:nonroot@")


def test_image_has_no_python():
    text = (IMAGE_DIR / "Dockerfile").read_text()
    assert "python" not in text.lower()
    assert 'ENTRYPOINT ["/opt/dsv-fetch/dsv-fetch"]' in text and 'CMD ["version"]' in text
    assert "dsv_fetch.py" not in (IMAGE_DIR / ".dockerignore").read_text()
