"""Local (docker) proof of modules/dbm: the SQL setup scripts run against real PostgreSQL 17 / MySQL 8.4,
and the Datadog Agent 7.84.2 runs the RENDERED postgres.d / mysql.d DBM configs (dbm: true) with the
password resolved through ENC[file@...] (readsecret_multiple_providers.sh) - no literal password.
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

from dockerutil import HERE, PACKAGE, Stack, wait_for

AGENT_IMAGE = "datadog/agent:7.84.2"
PG_IMAGE = os.environ.get("PG_IMAGE", "postgres:17-alpine")
MYSQL_IMAGE = "mysql:8.4"
PW = "dbm-test-only-Pw-1"  # synthetic, local container only

pytestmark = pytest.mark.skipif(shutil.which("docker") is None, reason="docker not available")


def _render_confd() -> dict:
    tf = os.environ.get("TERRAFORM_BIN", "terraform")
    mod = PACKAGE / "modules" / "dbm"
    subprocess.run([tf, "init", "-backend=false", "-input=false"], cwd=mod, check=True, capture_output=True)
    out = subprocess.run([tf, "console", f"-var-file={HERE / 'dbm' / 'databases.tfvars.json'}"], cwd=mod,
                         input="jsonencode(local.confd)", capture_output=True, text=True, check=True).stdout.strip()
    return json.loads(json.loads(out))


def _exec(c: str, *cmd: str, input_text: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["docker", "exec", "-i", c, *cmd], input=input_text, capture_output=True, text=True, timeout=300)


def test_dbm_setup_sql_and_agent_checks(tmp_path):
    confd = _render_confd()
    pg_conf = yaml.safe_load(confd["postgres.d"])
    my_conf = yaml.safe_load(confd["mysql.d"])
    # rendered config invariants (Azure shape)
    pgi, myi = pg_conf["instances"][0], my_conf["instances"][0]
    assert pgi["dbm"] is True and pgi["azure"]["deployment_type"] == "flexible_server" and pgi["password"].startswith("ENC[")
    assert myi["dbm"] is True and myi["password"] == "ENC[file@/etc/datadog-agent/secrets/mysql-password]"
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
        (cfg / "secrets" / "pg-password").write_text(PW)
        (cfg / "secrets" / "mysql-password").write_text(PW)
        for p in cfg.rglob("*"):
            p.chmod(0o755 if p.is_dir() else 0o644)
        agent = stack.run(
            "agent", AGENT_IMAGE,
            env={"DD_API_KEY": "0" * 32, "DD_HOSTNAME": "dbm-test", "DD_SITE": "datadoghq.com",
                 "DD_SECRET_BACKEND_COMMAND": "/readsecret_multiple_providers.sh", "DD_LOGS_ENABLED": "false",
                 "DD_APM_ENABLED": "false", "DD_PROCESS_CONFIG_PROCESS_COLLECTION_ENABLED": "false"},
            volumes=[f"{cfg / 'postgres'}:/etc/datadog-agent/conf.d/postgres.d:ro",
                     f"{cfg / 'mysql'}:/etc/datadog-agent/conf.d/mysql.d:ro",
                     f"{cfg / 'secrets'}:/etc/datadog-agent/secrets:ro"],
        )
        time.sleep(20)
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
