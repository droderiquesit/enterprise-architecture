"""Shared loading helpers for the Azure service catalog tools (stdlib + PyYAML only)."""
from __future__ import annotations

import pathlib
from typing import Any

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = REPO_ROOT / "catalog"
SERVICES_DIR = CATALOG / "services"
SCHEMA_PATH = CATALOG / "schemas" / "service.schema.json"
COMPONENTS_PATH = CATALOG / "components.yaml"
MATRIX_PATH = CATALOG / "architecture-matrix.yaml"
TELEMETRY_PATH = CATALOG / "telemetry-capabilities.yaml"
GAPS_PATH = CATALOG / "provider-gaps.yaml"
PROFILES_DIR = REPO_ROOT / "environments" / "profiles"
COVERAGE_DIR = REPO_ROOT / "docs" / "coverage"

# Rendering order of the per-category files.
SERVICE_FILES = [
    "databases.yaml",
    "analytics-adjacent.yaml",
    "compute.yaml",
    "serverless.yaml",
    "messaging-platform.yaml",
    "partner-and-fabric.yaml",
    "specialized.yaml",
]


def load_yaml(path: pathlib.Path) -> Any:
    with path.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def load_service_files() -> dict[str, dict]:
    """Return {filename: parsed document} for every catalog/services/*.yaml (known order first)."""
    docs: dict[str, dict] = {}
    present = sorted(p.name for p in SERVICES_DIR.glob("*.yaml"))
    for name in SERVICE_FILES + [n for n in present if n not in SERVICE_FILES]:
        path = SERVICES_DIR / name
        if path.exists():
            docs[name] = load_yaml(path)
    return docs


def all_entries(docs: dict[str, dict]) -> list[tuple[str, dict]]:
    out = []
    for name, doc in docs.items():
        for svc in (doc or {}).get("services", []) or []:
            out.append((name, svc))
    return out


def load_components() -> list[dict]:
    return load_yaml(COMPONENTS_PATH).get("components", [])


def load_profiles() -> dict[str, set[str]]:
    profiles: dict[str, set[str]] = {}
    for path in sorted(PROFILES_DIR.glob("*.yaml")):
        doc = load_yaml(path) or {}
        profiles[doc.get("profile", path.stem)] = set(doc.get("components") or [])
    return profiles
