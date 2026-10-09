"""Optional kind (Kubernetes-in-Docker) smoke of the hello-service chart with the locally built e2e images.

    HELLO_KIND_SMOKE=1 pytest tests/charts/test_kind_smoke.py -v      (HELLO_KIND_KEEP=1 keeps the cluster)

What it proves (beyond helm template/kubeconform): the chart installs on a real API server of the AKS minor version
(namespace with Pod Security `restricted` enforced), digest-pinned images start with the hardened securityContext
(read-only root FS, non-root, drop ALL), /healthz + /readyz + /version answer through `kubectl port-forward`,
hello-bff reaches hello-catalog-api through in-cluster DNS, and `helm upgrade` / `helm rollback` work per release.
Not covered (no Azure): workload identity webhook, Key Vault CSI driver, app routing, Datadog Agent/Fluent Bit.

Needs docker, kind, kubectl, helm and the local images hello-bff:0.1.0-e2e and hello-catalog-api:0.1.0-e2e
(tests/integration/build_images.sh); postgres:17-alpine and redis:7-alpine are pulled when missing. ~2.5 GB disk.
"""

from __future__ import annotations

import json
import os
import secrets
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from chartlib import CHART, HELM

HERE = Path(__file__).resolve().parent
CLUSTER = os.environ.get("HELLO_KIND_CLUSTER", "hello-charts-smoke")
CTX = f"kind-{CLUSTER}"
# kind v0.33.0 node image for the AKS minor (platform/compute/aks default kubernetes_version 1.36).
NODE_IMAGE = "kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
APP_IMAGES = {"hello-catalog-api": "hello-catalog-api:0.1.0-e2e", "hello-bff": "hello-bff:0.1.0-e2e"}
DEP_IMAGES = ["postgres:17-alpine", "redis:7-alpine"]
TOOLS = ["docker", "kind", "kubectl"]

pytestmark = pytest.mark.skipif(
    os.environ.get("HELLO_KIND_SMOKE") != "1" or not HELM or any(not shutil.which(t) for t in TOOLS),
    reason="kind smoke is opt-in: HELLO_KIND_SMOKE=1 with docker, kind, kubectl and helm installed")


def sh(*cmd: str, check: bool = True, input: str | None = None, timeout: int = 600) -> subprocess.CompletedProcess:
    res = subprocess.run(list(cmd), capture_output=True, text=True, input=input, timeout=timeout)
    if check and res.returncode != 0:
        raise AssertionError(f"{' '.join(cmd)}\n{res.stdout[-3000:]}\n{res.stderr[-3000:]}")
    return res


def kubectl(*args: str, **kw) -> subprocess.CompletedProcess:
    return sh("kubectl", "--context", CTX, *args, **kw)


def helm(*args: str, **kw) -> subprocess.CompletedProcess:
    return sh(HELM, "--kube-context", CTX, *args, **kw)


def node() -> str:
    return f"{CLUSTER}-control-plane"


def load_image(ref: str) -> None:
    """kind load; fall back to a single-platform `docker save | ctr import` (docker containerd image store)."""
    if sh("kind", "load", "docker-image", "--name", CLUSTER, ref, check=False).returncode == 0:
        return
    save = subprocess.Popen(["docker", "image", "save", "--platform", "linux/amd64", ref], stdout=subprocess.PIPE)
    imp = subprocess.run(["docker", "exec", "-i", node(), "ctr", "--namespace=k8s.io", "images", "import", "--digests",
                          "--snapshotter=overlayfs", "-"], stdin=save.stdout, capture_output=True, text=True, timeout=600)
    save.wait()
    assert imp.returncode == 0 and save.returncode == 0, imp.stderr


def pin_digest(ref: str) -> str:
    """Content digest of the imported image; tag it as <repo>@sha256:<digest> so a digest-pinned pod resolves locally."""
    full = f"docker.io/library/{ref}"
    info = json.loads(sh("docker", "exec", node(), "crictl", "inspecti", full).stdout)["status"]
    digest = info["repoDigests"][0].split("@", 1)[1]
    repo = full.rsplit(":", 1)[0]
    sh("docker", "exec", node(), "ctr", "-n", "k8s.io", "images", "tag", "--force", full, f"{repo}@{digest}")
    return digest


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class PortForward:
    def __init__(self, svc: str, ns: str = "hello"):
        self.port = free_port()
        self.proc = subprocess.Popen(["kubectl", "--context", CTX, "-n", ns, "port-forward", f"svc/{svc}", f"{self.port}:80"],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=1).close()
                return
            except OSError:
                time.sleep(0.5)
        raise AssertionError(f"port-forward to {svc} did not come up")

    def get(self, path: str, method: str = "GET", retries: int = 20) -> tuple[int, dict | list | str]:
        last = None
        for _ in range(retries):
            try:
                req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", method=method,
                                             data=b"" if method == "POST" else None)
                with urllib.request.urlopen(req, timeout=10) as r:  # noqa: S310 - http://127.0.0.1 port-forward
                    body = r.read().decode()
                    return r.status, (json.loads(body) if body.strip().startswith(("{", "[")) else body)
            except urllib.error.HTTPError as e:
                last = (e.code, e.read().decode())
                if e.code < 500:
                    return last
            except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
                last = (0, str(e))
            time.sleep(2)
        return last

    def close(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)


DEPS = """
apiVersion: v1
kind: Namespace
metadata: {name: deps}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: postgres, namespace: deps}
spec:
  selector: {matchLabels: {app: postgres}}
  template:
    metadata: {labels: {app: postgres}}
    spec:
      containers:
        - name: postgres
          image: docker.io/library/postgres:17-alpine
          imagePullPolicy: Never
          env:
            - {name: POSTGRES_DB, value: catalog}
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: pg, key: password}}
          ports: [{containerPort: 5432}]
          readinessProbe: {exec: {command: [pg_isready, -U, postgres]}, periodSeconds: 3}
---
apiVersion: v1
kind: Service
metadata: {name: postgres, namespace: deps}
spec: {selector: {app: postgres}, ports: [{port: 5432}]}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: redis, namespace: deps}
spec:
  selector: {matchLabels: {app: redis}}
  template:
    metadata: {labels: {app: redis}}
    spec:
      containers:
        - name: redis
          image: docker.io/library/redis:7-alpine
          imagePullPolicy: Never
          ports: [{containerPort: 6379}]
---
apiVersion: v1
kind: Service
metadata: {name: redis, namespace: deps}
spec: {selector: {app: redis}, ports: [{port: 6379}]}
"""


@pytest.fixture(scope="module")
def cluster():
    for ref in list(APP_IMAGES.values()):
        if sh("docker", "image", "inspect", ref, check=False).returncode != 0:
            pytest.skip(f"local image {ref} missing (tests/integration/build_images.sh)")
    for ref in DEP_IMAGES:
        if sh("docker", "image", "inspect", ref, check=False).returncode != 0:
            sh("docker", "pull", ref)
    if CLUSTER not in sh("kind", "get", "clusters").stdout.split():
        sh("kind", "create", "cluster", "--name", CLUSTER, "--image", NODE_IMAGE,
           "--config", str(HERE / "kind" / "cluster.yaml"), "--wait", "240s", timeout=900)
    try:
        for ref in [*APP_IMAGES.values(), *DEP_IMAGES]:
            load_image(ref)
        digests = {name: pin_digest(ref) for name, ref in APP_IMAGES.items()}
        password = secrets.token_urlsafe(18)
        kubectl("apply", "-f", "-", input=DEPS.split("---", 1)[0])
        kubectl("-n", "deps", "create", "secret", "generic", "pg", f"--from-literal=password={password}")
        kubectl("apply", "-f", "-", input=DEPS)
        kubectl("-n", "deps", "rollout", "status", "deployment/postgres", "deployment/redis", "--timeout=180s")
        # Same namespace shape as AKS: Pod Security `restricted` enforced.
        kubectl("create", "namespace", "hello")
        kubectl("label", "namespace", "hello", "pod-security.kubernetes.io/enforce=restricted",
                "app.kubernetes.io/part-of=enterprise-hello")
        kubectl("-n", "hello", "create", "secret", "generic", "catalog-db", f"--from-literal=password={password}")
        yield digests
    finally:
        if os.environ.get("HELLO_KIND_KEEP") != "1":
            sh("kind", "delete", "cluster", "--name", CLUSTER, check=False)


def install(release: str, digest: str, *extra: str) -> None:
    helm("upgrade", "--install", release, str(CHART), "-n", "hello", "-f", str(CHART / "examples" / f"kind-{release.removeprefix('hello-')}.yaml"),
         "--set", f"image.digest={digest}", "--rollback-on-failure", "--wait", "--timeout", "5m", *extra, timeout=420)


def test_install_probe_upgrade_rollback(cluster):
    install("hello-catalog-api", cluster["hello-catalog-api"])
    install("hello-bff", cluster["hello-bff"])

    pods = json.loads(kubectl("-n", "hello", "get", "pods", "-o", "json").stdout)["items"]
    assert {p["metadata"]["labels"]["app.kubernetes.io/name"] for p in pods} == {"hello-bff", "hello-catalog-api"}
    for p in pods:
        assert all(cs["ready"] for cs in p["status"]["containerStatuses"]), p["metadata"]["name"]
        assert p["spec"]["containers"][0]["image"].split("@")[1] == cluster[p["metadata"]["labels"]["app.kubernetes.io/name"]]
        assert p["metadata"]["labels"]["tags.datadoghq.com/env"] == "kind"

    cat, bff = PortForward("hello-catalog-api"), PortForward("hello-bff")
    try:
        for pf, name in ((cat, "hello-catalog-api"), (bff, "hello-bff")):
            assert pf.get("/healthz")[0] == 200
            status, body = pf.get("/readyz")
            assert status == 200, body
            status, body = pf.get("/version")
            assert status == 200 and body["service"] == name and body["version"] == "0.1.0-e2e", body
        assert cat.get("/seed", method="POST")[0] in (200, 201)
        status, body = bff.get("/api/catalog/products")   # BFF -> catalog through in-cluster DNS
        assert status == 200 and len(body if isinstance(body, list) else body.get("items", body.get("products", []))) >= 20, body
    finally:
        cat.close()
        bff.close()

    # Independent per-release upgrade + rollback.
    install("hello-bff", cluster["hello-bff"], "--set", "service.version=0.1.0-e2e-r2")
    hist = json.loads(helm("-n", "hello", "history", "hello-bff", "-o", "json").stdout)
    assert [h["revision"] for h in hist][-1] == 2
    helm("-n", "hello", "rollback", "hello-bff", "1", "--wait", "--timeout", "5m", timeout=420)
    dep = json.loads(kubectl("-n", "hello", "get", "deployment", "hello-bff", "-o", "json").stdout)
    assert dep["metadata"]["labels"]["tags.datadoghq.com/version"] == "0.1.0-e2e"
    assert json.loads(helm("-n", "hello", "history", "hello-catalog-api", "-o", "json").stdout)[-1]["revision"] == 1


def test_restricted_pod_security_rejects_root(cluster, tmp_path):
    """Sanity: the namespace really enforces `restricted` (a privileged pod is refused by admission)."""
    res = kubectl("-n", "hello", "run", "root-probe", "--image=docker.io/library/redis:7-alpine", "--image-pull-policy=Never",
                  "--restart=Never", "--overrides",
                  json.dumps({"spec": {"containers": [{"name": "root-probe", "image": "docker.io/library/redis:7-alpine",
                                                         "securityContext": {"privileged": True}}]}}), check=False)
    assert res.returncode != 0 and "violates PodSecurity" in res.stderr, res.stderr
