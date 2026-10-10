"""tools/validate/versions.py: versions.yaml images.datadog_agent / datadog_serverless_init equal the fleet policy pins."""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from tools.validate.versions import FLEET_POLICY, check_fleet_pins  # noqa: E402


def test_repository_pins_agree():
    images = yaml.safe_load((REPO / "versions.yaml").read_text())["images"]
    assert check_fleet_pins(REPO, images) == []
    agent = yaml.safe_load((REPO / FLEET_POLICY).read_text())["agent"]
    assert images["datadog_agent"] == f"{agent['image']}:{agent['version']}"
    assert images["datadog_serverless_init"] == f"{agent['serverless_init']['image']}:{agent['serverless_init']['version']}"


def test_mismatch_is_reported(tmp_path):
    (tmp_path / FLEET_POLICY).parent.mkdir(parents=True)
    (tmp_path / FLEET_POLICY).write_text(yaml.safe_dump({"agent": {"image": "gcr.io/datadoghq/agent", "version": "7.84.2",
                                                                    "serverless_init": {"image": "datadog/serverless-init", "version": "1.10.4"}}}))
    errs = check_fleet_pins(tmp_path, {"datadog_agent": "gcr.io/datadoghq/agent:7.83.0", "datadog_serverless_init": "datadog/serverless-init:1.10.4"})
    assert len(errs) == 1 and "images.datadog_agent" in errs[0]
    errs = check_fleet_pins(tmp_path, {"datadog_agent": "gcr.io/datadoghq/agent:7.84.2"})
    assert len(errs) == 1 and "datadog_serverless_init" in errs[0]
