# deploy-core-aks — core services on AKS

- **Owner**: applications layer. **Status**: implemented (mock tests); not deployed.
- **Purpose**: `hello-bff`, `hello-orders-api`, `hello-catalog-api`, `hello-worker` as Kubernetes Deployments in
  namespace `hello` with workload-identity ServiceAccounts, Services, PodDisruptionBudgets, HPAs (CPU, ceilings).
- **Providers**: azurerm (cluster endpoint/CA via `data.azurerm_kubernetes_cluster`, i.e. listClusterUserCredential;
  local accounts are disabled so no credentials are returned) + kubernetes 3.3 with **kubelogin exec**
  (`settings.kubelogin_mode`: `azurecli` (pipeline AzureCLI task / developer) or `workloadidentity`).
  The private API server must be reachable (foundation-deploy-agents in the VNet).
- **Consumed contracts**: platform-aks, platform-shared, platform-messaging, platform-db-sql, platform-db-postgresql,
  obs-telemetry-transport, foundation-identity; optional platform-db-redis, obs-kubernetes (not read today).
- **Produced contract**: `deploy-core-aks`: `apps.<svc>.{id (<cluster id>/namespaces/hello/deployments/<svc>), url,...}`,
  `public_api.origin`, `endpoints` (BFF only), `idle_behavior` (no scale-to-zero), `secrets.mechanism`, `exposure`.

## App settings
Same service env as deploy-core-aca plus: `DD_AGENT_HOST` from `status.hostIP` (first env var) and
`OTEL_EXPORTER_OTLP_ENDPOINT=http://$(DD_AGENT_HOST):4317` (gRPC), no `LOG_FILE_PATH` (stdout → Fluent Bit
DaemonSet), unified service labels `tags.datadoghq.com/*`, pod annotation `ad.datadoghq.com/<c>.logs=[]` (Agent must
not ship the same logs). Worker: `SB_TOPIC`, `SB_SUBSCRIPTION=notifications`, `HEALTH_PORT=8081`, `TABLE_MODE=memory`
(this root does not consume platform-db-table-storage). Python services get `AZURE_CREDENTIAL_MODE=workload_identity`.

**Secrets**: Azure Key Vault provider for the Secrets Store CSI driver (platform-aks `key_vault_secrets_provider_enabled`
= true by default). One `SecretProviderClass` per app (`clientID` = the app's workload identity), synced to Secret
`<svc>-kv`, env via `secretKeyRef`; the CSI volume is mounted read-only (sync only happens while mounted). When the
add-on is disabled (`key_vault_secrets_provider = null`) FAULT_TOKEN is not injected (faults impossible).

**Exposure**: platform-aks does not enable the application routing add-on (`web_app_routing`), so the default
`exposure.mode = internal-lb` publishes hello-bff on an internal Azure Load Balancer (HTTP, VNet only). With the add-on
enabled, `exposure.mode = app-routing` creates an Ingress (`webapprouting.kubernetes.azure.com`) with TLS from Key Vault
(`kubernetes.azure.com/tls-cert-keyvault-uri`).

## Settings
`kubelogin_mode`, `namespace`, `faults_enabled`, `log_level`, `trace_sample_ratio`, `replica_ceiling` (6),
`exposure.{mode,host,tls_cert_keyvault_id}`, `cors_allowed_origins`, `auth_mode`, `inventory_api_url`, `adapters`,
`apps.<svc>.{enabled,min_replicas (1),max_replicas (3),cpu/memory requests+limits,target_cpu}`.

## Rollback
Re-run the deployment with the previous image digests (RollingUpdate, maxUnavailable 0, readiness-gated).
Break-glass: `kubectl rollout undo deployment/<svc> -n hello`.

## Smoke
`scripts/smoke.sh`: in-cluster URLs through `az aks command invoke` (`curl http://<svc>.hello.svc.cluster.local/readyz`),
BFF via the internal LB address from the deploy agents.

## Cost
No Azure resources of its own (pods run on the platform-aks node pool). Internal LB: Standard LB rules ≈ $18/month.

## Teardown
Destroys Kubernetes objects and namespace `hello`; no persistent volumes.

## Security
Pod Security `restricted` labels, non-root, read-only root FS (+ `/tmp` emptyDir), drop ALL capabilities,
RuntimeDefault seccomp, topology spread, `automountServiceAccountToken` only for the projected WI token.

## Limitations
- kubernetes_manifest (SecretProviderClass) needs API access at plan time.
- TLS on the internal LB path is not available without the app routing add-on (requested change).

Docs: https://learn.microsoft.com/azure/aks/workload-identity-overview , https://learn.microsoft.com/azure/aks/csi-secrets-store-identity-access ,
https://learn.microsoft.com/azure/aks/app-routing , https://azure.github.io/kubelogin/
