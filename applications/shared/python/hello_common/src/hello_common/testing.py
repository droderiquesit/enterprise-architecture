"""Test utilities: throwaway docker containers for `integration`-marked tests (docker CLI only)."""

from __future__ import annotations

import contextlib
import shutil
import subprocess
import time
import uuid
from collections.abc import Callable, Iterator
from dataclasses import dataclass


class DockerUnavailable(RuntimeError):
    pass


@dataclass
class Container:
    name: str
    image: str
    host: str
    ports: dict[int, int]

    def port(self, container_port: int) -> int:
        return self.ports[container_port]

    def exec(self, *cmd: str, timeout: int = 60) -> subprocess.CompletedProcess:
        return subprocess.run(["docker", "exec", self.name, *cmd], capture_output=True, text=True, timeout=timeout)

    def logs(self) -> str:
        return subprocess.run(["docker", "logs", "--tail", "50", self.name], capture_output=True, text=True).stdout


def docker_available() -> bool:
    if shutil.which("docker") is None:
        return False
    return subprocess.run(["docker", "info"], capture_output=True).returncode == 0


@contextlib.contextmanager
def run_container(
    image: str,
    ports: list[int],
    *,
    env: dict[str, str] | None = None,
    command: list[str] | None = None,
    ready: Callable[[Container], bool] | None = None,
    timeout: float = 90.0,
    name_prefix: str = "hello-it",
    extra_args: list[str] | None = None,
) -> Iterator[Container]:
    if not docker_available():
        raise DockerUnavailable("docker daemon not available")
    name = f"{name_prefix}-{uuid.uuid4().hex[:8]}"
    args = ["docker", "run", "-d", "--rm", "--name", name]
    for p in ports:
        args += ["-p", f"127.0.0.1::{p}"]
    for k, v in (env or {}).items():
        args += ["-e", f"{k}={v}"]
    args += extra_args or []
    args.append(image)
    args += command or []
    subprocess.run(args, check=True, capture_output=True, text=True, timeout=600)
    try:
        mapped: dict[int, int] = {}
        for p in ports:
            out = subprocess.run(["docker", "port", name, str(p)], check=True, capture_output=True, text=True).stdout
            mapped[p] = int(out.strip().splitlines()[0].rsplit(":", 1)[1])
        container = Container(name=name, image=image, host="127.0.0.1", ports=mapped)
        deadline = time.monotonic() + timeout
        last_error: Exception | None = None
        while ready is not None:
            try:
                if ready(container):
                    break
            except Exception as exc:  # keep polling until timeout
                last_error = exc
            if time.monotonic() > deadline:
                raise TimeoutError(f"{image} not ready after {timeout}s: {last_error}\n{container.logs()}")
            time.sleep(1.0)
        yield container
    finally:
        subprocess.run(["docker", "rm", "-f", "-v", name], capture_output=True)


SB_EMULATOR_IMAGE = "mcr.microsoft.com/azure-messaging/servicebus-emulator:latest"
MSSQL_IMAGE = "mcr.microsoft.com/mssql/server:2022-latest"


def servicebus_emulator_config(topics: dict[str, list[str]] | None = None, queues: list[str] | None = None) -> dict:
    sub_props = {"DeadLetteringOnMessageExpiration": False, "DefaultMessageTimeToLive": "PT1H", "LockDuration": "PT1M",
                 "MaxDeliveryCount": 10, "ForwardDeadLetteredMessagesTo": "", "ForwardTo": "", "RequiresSession": False}
    return {
        "UserConfig": {
            "Namespaces": [{
                "Name": "sbemulatorns",
                "Queues": [{"Name": q, "Properties": {**sub_props, "DuplicateDetectionHistoryTimeWindow": "PT20S", "MaxSizeInMegabytes": 256,
                                                       "RequiresDuplicateDetection": False}} for q in (queues or [])],
                "Topics": [{
                    "Name": t,
                    "Properties": {"DefaultMessageTimeToLive": "PT1H", "DuplicateDetectionHistoryTimeWindow": "PT20S", "RequiresDuplicateDetection": False},
                    "Subscriptions": [{"Name": s, "Properties": sub_props, "Rules": []} for s in subs],
                } for t, subs in (topics or {}).items()],
            }],
            "Logging": {"Type": "File"},
        }
    }


@contextlib.contextmanager
def servicebus_emulator(config: dict, timeout: float = 240.0) -> Iterator[str]:
    """Start SQL Server + the official Service Bus emulator on a private docker network.
    Yields an emulator connection string reachable from the host."""
    import json
    import os
    import tempfile

    if not docker_available():
        raise DockerUnavailable("docker daemon not available")
    net = f"hello-sbe-{uuid.uuid4().hex[:8]}"
    sa = "Local0nly!SbEmu"
    subprocess.run(["docker", "network", "create", net], check=True, capture_output=True)
    cfg_dir = tempfile.mkdtemp(prefix="sbe-")
    cfg = os.path.join(cfg_dir, "Config.json")
    with open(cfg, "w") as fh:
        json.dump(config, fh)
    os.chmod(cfg_dir, 0o755)
    os.chmod(cfg, 0o644)
    sql_name = f"sbe-sql-{uuid.uuid4().hex[:6]}"
    try:
        with run_container(MSSQL_IMAGE, [], env={"ACCEPT_EULA": "Y", "MSSQL_SA_PASSWORD": sa}, extra_args=["--network", net, "--network-alias", sql_name],
                           ready=lambda c: c.exec("/opt/mssql-tools18/bin/sqlcmd", "-S", "localhost", "-U", "sa", "-P", sa, "-C", "-Q", "SELECT 1").returncode == 0,
                           timeout=timeout, name_prefix="sbe-sql"):
            with run_container(SB_EMULATOR_IMAGE, [5672], env={"ACCEPT_EULA": "Y", "SQL_SERVER": sql_name, "MSSQL_SA_PASSWORD": sa},
                               extra_args=["--network", net, "-v", f"{cfg}:/ServiceBus_Emulator/ConfigFiles/Config.json:ro"],
                               ready=lambda c: "Emulator Service is Successfully Up" in subprocess.run(["docker", "logs", c.name], capture_output=True, text=True).stdout,
                               timeout=timeout, name_prefix="sbe") as emu:
                yield (f"Endpoint=sb://{emu.host}:{emu.port(5672)};SharedAccessKeyName=RootManageSharedAccessKey;"
                       "SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;")
    finally:
        subprocess.run(["docker", "network", "rm", net], capture_output=True)
