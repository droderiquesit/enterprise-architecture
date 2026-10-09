"""send_deployment_event.py: payload shape (DORA API), time conversion, retries, exit codes (no network)."""
import io
import json
import urllib.error

import send_deployment_event as sde


def test_time_conversion():
    assert sde.to_ns("1693491974") == 1693491974000000000
    assert sde.to_ns("1693491974000") == 1693491974000000000
    assert sde.to_ns("1693491974000000000") == 1693491974000000000
    assert sde.to_ns("2023-08-31T14:26:14Z") == 1693491974000000000


def test_dry_run_payload(capsys):
    rc = sde.main(["--service", "api", "--env", "prod", "--version", "1.2.3", "--commit-sha", "abc",
                   "--repository-url", "https://example.com/r.git", "--team", "shop",
                   "--started-at", "1693491974", "--finished-at", "1693491984", "--tag", "app_type:backend", "--dry-run"])
    assert rc == 0
    body = json.loads(capsys.readouterr().out)
    a = body["data"]["attributes"]
    assert a == {"service": "api", "env": "prod", "version": "1.2.3", "started_at": 1693491974000000000,
                 "finished_at": 1693491984000000000, "git": {"commit_sha": "abc", "repository_url": "https://example.com/r.git"},
                 "team": "shop", "custom_tags": ["app_type:backend"]}


def test_empty_team_ignored(capsys):
    assert sde.main(["--service", "a", "--env", "e", "--version", "1", "--team", "", "--dry-run"]) == 0
    assert "team" not in json.loads(capsys.readouterr().out)["data"]["attributes"]


def test_usage_errors(monkeypatch):
    monkeypatch.delenv("DD_API_KEY", raising=False)
    assert sde.main(["--service", "a", "--env", "e", "--version", "1"]) == 2
    assert sde.main(["--service", "a", "--env", "e", "--version", "1", "--site", "evil.example.com", "--dry-run"]) == 2
    assert sde.main(["--service", "a", "--env", "e", "--version", "1", "--commit-sha", "x", "--dry-run"]) == 2


class FakeResp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_send_retries_then_succeeds(monkeypatch):
    calls = []

    def opener(req, timeout):
        calls.append(req)
        assert req.full_url == "https://api.datadoghq.eu/api/v2/dora/deployment"
        assert req.get_header("Dd-api-key") == "k"
        if len(calls) == 1:
            raise urllib.error.HTTPError(req.full_url, 503, "busy", {}, None)
        return FakeResp(b'{"data":{"id":"x","type":"dora_deployment"}}')

    resp = sde.send("datadoghq.eu", "k", {"data": {}}, opener=opener, sleep=lambda s: None)
    assert resp["data"]["id"] == "x" and len(calls) == 2


def test_send_does_not_retry_client_error():
    calls = []

    def opener(req, timeout):
        calls.append(1)
        raise urllib.error.HTTPError(req.full_url, 400, "bad", {}, None)

    try:
        sde.send("datadoghq.com", "k", {}, opener=opener, sleep=lambda s: None)
    except RuntimeError as exc:
        assert "400" in str(exc)
    assert len(calls) == 1
