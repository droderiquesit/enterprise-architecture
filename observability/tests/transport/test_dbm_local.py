"""Local (docker) proof of modules/dbm: the SQL setup scripts run against real PostgreSQL 17 / MySQL 8.4,
and the Datadog Agent 7.84.2 runs the RENDERED postgres.d / mysql.d DBM configs (dbm: true) and the RENDERED ACI
datadog.yaml: API key and passwords are ENC[dsv://...] references resolved by dsv-fetch agent-backend (installed in
the Agent container exactly like the ACI start command) against a mock Delinea DSV - no literal password or key.
Auth to the mock uses DSV_AUTH=client_credentials (ACI uses the group's managed identity via IMDS).
Deviations from Azure (documented): no TLS on the local servers (ssl settings relaxed by this test) and
no Azure metadata endpoint. Requires docker and terraform (TERRAFORM_BIN to override).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time

import pytest
import yaml

from dockerutil import HERE, PACKAGE, PYTHON_IMAGE, REPO, Stack, wait_for

AGENT_IMAGE = "datadog/agent:7.84.2"
PG_IMAGE = os.environ.get("PG_IMAGE", "postgres:17-alpine")
MYSQL_IMAGE = os.environ.get("MYSQL_IMAGE", "mysql:8.4")
PW = "dbm-test-only-Pw-1"  # synthetic, local container only

pytestmark = pytest.mark.skipif(shutil.which("docker") is None, reason="docker not available")


def _render(expr: str):
    tf = os.environ.get("TERRAFORM_BIN", "terraform")
    mod = PACKAGE / "modules" / "dbm"
    subprocess.run([tf, "init", "-backend=false", "-input=false"], cwd=mod, check=True, capture_output=True)
    out = subprocess.run([tf, "console", f"-var-file={HERE / 'dbm' / 'databases.tfvars.json'}"], cwd=mod,
                         input=f"jsonencode({expr})", capture_output=True, text=True, check=True).stdout.strip()
    return json.loads(json.loads(out))


def _render_confd() -> dict:
    return _render("local.confd")


def _exec(c: str, *cmd: str, input_text: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["docker", "exec", "-i", c, *cmd], input=input_text, capture_output=True, text=True, timeout=300)


def test_dbm_setup_sql_and_agent_checks(tmp_path):
    confd = _render_confd()
    pg_conf = yaml.safe_load(confd["postgres.d"])
    my_conf = yaml.safe_load(confd["mysql.d"])
    # rendered config invariants (Azure shape)
    pgi, myi = pg_conf["instances"][0], my_conf["instances"][0]
    assert pgi["dbm"] is True and pgi["azure"]["deployment_type"] == "flexible_server" and pgi["password"] == "ENC[dsv://eh/test/dbm-pg-password#value]"
    assert myi["dbm"] is True and myi["password"] == "ENC[dsv://eh/test/dbm-mysql-password#value]"
    dd_yaml = yaml.safe_load(_render("local.aci_datadog_yaml"))
    assert dd_yaml["api_key"] == "ENC[dsv://eh/test/datadog-api-key#value]" and dd_yaml["secret_backend_command"] == "/opt/dsv-fetch/dsv-fetch"
    # local servers have no TLS: relax only here
    pgi["ssl"] = "disable"
    myi.pop("ssl", None)

    stack = Stack("dbm")
    try:
        sql = PACKAGE / "modules" / "dbm" / "sql"
        pg = stack.run("pg", PG_IMAGE, env={"POSTGRES_PASSWORD": "admin-test", "POSTGRES_DB": "catalog"},
                       volumes=[f"{sql}:/sql:ro"],
                       cmd=["postgres", "-c", "shared_preload_libraries=pg_stat_statements", "-c", "pg_stat_statements.track=all",
                            "-c", "track_activity_query_size=4096", "-c", "track_io_timing=on"])
        my = stack.run("mysql", MYSQL_IMAGE, env={"MYSQL_ROOT_PASSWORD": "admin-test", "MYSQL_DATABASE": "adapter"},
                       volumes=[f"{sql}:/sql:ro"], cmd=["--performance-schema=ON"])
        wait_for(lambda: _exec(pg, "pg_isready", "-U", "postgres").returncode == 0, 90, 2, "postgres")
        time.sleep(2)
        for _ in range(2):  # idempotency: run twice
            r = _exec(pg, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-v", f"dd_password={PW}", "-f", "/sql/postgres-flexible.sql")
            assert r.returncode == 0, r.stderr
            r = _exec(pg, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "catalog", "-f", "/sql/postgres-flexible-per-database.sql")
            assert r.returncode == 0, r.stderr
        wait_for(lambda: _exec(my, "mysqladmin", "-uroot", "-padmin-test", "ping").returncode == 0, 180, 3, "mysql")
        time.sleep(5)
        mysql_sql = (sql / "mysql-flexible.sql").read_text().replace("__DATADOG_PASSWORD__", PW)
        for _ in range(2):
            r = _exec(my, "mysql", "-uroot", "-padmin-test", input_text=mysql_sql)
            assert r.returncode == 0, r.stderr

        cfg = tmp_path / "agent"
        (cfg / "postgres").mkdir(parents=True)
        (cfg / "mysql").mkdir()
        (cfg / "secrets").mkdir()
        (cfg / "postgres" / "conf.yaml").write_text(yaml.safe_dump(pg_conf))
        (cfg / "mysql" / "conf.yaml").write_text(yaml.safe_dump(my_conf))
        # mock Delinea DSV on the stack network holding the API key + DB passwords
        dsv_cfg = {
            "clients": {"dbm-test": {"secret": "dbm-test-secret", "identity": "obs-dbm-test"}},
            "users": {"obs-dbm-test": {"read": ["eh/test/*"]}},
            "secrets": {"eh/test/datadog-api-key": {"value": "0" * 32}, "eh/test/dbm-pg-password": {"value": PW},
                        "eh/test/dbm-mysql-password": {"value": PW}},
        }
        (cfg / "dsvmock").mkdir()
        (cfg / "dsvmock" / "cfg.json").write_text(json.dumps(dsv_cfg))
        stack.run("dsv", PYTHON_IMAGE, volumes=[f"{REPO / 'tools' / 'secrets'}:/m:ro", f"{cfg / 'dsvmock'}:/c:ro"],
                  cmd=["python", "-u", "/m/mock_dsv.py", "--config", "/c/cfg.json", "--host", "0.0.0.0", "--port", "8200"])
        # the ACI container group's /eh/agent (rendered datadog.yaml) and /eh/dsv (dsv_fetch.py + dsv.json) volumes
        (cfg / "eh-agent").mkdir()
        (cfg / "eh-agent" / "datadog.yaml").write_text(yaml.safe_dump(dd_yaml))
        (cfg / "eh-dsv").mkdir()
        shutil.copy(PACKAGE / "images" / "dsv-fetch" / "dsv_fetch.py", cfg / "eh-dsv" / "dsv_fetch.py")
        (cfg / "eh-dsv" / "dsv.json").write_text(json.dumps({
            "DSV_AUTH": "client_credentials", "DSV_CLIENT_ID": "dbm-test", "DSV_CLIENT_SECRET": "dbm-test-secret",
            "DSV_BASE_URL": "http://dsv:8200/v1", "DSV_ALLOW_INSECURE_HTTP": "true"}))
        for p in cfg.rglob("*"):
            p.chmod(0o755 if p.is_dir() else 0o644)
        # same start sequence as modules/dbm azurerm_container_group.dbm (install backend 0500 root, copy config)
        start = ("python3 -I /eh/dsv/dsv_fetch.py install --dest /opt/dsv-fetch/dsv-fetch --python /opt/datadog-agent/embedded/bin/python3"
                 " && cp /eh/agent/datadog.yaml /etc/datadog-agent/datadog.yaml && exec /bin/entrypoint.sh")
        agent = stack.run(
            "agent", AGENT_IMAGE,
            env={"DD_API_KEY": "ENC[dsv://eh/test/datadog-api-key#value]", "DD_HOSTNAME": "dbm-test", "DD_SITE": "datadoghq.com",
                 "DD_LOGS_ENABLED": "false",
                 "DD_APM_ENABLED": "false", "DD_PROCESS_CONFIG_PROCESS_COLLECTION_ENABLED": "false"},
            volumes=[f"{cfg / 'postgres'}:/etc/datadog-agent/conf.d/postgres.d:ro",
                     f"{cfg / 'mysql'}:/etc/datadog-agent/conf.d/mysql.d:ro",
                     f"{cfg / 'eh-agent'}:/eh/agent:ro", f"{cfg / 'eh-dsv'}:/eh/dsv:ro"],
            entrypoint="/bin/sh", cmd=["-c", start],
        )
        time.sleep(20)
        sec = _exec(agent, "agent", "secret")
        print(sec.stdout[-2000:])
        assert "Executable permissions: OK" in sec.stdout, sec.stdout[-2000:]
        assert "Number of secrets resolved: 3" in sec.stdout or "Number of secrets decrypted: 3" in sec.stdout, sec.stdout[-2000:]
        pg_out = _exec(agent, "agent", "check", "postgres", "--json")
        my_out = _exec(agent, "agent", "check", "mysql", "--json")
        print(pg_out.stdout[-3000:], pg_out.stderr[-2000:])
        print(my_out.stdout[-3000:], my_out.stderr[-2000:])
        for out, engine in ((pg_out, "postgres"), (my_out, "mysql")):
            assert out.returncode == 0, out.stderr[-2000:]
            res = json.loads(out.stdout)[0]
            runner = res["runner"]
            assert runner["TotalErrors"] == 0 and runner["LastError"] == "", runner["LastError"]
            assert runner["MetricSamples"] > 20
            sc = {c["check"]: c["status"] for c in res["aggregator"]["service_checks"]}
            assert sc.get(f"{engine}.can_connect") == 0, sc  # 0 = OK
            # DBM is active (event-platform payloads such as metadata/samples)
            assert any("Database Monitoring" in k for k in runner.get("TotalEventPlatformEvents", {}) or {}), runner.get("TotalEventPlatformEvents")
        assert PW not in pg_out.stdout and PW not in my_out.stdout  # secret never echoed
    finally:
        stack.close()
