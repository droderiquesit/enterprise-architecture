import pytest

from hello_common.config import ConfigError, env_bool, env_choice, env_int, service_info


def test_service_info_env(monkeypatch):
    monkeypatch.setenv("DD_SERVICE", "a")
    monkeypatch.setenv("DB_SERVICE_NAME", "hello-dbadapter-mysql")
    monkeypatch.setenv("DD_VERSION", "2.0.0")
    monkeypatch.setenv("GIT_COMMIT", "abc")
    info = service_info("default", service_override_var="DB_SERVICE_NAME")
    assert info.service == "hello-dbadapter-mysql"
    doc = info.version_document()
    assert set(doc) == {"service", "version", "commit", "build_time", "runtime"}
    assert doc["commit"] == "abc" and doc["runtime"].startswith("python 3.13")


def test_env_parsers(monkeypatch):
    monkeypatch.setenv("X_INT", "5")
    assert env_int("X_INT", 1, maximum=10) == 5
    monkeypatch.setenv("X_INT", "50")
    with pytest.raises(ConfigError):
        env_int("X_INT", 1, maximum=10)
    monkeypatch.setenv("X_BOOL", "TRUE")
    assert env_bool("X_BOOL") is True
    monkeypatch.setenv("X_BOOL", "maybe")
    with pytest.raises(ConfigError):
        env_bool("X_BOOL")
    monkeypatch.setenv("X_CH", "Entra")
    assert env_choice("X_CH", "password", {"entra", "password"}) == "entra"
