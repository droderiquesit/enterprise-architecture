"""hello-service chart: lint, schema, rendering assertions and kubeconform against the AKS Kubernetes version.

    pytest tests/charts -q
"""

from __future__ import annotations

import copy
import json
import re
import subprocess
import tarfile

import jsonschema
import pytest
import yaml

from chartlib import CHART, HELM3, KUBECONFORM, aks_kubernetes_version, by_kind, example_files, helm_binaries, load_values, render, run, template

EXAMPLES = example_files()
IDS = [p.stem for p in EXAMPLES]
SECRETISH = re.compile(r"(PASSWORD|SECRET|TOKEN|API_KEY|ACCESS_KEY|PRIVATE_KEY)$")
CRD_SCHEMAS = "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"


def workloads(docs):
    return by_kind(docs, "Deployment") + by_kind(docs, "CronJob")


def pod_template(w):
    return w["spec"]["template"] if w["kind"] == "Deployment" else w["spec"]["jobTemplate"]["spec"]["template"]


# ------------------------------------------------------------------------------------------------ lint / schema
def test_examples_cover_every_core_aks_workload():
    stems = set(IDS)
    assert {"aks-bff", "aks-orders-api", "aks-catalog-api", "aks-worker", "aro-catalog-api", "aks-jobs-cronjob"} <= stems


@pytest.mark.parametrize("helm", helm_binaries() or [None], ids=lambda h: (h or "none").rsplit("/", 1)[-1])
@pytest.mark.parametrize("values", EXAMPLES, ids=IDS)
def test_helm_lint_strict(helm, values):
    if not helm:
        pytest.skip("helm not installed")
    res = run([helm, "lint", "--strict", str(CHART), "-n", "hello", "-f", str(values)])
    assert res.returncode == 0, res.stdout + res.stderr


@pytest.mark.parametrize("values", EXAMPLES, ids=IDS)
def test_examples_valid_against_values_schema(values, schema):
    merged = yaml.safe_load((CHART / "values.yaml").read_text())

    def deep(a, b):
        for k, v in b.items():
            a[k] = deep(a.get(k, {}), v) if isinstance(v, dict) and isinstance(a.get(k), dict) else v
        return a
    jsonschema.Draft7Validator(schema).validate(deep(merged, load_values(values)))


@pytest.mark.skipif(not HELM3, reason="helm3 (Helm v3 CLI, the engine of the Terraform helm provider) not installed")
@pytest.mark.parametrize("values", EXAMPLES, ids=IDS)
def test_helm3_and_helm4_render_identically(values, helm_bin):
    assert render(values, helm=HELM3) == render(values, helm=helm_bin)


# ------------------------------------------------------------------------------------------------ kubeconform
@pytest.mark.parametrize("values", EXAMPLES, ids=IDS)
def test_kubeconform_strict(values, helm_bin, kubeconform_cache):
    if not KUBECONFORM:
        pytest.skip("kubeconform not installed")
    res = template(values)
    assert res.returncode == 0, res.stderr
    kc = subprocess.run(
        [KUBECONFORM, "-strict", "-summary", "-output", "json", "-kubernetes-version", aks_kubernetes_version(),
         "-cache", str(kubeconform_cache), "-schema-location", "default", "-schema-location", CRD_SCHEMAS,
         # No public JSON schema for route.openshift.io/v1 Route: asserted structurally in test_aro_*.
         "-skip", "Route"],
        input=res.stdout, capture_output=True, text=True)
    out = json.loads(kc.stdout or "{}")
    errors = [r for r in out.get("resources", []) if r.get("status") in ("statusError",)]
    if errors and all("could not find schema" in r.get("msg", "") or "dial tcp" in r.get("msg", "")
                      or "no such host" in r.get("msg", "") for r in errors):
        pytest.skip(f"kubeconform schemas unavailable (offline?): {errors[0]['msg'][:160]}")
    assert kc.returncode == 0, kc.stdout + kc.stderr
    assert out["summary"]["invalid"] == 0 and out["summary"]["errors"] == 0


def test_kubeconform_ingress_and_networkpolicy(helm_bin, kubeconform_cache, tmp_path):
    if not KUBECONFORM:
        pytest.skip("kubeconform not installed")
    v = load_values(CHART / "examples" / "aks-bff.yaml")
    v["ingress"].update({"enabled": True, "host": "api.hello.example.com"})
    v["networkPolicy"] = {"enabled": True, "allowFromNamespaces": ["app-routing-system"], "allowFromCIDRs": ["10.20.0.0/16"]}
    res = template(v, tmp=tmp_path)
    assert res.returncode == 0, res.stderr
    kc = subprocess.run([KUBECONFORM, "-strict", "-summary", "-kubernetes-version", aks_kubernetes_version(), "-cache",
                         str(kubeconform_cache), "-schema-location", "default", "-schema-location", CRD_SCHEMAS],
                        input=res.stdout, capture_output=True, text=True)
    if "could not find schema" in kc.stdout and "dial tcp" in kc.stdout:
        pytest.skip("kubeconform schemas unavailable (offline?)")
    assert kc.returncode == 0, kc.stdout + kc.stderr


# ------------------------------------------------------------------------------------------------ rendered manifests
@pytest.mark.parametrize("values", EXAMPLES, ids=IDS)
def test_security_context_hardened(values, helm_bin):
    docs = render(values)
    v = load_values(values)
    for w in workloads(docs):
        spec = pod_template(w)["spec"]
        assert spec["securityContext"]["runAsNonRoot"] is True
        assert spec["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
        assert spec["enableServiceLinks"] is False
        assert spec["automountServiceAccountToken"] is v["identity"].get("workloadIdentity", True)
        assert len(spec["containers"]) == 1, "no sidecars: logs go through the Fluent Bit DaemonSet"
        c = spec["containers"][0]
        sc = c["securityContext"]
        assert sc["allowPrivilegeEscalation"] is False and sc["readOnlyRootFilesystem"] is True
        assert sc["capabilities"]["drop"] == ["ALL"] and sc["runAsNonRoot"] is True
        assert {"name": "tmp", "mountPath": "/tmp"} in c["volumeMounts"]
        assert c["resources"]["requests"]["cpu"] and c["resources"]["requests"]["memory"] and c["resources"]["limits"]["memory"]


@pytest.mark.parametrize("values", EXAMPLES, ids=IDS)
def test_images_digest_pinned(values, helm_bin):
    for w in workloads(render(values)):
        for c in pod_template(w)["spec"]["containers"]:
            assert re.fullmatch(r"[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+@sha256:[a-f0-9]{64}", c["image"]), c["image"]


@pytest.mark.parametrize("values", EXAMPLES, ids=IDS)
def test_probes(values, helm_bin):
    v = load_values(values)
    for w in workloads(render(values)):
        c = pod_template(w)["spec"]["containers"][0]
        if v["kind"] == "cronjob":
            assert not any(k in c for k in ("livenessProbe", "readinessProbe", "startupProbe", "ports"))
            continue
        port = "health" if v["kind"] == "worker" else "http"
        assert c["ports"] == [{"name": port, "containerPort": v.get("port", 8080), "protocol": "TCP"}]
        assert c["livenessProbe"]["httpGet"] == {"path": "/healthz", "port": port}
        assert c["readinessProbe"]["httpGet"] == {"path": "/readyz", "port": port}
        assert c["startupProbe"]["httpGet"]["path"] == "/healthz"


@pytest.mark.parametrize("values", EXAMPLES, ids=IDS)
def test_workload_identity(values, helm_bin):
    v = load_values(values)
    docs = render(values)
    sa = by_kind(docs, "ServiceAccount")[0]
    pod_labels = pod_template(workloads(docs)[0])["metadata"]["labels"]
    env = {e["name"]: e for e in pod_template(workloads(docs)[0])["spec"]["containers"][0]["env"]}
    assert env["AZURE_CLIENT_ID"]["value"] == v["identity"]["clientId"]
    assert sa["automountServiceAccountToken"] is False
    if v["identity"].get("workloadIdentity", True):
        assert sa["metadata"]["annotations"]["azure.workload.identity/client-id"] == v["identity"]["clientId"]
        assert pod_labels["azure.workload.identity/use"] == "true"
    else:
        assert "azure.workload.identity/use" not in pod_labels
        assert "azure.workload.identity/client-id" not in (sa["metadata"].get("annotations") or {})


@pytest.mark.parametrize("values", EXAMPLES, ids=IDS)
def test_unified_service_tagging_and_env(values, helm_bin):
    v = load_values(values)
    docs = render(values)
    expected = {"tags.datadoghq.com/env": v["service"]["env"], "tags.datadoghq.com/service": v["service"]["name"],
                "tags.datadoghq.com/version": v["service"]["version"]}
    for w in workloads(docs):
        for labels in (w["metadata"]["labels"], pod_template(w)["metadata"]["labels"]):
            assert expected.items() <= labels.items()
            assert labels["app.kubernetes.io/version"] == v["service"]["version"]
        env = pod_template(w)["spec"]["containers"][0]["env"]
        names = [e["name"] for e in env]
        assert env[0] == {"name": "DD_AGENT_HOST", "valueFrom": {"fieldRef": {"fieldPath": "status.hostIP"}}}
        assert len(names) == len(set(names)), "duplicate env names"
        e = {x["name"]: x.get("value") for x in env}
        assert (e["DD_ENV"], e["DD_SERVICE"], e["DD_VERSION"]) == (v["service"]["env"], v["service"]["name"], v["service"]["version"])
        assert e["FAULTS_ENABLED"] == "false"
        # $(DD_AGENT_HOST) references only resolve for variables defined earlier
        for i, x in enumerate(env):
            if "$(DD_AGENT_HOST)" in (x.get("value") or ""):
                assert i > 0
        ann = pod_template(w)["metadata"]["annotations"]
        assert ann[f"ad.datadoghq.com/{w['metadata']['name']}.logs"] == "[]"
    for d in docs:   # every object carries the tags (Datadog Agent / Fluent Bit enrichment, cost views)
        assert expected.items() <= d["metadata"]["labels"].items(), d["kind"]


@pytest.mark.parametrize("values", EXAMPLES, ids=IDS)
def test_no_plaintext_secrets(values, helm_bin):
    docs = render(values)
    assert not by_kind(docs, "Secret"), "the chart never creates Secret objects"
    for w in workloads(docs):
        for e in pod_template(w)["spec"]["containers"][0]["env"]:
            if SECRETISH.search(e["name"]):
                assert "value" not in e and "secretKeyRef" in e["valueFrom"], e
    for spc in by_kind(docs, "SecretProviderClass"):
        objs = yaml.safe_load(spc["spec"]["parameters"]["objects"])["array"]
        for raw in objs:
            o = yaml.safe_load(raw)
            assert o["objectType"] == "secret" and re.fullmatch(r"[A-Za-z0-9-]+", o["objectName"])
        assert spc["spec"]["parameters"]["usePodIdentity"] == "false"


@pytest.mark.parametrize("values", EXAMPLES, ids=IDS)
def test_hpa_pdb_service(values, helm_bin):
    v = load_values(values)
    docs = render(values)
    hpa, pdb, svc = by_kind(docs, "HorizontalPodAutoscaler"), by_kind(docs, "PodDisruptionBudget"), by_kind(docs, "Service")
    dep = by_kind(docs, "Deployment")
    if v["kind"] == "cronjob":
        assert not (hpa or pdb or svc or dep)
        return
    assert pdb and pdb[0]["spec"]["maxUnavailable"] == 1, "PDB for every long-running workload"
    if v.get("autoscaling", {}).get("enabled", True):
        assert hpa[0]["spec"]["maxReplicas"] <= 20 and hpa[0]["spec"]["maxReplicas"] == v["autoscaling"]["maxReplicas"]
        assert hpa[0]["spec"]["minReplicas"] <= hpa[0]["spec"]["maxReplicas"]
        assert "replicas" not in dep[0]["spec"], "HPA owns spec.replicas"
    else:
        assert not hpa and dep[0]["spec"]["replicas"] == v["replicas"]
    if v["kind"] == "worker":
        assert not svc and not by_kind(docs, "Ingress")
    else:
        assert svc[0]["spec"]["ports"][0]["targetPort"] == "http"
        assert svc[0]["spec"]["selector"] == {"app.kubernetes.io/name": v["service"]["name"]}


def test_bff_internal_lb_and_kv(helm_bin):
    docs = render(CHART / "examples" / "aks-bff.yaml")
    svc = by_kind(docs, "Service")[0]
    assert svc["spec"]["type"] == "LoadBalancer"
    assert svc["metadata"]["annotations"]["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
    spc = by_kind(docs, "SecretProviderClass")[0]
    assert spc["metadata"]["name"] == "hello-bff-kv" and spc["spec"]["secretObjects"][0]["secretName"] == "hello-bff-kv"
    pod = by_kind(docs, "Deployment")[0]["spec"]["template"]["spec"]
    assert {"name": "kv-secrets", "csi": {"driver": "secrets-store.csi.k8s.io", "readOnly": True,
                                          "volumeAttributes": {"secretProviderClass": "hello-bff-kv"}}} in pod["volumes"]


def test_worker_has_no_keyvault(helm_bin):
    docs = render(CHART / "examples" / "aks-worker.yaml")
    assert not by_kind(docs, "SecretProviderClass") and not by_kind(docs, "Service")


def test_ingress_app_routing(helm_bin, tmp_path):
    v = load_values(CHART / "examples" / "aks-bff.yaml")
    v["k8sService"] = {"type": "ClusterIP", "port": 80, "internalLoadBalancer": False}
    v["ingress"].update({"enabled": True, "host": "api.hello.example.com",
                         "tls": {"enabled": True, "secretName": "keyvault-hello-bff-tls",
                                 "keyVaultCertificateUri": "https://kv1.vault.azure.net/certificates/hello-api"}})
    ing = by_kind(render(v, tmp=tmp_path), "Ingress")[0]
    assert ing["spec"]["ingressClassName"] == "webapprouting.kubernetes.azure.com"
    assert ing["metadata"]["annotations"]["kubernetes.azure.com/tls-cert-keyvault-uri"].endswith("/certificates/hello-api")
    assert ing["spec"]["tls"][0] == {"hosts": ["api.hello.example.com"], "secretName": "keyvault-hello-bff-tls"}
    assert ing["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"] == {"name": "hello-bff", "port": {"name": "http"}}


def test_network_policy(helm_bin, tmp_path):
    v = load_values(CHART / "examples" / "aks-bff.yaml")
    v["networkPolicy"] = {"enabled": True, "allowFromNamespaces": ["app-routing-system"], "allowFromCIDRs": ["10.20.0.0/16"]}
    np_ = by_kind(render(v, tmp=tmp_path), "NetworkPolicy")[0]
    assert np_["spec"]["policyTypes"] == ["Ingress"]
    frm = np_["spec"]["ingress"][0]["from"]
    assert {"podSelector": {}} in frm and {"ipBlock": {"cidr": "10.20.0.0/16"}} in frm
    assert np_["spec"]["ingress"][0]["ports"] == [{"port": "http", "protocol": "TCP"}]


def test_aro_route_and_scc(helm_bin, tmp_path):
    v = load_values(CHART / "examples" / "aro-catalog-api.yaml")
    v["podSecurityContext"] = {"runAsNonRoot": True, "runAsUser": 10001, "fsGroup": 10001, "seccompProfile": {"type": "RuntimeDefault"}}
    docs = render(v, tmp=tmp_path)
    route = by_kind(docs, "Route")[0]
    assert route["apiVersion"] == "route.openshift.io/v1"
    assert route["spec"]["to"] == {"kind": "Service", "name": "hello-catalog-api", "weight": 100}
    assert route["spec"]["tls"] == {"termination": "edge", "insecureEdgeTerminationPolicy": "Redirect"}
    assert not by_kind(docs, "Ingress") and not by_kind(docs, "SecretProviderClass")
    psc = by_kind(docs, "Deployment")[0]["spec"]["template"]["spec"]["securityContext"]
    assert "runAsUser" not in psc and "fsGroup" not in psc, "OpenShift SCC assigns the UID"
    env = {e["name"]: e for e in by_kind(docs, "Deployment")[0]["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["PG_PASSWORD"]["valueFrom"]["secretKeyRef"] == {"name": "hello-catalog-api-db", "key": "password"}


def test_cronjob_shape(helm_bin):
    cj = by_kind(render(CHART / "examples" / "aks-jobs-cronjob.yaml"), "CronJob")[0]
    assert cj["spec"]["concurrencyPolicy"] == "Forbid" and cj["spec"]["schedule"] == "*/30 * * * *"
    job = cj["spec"]["jobTemplate"]["spec"]
    assert job["backoffLimit"] == 2 and job["activeDeadlineSeconds"] == 900
    assert job["template"]["spec"]["restartPolicy"] == "Never"
    assert job["template"]["spec"]["containers"][0]["args"] == ["reconcile-trigger"]


# ------------------------------------------------------------------------------------------------ schema rejections
def _bad(mutate):
    v = copy.deepcopy(load_values(CHART / "examples" / "aks-bff.yaml"))
    mutate(v)
    return v


REJECT = {
    "tag_only_image": lambda v: v.update(image={"repository": "ehcrshareddevabcde.azurecr.io/hello-bff", "tag": "1.0"}),
    "tag_plus_digest": lambda v: v["image"].update(tag="latest"),
    "digest_not_sha256": lambda v: v["image"].update(digest="latest"),
    "repository_with_tag": lambda v: v["image"].update(repository="ehcrshareddevabcde.azurecr.io/hello-bff:1.0"),
    "missing_client_id": lambda v: v["identity"].pop("clientId"),
    "client_id_not_uuid": lambda v: v["identity"].update(clientId="c1"),
    # values.yaml ships defaults; a deployer can only drop them with null (Helm deletes null keys) -> rejected
    "missing_resources": lambda v: v.update(resources=None),
    "missing_memory_limit": lambda v: v["resources"]["limits"].update(memory=None),
    "missing_client_id_null": lambda v: v["identity"].update(clientId=None),
    "missing_digest_null": lambda v: v["image"].update(digest=None),
    "fault_token_plain_env": lambda v: v["env"].update(FAULT_TOKEN="x"),
    "password_plain_env": lambda v: v["env"].update(PG_PASSWORD="x"),
    "chart_owned_env": lambda v: v["env"].update(DD_VERSION="other"),
    "faults_without_token": lambda v: (v.update(secretEnv={}, keyVault={"enabled": False}), v["faults"].update(enabled=True)),
    "secret_env_without_keyvault": lambda v: v["keyVault"].update(enabled=False),
    "secret_env_versioned_id": lambda v: v["secretEnv"].update(FAULT_TOKEN=v["secretEnv"]["FAULT_TOKEN"] + "/0123456789abcdef"),
    "hpa_above_ceiling": lambda v: v["autoscaling"].update(maxReplicas=50),
    "root_allowed": lambda v: v.update(podSecurityContext={"runAsNonRoot": False, "seccompProfile": {"type": "RuntimeDefault"}}),
    "unknown_kind": lambda v: v.update(kind="daemonset"),
    "cronjob_without_schedule": lambda v: v.update(kind="cronjob"),
    "unknown_key": lambda v: v.update(sidecars=[{"name": "fluent-bit"}]),
}


@pytest.mark.parametrize("helm", helm_binaries() or [None], ids=lambda h: (h or "none").rsplit("/", 1)[-1])
@pytest.mark.parametrize("name", sorted(REJECT))
def test_schema_rejects(name, helm, tmp_path):
    if not helm:
        pytest.skip("helm not installed")
    res = template(_bad(REJECT[name]), tmp=tmp_path, helm=helm)
    assert res.returncode != 0, f"{name} should be rejected"
    assert "values don't meet the specifications of the schema" in res.stderr, res.stderr


def test_min_greater_than_max_fails(helm_bin, tmp_path):
    res = template(_bad(lambda v: v["autoscaling"].update(minReplicas=5, maxReplicas=3)), tmp=tmp_path)
    assert res.returncode != 0 and "minReplicas" in res.stderr


def test_faults_enabled_with_keyvault_token(helm_bin, tmp_path):
    docs = render(_bad(lambda v: v["faults"].update(enabled=True)), tmp=tmp_path)
    env = {e["name"]: e for e in by_kind(docs, "Deployment")[0]["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["FAULTS_ENABLED"]["value"] == "true"
    assert env["FAULT_TOKEN"]["valueFrom"]["secretKeyRef"] == {"name": "hello-bff-kv", "key": "FAULT_TOKEN"}


def test_chart_metadata():
    chart = yaml.safe_load((CHART / "Chart.yaml").read_text())
    assert chart["apiVersion"] == "v2" and chart["type"] == "application"
    assert re.fullmatch(r"\d+\.\d+\.\d+", chart["version"])
    assert not (CHART / "charts").exists() and "dependencies" not in chart, "no subcharts (one release per workload)"


def test_package_excludes_examples(helm_bin, tmp_path):
    res = run([helm_bin, "package", str(CHART), "--app-version", "src-test", "-d", str(tmp_path)])
    assert res.returncode == 0, res.stderr
    chart = yaml.safe_load((CHART / "Chart.yaml").read_text())
    with tarfile.open(tmp_path / f"hello-service-{chart['version']}.tgz") as t:
        names = t.getnames()
    assert "hello-service/values.schema.json" in names and "hello-service/README.md" in names
    assert not any("/examples/" in n for n in names)
