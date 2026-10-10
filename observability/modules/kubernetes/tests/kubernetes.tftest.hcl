mock_provider "helm" {
  override_during = plan
}
mock_provider "kubernetes" {
  override_during = plan
}

# File default: the 2.x path (fluent_bit_direct: Fluent Bit DaemonSet -> Datadog); the 3.0 default runs override it.
variables {
  log_pipeline = "fluent_bit_direct"
  cluster_name = "aks-eh-dev"
  datadog      = { site = "datadoghq.eu", env = "dev", extra_tags = { team = "platform" } }
  dsv = {
    api_key_ref        = "dsv://eh/dev/datadog-api-key#value"
    tenant             = "contoso"
    fetch_image        = "ehacr.azurecr.io/dsv-fetch@sha256:3333333333333333333333333333333333333333333333333333333333333333"
    identity_client_id = "66666666-6666-6666-6666-666666666666"
  }
  cluster_checks = {
    "postgres.yaml" = "cluster_check: true\ninit_config: {}\ninstances:\n  - host: psql-eh-dev.postgres.database.azure.com\n    dbm: true\n"
  }
}

run "defaults" {
  command = plan

  assert {
    condition     = helm_release.datadog.version == "3.253.2" && helm_release.fluent_bit[0].version == "0.58.3"
    error_message = "Charts pinned."
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[1]).datadog.logs.enabled == false && yamldecode(helm_release.datadog.values[1]).datadog.logs.containerCollectAll == false
    error_message = "Agent container log collection must be disabled (Fluent Bit owns app logs)."
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[0]).datadog.otlp.receiver.protocols.grpc.useHostPort && yamldecode(helm_release.datadog.values[0]).datadog.otlp.receiver.protocols.grpc.endpoint == "0.0.0.0:4317"
    error_message = "OTLP gRPC on hostPort 4317."
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[1]).providers.aks.enabled && !can(yamldecode(helm_release.datadog.values[1]).datadog.kubelet.tlsVerify)
    error_message = "AKS provider on; TLS verification kept by default."
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[1]).datadog.apiKey == "ENC[dsv://eh/dev/datadog-api-key#value]" && yamldecode(helm_release.datadog.values[1]).datadog.secretBackend.command == "/opt/dsv-fetch/dsv-fetch" && yamldecode(helm_release.datadog.values[1]).datadog.secretBackend.arguments == "agent-backend"
    error_message = "Agents resolve the API key ENC[dsv://] reference with dsv-fetch agent-backend; values hold only the reference."
  }
  assert {
    condition     = helm_release.datadog.values[0] == file("${path.module}/values/base.yaml") && length(helm_release.datadog.values) == 2
    error_message = "Layered values: [values/base.yaml, fleet layer] (no overrides given)."
  }
  assert {
    condition = (yamldecode(helm_release.datadog.values[1]).agents.rbac.serviceAccountAnnotations["azure.workload.identity/client-id"] == "66666666-6666-6666-6666-666666666666"
      && yamldecode(helm_release.datadog.values[1]).clusterAgent.rbac.serviceAccountAnnotations["azure.workload.identity/client-id"] == "66666666-6666-6666-6666-666666666666"
      && yamldecode(helm_release.datadog.values[1]).clusterChecksRunner.rbac.serviceAccountAnnotations["azure.workload.identity/client-id"] == "66666666-6666-6666-6666-666666666666"
      && yamldecode(helm_release.datadog.values[1]).clusterChecksRunner.rbac.dedicated
      && alltrue([for c in ["agents", "clusterAgent", "clusterChecksRunner"] : yamldecode(helm_release.datadog.values[1])[c].additionalLabels["azure.workload.identity/use"] == "true"])
    && yamldecode(helm_release.datadog.values[0]).clusterAgent.volumes[0].emptyDir.medium == "Memory")
    error_message = "Workload identity on the agent, Cluster Agent and runner service accounts; dsv-fetch emptyDir (Memory) in base.yaml."
  }
  assert {
    condition = (helm_release.datadog.postrender.binary_path == "/bin/sh" && endswith(helm_release.datadog.postrender.args[0], "postrender/dsv-fetch-init.sh")
    && helm_release.datadog.postrender.args[2] == "ehacr.azurecr.io/dsv-fetch@sha256:3333333333333333333333333333333333333333333333333333333333333333" && helm_release.datadog.postrender.args[4] == "3")
    error_message = "Post-renderer adds the dsv-fetch-install init container (digest-pinned image) to the 3 Agent workloads."
  }
  assert {
    condition = (anytrue([for e in yamldecode(helm_release.datadog.values[1]).datadog.env : e.name == "DSV_BASE_URL" && e.value == "https://contoso.secretsvaultcloud.com/v1"])
      && anytrue([for e in yamldecode(helm_release.datadog.values[1]).clusterAgent.env : e.name == "DSV_AUTH" && e.value == "azure"])
      && anytrue([for e in yamldecode(helm_release.datadog.values[1]).clusterChecksRunner.env : e.name == "DSV_TENANT" && e.value == "contoso"])
    && !strcontains(join("\n", helm_release.datadog.values), "DD_SECRET_BACKEND_COMMAND"))
    error_message = "DSV env for node Agents, Cluster Agent and runners; no secret-backend opt-out."
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[1]).agents.image.tag == "7.84.2" && yamldecode(helm_release.datadog.values[1]).clusterAgent.image.tag == "7.84.2" && yamldecode(helm_release.datadog.values[1]).registry == "gcr.io/datadoghq"
    error_message = "Agent / Cluster Agent version = the fleet policy pin (agent.version), registry from agent.image."
  }
  assert {
    condition = (yamldecode(helm_release.fluent_bit[0].values[0]).initContainers[0].name == "dsv-fetch"
      && contains(yamldecode(helm_release.fluent_bit[0].values[0]).initContainers[0].args, "DD_API_KEY=dsv://eh/dev/datadog-api-key#value")
      && yamldecode(helm_release.fluent_bit[0].values[0]).extraVolumes[1].emptyDir.medium == "Memory"
      && yamldecode(helm_release.fluent_bit[0].values[0]).podLabels["azure.workload.identity/use"] == "true"
    && !anytrue([for e in yamldecode(helm_release.fluent_bit[0].values[0]).env : e.name == "DD_API_KEY"]))
    error_message = "Fluent Bit: dsv-fetch init container writes the env-yaml into an in-memory emptyDir; no API key env."
  }
  assert {
    condition     = strcontains(yamldecode(helm_release.datadog.values[1]).clusterAgent.confd["postgres.yaml"], "dbm: true") && yamldecode(helm_release.datadog.values[1]).clusterChecksRunner.enabled
    error_message = "DBM cluster checks dispatched to runners."
  }
  assert {
    condition     = strcontains(kubernetes_config_map_v1.fluent_bit[0].data["fluent-bit.yaml"], "/var/log/containers/*.log") && contains(yamldecode(helm_release.fluent_bit[0].values[0]).args, "--config=/fluent-bit/etc/eh/fluent-bit.yaml")
    error_message = "Fluent Bit DaemonSet runs the validated k8s config."
  }
  assert {
    condition     = yamldecode(helm_release.fluent_bit[0].values[0]).resources.limits.memory == "512Mi" && yamldecode(helm_release.datadog.values[0]).agents.containers.agent.resources.limits.memory == "512Mi"
    error_message = "Bounded resources."
  }
  assert {
    condition     = output.contract.agent.otlp_grpc_port == 4317 && output.contract.log_route == "daemonset" && output.contract.agent.local_service == "datadog.datadog.svc.cluster.local"
    error_message = "obs-kubernetes contract."
  }
}

run "hostca_kubelet" {
  command = plan
  variables {
    features = { kubelet_tls_mode = "aks_hostca" }
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[1]).datadog.kubelet.hostCAPath == "/etc/kubernetes/certs/kubeletserver.crt" && !can(yamldecode(helm_release.datadog.values[1]).datadog.apiKeyExistingSecret)
    error_message = "AKS kubelet CA path; no existing-Secret mode."
  }
}

run "cluster_checks_identity_and_overrides" {
  command = plan
  variables {
    dsv = {
      api_key_ref                       = "dsv://eh/dev/datadog-api-key#value"
      tenant                            = "contoso"
      fetch_image                       = "ehacr.azurecr.io/dsv-fetch@sha256:3333333333333333333333333333333333333333333333333333333333333333"
      identity_client_id                = "66666666-6666-6666-6666-666666666666"
      cluster_checks_identity_client_id = "77777777-7777-7777-7777-777777777777"
    }
    values_overrides = ["clusterAgent:\n  replicas: 2\n", "agents:\n  tolerations: [{operator: Exists}]\n"]
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[1]).clusterChecksRunner.rbac.serviceAccountAnnotations["azure.workload.identity/client-id"] == "77777777-7777-7777-7777-777777777777" && yamldecode(helm_release.datadog.values[1]).agents.rbac.serviceAccountAnnotations["azure.workload.identity/client-id"] == "66666666-6666-6666-6666-666666666666"
    error_message = "Runners use the cluster-checks identity (e.g. obs-dbm), the other Agents the collector identity."
  }
  assert {
    condition     = length(helm_release.datadog.values) == 4 && yamldecode(helm_release.datadog.values[2]).clusterAgent.replicas == 2 && yamldecode(helm_release.datadog.values[3]).agents.tolerations[0].operator == "Exists"
    error_message = "Per-cluster overrides are applied last, in order."
  }
}

run "reject_override_of_secret_path" {
  command = plan
  variables {
    values_overrides = ["datadog:\n  apiKeyExistingSecret: datadog-api-key\n"]
  }
  expect_failures = [var.values_overrides]
}

run "reject_override_dropping_backend_volume" {
  command = plan
  variables {
    values_overrides = ["clusterAgent:\n  volumes: []\n"]
  }
  expect_failures = [var.values_overrides]
}

run "reject_tag_pinned_fetch_image" {
  command = plan
  variables {
    dsv = { api_key_ref = "dsv://eh/dev/datadog-api-key#value", tenant = "contoso", fetch_image = "ehacr.azurecr.io/dsv-fetch:2.0.0", identity_client_id = "66666666-6666-6666-6666-666666666666" }
  }
  expect_failures = [var.dsv]
}

run "reject_policy_without_agent_version" {
  command = plan
  variables {
    fleet_policy = {
      apiVersion   = "observability/fleet-policy/v1"
      kind         = "FleetPolicy"
      log_pipeline = "fluent_bit_direct"
      agent        = { remote_configuration = true }
    }
  }
  expect_failures = [helm_release.datadog]
}

run "reject_cluster_checks_without_runner" {
  command = plan
  variables {
    features = { cluster_checks_runner = false }
  }
  expect_failures = [helm_release.datadog]
}

run "reject_k8s_secret_in_cluster_checks" {
  command = plan
  variables {
    cluster_checks = { "mysql.yaml" = "cluster_check: true\ninstances:\n  - password: ENC[k8s_secret@datadog/db/password]\n" }
  }
  expect_failures = [var.cluster_checks]
}

run "reject_unpinned_chart" {
  command = plan
  variables {
    charts = { datadog_version = "latest" }
  }
  expect_failures = [var.charts]
}

run "reject_bad_kubelet_mode" {
  command = plan
  variables {
    features = { kubelet_tls_mode = "whatever" }
  }
  expect_failures = [var.features]
}

run "fleet_default_agent_logs_to_op_ssi_profiling" {
  command = plan
  variables {
    log_pipeline = null
    op_logs_url  = "http://eh-obs-dev-opw.internal.example.azurecontainerapps.io:8282"
    identity     = { team = "platform-engineering", region = "swedencentral", application = "enterprise-hello", owner = "platform@example.com", domain = "shared", tier = "infrastructure" }
  }
  assert {
    condition     = length(helm_release.fluent_bit) == 0 && yamldecode(helm_release.datadog.values[1]).datadog.logs.enabled && yamldecode(helm_release.datadog.values[1]).datadog.logs.containerCollectAll
    error_message = "one log collector per node: the Agent (no Fluent Bit DaemonSet)"
  }
  assert {
    condition     = anytrue([for e in yamldecode(helm_release.datadog.values[1]).datadog.env : e.name == "DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL" && e.value == "http://eh-obs-dev-opw.internal.example.azurecontainerapps.io:8282"]) && anytrue([for e in yamldecode(helm_release.datadog.values[1]).datadog.env : e.name == "DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_ENABLED" && e.value == "true"])
    error_message = "Agent logs -> Observability Pipelines Worker"
  }
  assert {
    condition     = strcontains(yamldecode(helm_release.datadog.values[1]).datadog.containerExcludeLogs, "kube_namespace:datadog")
    error_message = "collector namespaces excluded"
  }
  assert {
    condition = (yamldecode(helm_release.datadog.values[1]).datadog.apm.instrumentation.enabled
      && yamldecode(helm_release.datadog.values[1]).datadog.apm.instrumentation.targets[0].namespaceSelector.matchNames[0] == "hello"
      && yamldecode(helm_release.datadog.values[1]).datadog.apm.instrumentation.targets[0].ddTraceVersions.dotnet == "v3"
      && yamldecode(helm_release.datadog.values[1]).datadog.apm.instrumentation.targets[0].ddTraceVersions.python == "v4"
    && anytrue([for c in yamldecode(helm_release.datadog.values[1]).datadog.apm.instrumentation.targets[0].ddTraceConfigs : c.name == "DD_PROFILING_ENABLED" && c.value == "auto"]))
    error_message = "Single Step Instrumentation: target namespaces, pinned library majors, profiler injected"
  }
  assert {
    condition     = anytrue([for e in yamldecode(helm_release.datadog.values[1]).clusterAgent.env : e.name == "DD_ADMISSION_CONTROLLER_AUTO_INSTRUMENTATION_INIT_SECURITY_CONTEXT"])
    error_message = "restricted PSS securityContext for injected init containers"
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[1]).datadog.podLabelsAsTags["team"] == "team" && contains(yamldecode(helm_release.datadog.values[1]).datadog.tags, "team:platform-engineering") && contains(yamldecode(helm_release.datadog.values[1]).datadog.tags, "region:swedencentral")
    error_message = "tag policy: cluster tags + podLabelsAsTags"
  }
  assert {
    condition     = yamldecode(helm_release.datadog.values[1]).remoteConfiguration.enabled && output.contract.log_collector == "datadog-agent" && output.contract.agent.ssi_enabled
    error_message = "Remote Configuration on; contract reflects the collector"
  }
}

run "op_with_fluent_bit_node_collector" {
  command = plan
  variables {
    log_pipeline = null
    op_logs_url  = "http://opw.internal:8282"
    fleet_policy = {
      apiVersion = "observability/fleet-policy/v1"
      kind       = "FleetPolicy"
      logs       = { node_collector = "fluent_bit" }
      agent      = { version = "7.84.2" }
    }
  }
  assert {
    condition     = length(helm_release.fluent_bit) == 1 && !yamldecode(helm_release.datadog.values[1]).datadog.logs.enabled && length(yamldecode(helm_release.fluent_bit[0].values[0]).initContainers) == 0
    error_message = "Fluent Bit DaemonSet forwards to the Worker without a key (no dsv-fetch)"
  }
  assert {
    condition     = strcontains(kubernetes_config_map_v1.fluent_bit[0].data["fluent-bit.yaml"], "- name: forward") && anytrue([for e in yamldecode(helm_release.fluent_bit[0].values[0]).env : e.name == "FLB_FORWARD_HOST" && e.value == "opw.internal"])
    error_message = "DaemonSet output = Worker fluent source"
  }
}

run "op_worker_on_aks" {
  command = plan
  variables {
    log_pipeline = null
    op_worker = {
      enabled     = true
      pipeline_id = "aaaaaaaa-0000-0000-0000-000000000001"
      env         = { DD_OP_SOURCE_KAFKA_BOOTSTRAP_SERVERS = "evhns.servicebus.windows.net:9093", DD_API_KEY = "must-be-ignored" }
      secret_env  = { DD_OP_SOURCE_KAFKA_SASL_PASSWORD = "dsv://eh/dev/eventhub-opw-listen#value" }
    }
  }
  assert {
    condition = (anytrue([for e in yamldecode(helm_release.op_worker[0].values[0]).env : e.name == "DD_OP_SOURCE_KAFKA_BOOTSTRAP_SERVERS" && try(e.value, "") == "evhns.servicebus.windows.net:9093"])
      && !anytrue([for e in yamldecode(helm_release.op_worker[0].values[0]).env : e.name == "DD_API_KEY" || can(e.valueFrom.secretKeyRef)])
      && contains(yamldecode(helm_release.op_worker[0].values[0]).initContainers[0].args, "DD_OP_SOURCE_KAFKA_SASL_PASSWORD=dsv://eh/dev/eventhub-opw-listen#value")
    && contains(yamldecode(helm_release.op_worker[0].values[0]).initContainers[0].args, "DD_API_KEY=dsv://eh/dev/datadog-api-key#value"))
    error_message = "Event Hubs source env for the in-cluster Worker: bootstrap as value, SASL password + API key from DSV (dsv-fetch init); chart-managed keys cannot be overridden; no secretKeyRef"
  }
  assert {
    condition = (helm_release.op_worker[0].version == "2.22.0" && yamldecode(helm_release.op_worker[0].values[0]).persistence.enabled
      && yamldecode(helm_release.op_worker[0].values[0]).datadog.apiKey == "ENC[dsv://eh/dev/datadog-api-key#value]" && !can(yamldecode(helm_release.op_worker[0].values[0]).datadog.apiKeyExistingSecret)
      && yamldecode(helm_release.op_worker[0].values[0]).extraVolumes[0].emptyDir.medium == "Memory"
      && strcontains(yamldecode(helm_release.op_worker[0].values[0]).command[2], ". /dsv-secrets/opw.env")
    && yamldecode(helm_release.op_worker[0].values[0]).serviceAccount.annotations["azure.workload.identity/client-id"] == "66666666-6666-6666-6666-666666666666")
    error_message = "Worker chart pinned, persistent disk buffers; chart Secret = ENC[] reference only, values from the dsv-fetch env file (workload identity)"
  }
  assert {
    condition     = anytrue([for e in yamldecode(helm_release.datadog.values[1]).datadog.env : e.name == "DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL" && e.value == "http://opw-observability-pipelines-worker.observability-pipelines.svc.cluster.local:8282"])
    error_message = "Agents ship to the in-cluster Worker service"
  }
}

run "reject_op_agent_logs_without_endpoint" {
  command = plan
  variables {
    log_pipeline = null
  }
  expect_failures = [helm_release.datadog]
}

run "agents_drop_health_probe_traces" {
  command = plan
  assert {
    condition     = anytrue([for e in yamldecode(helm_release.datadog.values[1]).datadog.env : e.name == "DD_APM_IGNORE_RESOURCES" && strcontains(e.value, "GET /healthz") && strcontains(e.value, "GET /readyz")])
    error_message = "Node Agents drop the health-probe resources of the fleet policy (apm.ignore_resources)"
  }
}
