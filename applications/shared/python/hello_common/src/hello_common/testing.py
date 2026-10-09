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
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)
