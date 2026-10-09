# platform/compute/aks — AKS cluster platform

| | |
|---|---|
| Component id | `platform-aks` |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`subnets.aks-nodes`, `egress.type`, `spoke_vnet_id`), `foundation-identity` (`aks-control-plane`, `aks-kubelet`, workload identities, `deploy-agent`), `platform-shared` (`log_analytics_workspace_id`, only for the Defender opt-in) |
| Produces | `platform-aks` v1 (no kubeconfig, no credentials) |
| Status | `implemented` |

## What it creates

- Resource group + AKS cluster: Kubernetes **1.36** by default (AKS calendar on Learn, checked 2026-10-09:
  1.35 GA Mar 2026/EOL Mar 2027, **1.36 GA Jun 2026/EOL Jun 2027**, 1.37 GA Oct 2026 and still rolling out),
  `automatic_upgrade_channel = "patch"`, `node_os_upgrade_channel = "NodeImage"`, weekly maintenance windows
  (Sunday 02:00 UTC, 4 h) for both channels.
- **Entra ID + Azure RBAC for Kubernetes**, `local_account_disabled = true`, OIDC issuer + **workload identity**.
- Control plane identity `aks-control-plane` (user-assigned) with *Network Contributor* on the node subnet and
  *Managed Identity Operator* on the kubelet identity `aks-kubelet` (AcrPull is granted in platform-shared).
- Azure CNI **overlay** + Cilium data plane/network policy, pod CIDR `192.168.0.0/16`, service CIDR
  `10.0.0.0/16` (non-overlapping with hub `10.40.0.0/20` and spoke `10.41.0.0/16`).
- Outbound: `auto` → `userAssignedNATGateway` when foundation egress is a NAT gateway (the NAT gateway must
  already be associated with `aks-nodes`), `userDefinedRouting` when it is a firewall (0.0.0.0/0 route on the
  subnet). Override with `outbound_type`.
- System pool `system`: 1–2 × `Standard_D2s_v5` (cluster autoscaler), Azure Linux, no node public IPs.
  Optional user pool (`user_pool.enabled`); with it, the system pool is tainted `CriticalAddonsOnly`.
- Secrets Store CSI driver (Key Vault provider, rotation every 2 min) for app secret references.
- Azure RBAC grants for `deploy-agent` (+ `cluster_admin_principals`): *AKS RBAC Cluster Admin* and *AKS
  Cluster User Role* (Entra kubeconfig only), at cluster scope. Put the pipeline **apply** and **plan** identities'
  principal ids (bootstrap contract `identities.<id>.principal_id`) into `cluster_admin_principals`: deploy-core-aks
  and obs-kubernetes manage Kubernetes objects through the Entra-authenticated API (local accounts are disabled).
- **Federated identity credentials** binding foundation identities to this cluster's issuer:
  `hello/hello-bff`, `hello/hello-orders-api`, `hello/hello-catalog-api`, `hello/hello-worker`,
  `datadog/datadog-agent` (obs-collector). They live here because the issuer belongs to this cluster:
  recreating the cluster changes the issuer and must replace the credentials in the same apply.

Not here: namespaces, service accounts, Deployments (deploy-core-aks), Datadog Agent/Fluent Bit Helm releases
(obs-kubernetes), diagnostic settings (obs-diagnostics).

## Private API server (secure default)

`private_cluster_enabled = true` (private DNS zone `System`). Consequences:

- Pipelines must run on VNet-connected agents (`foundation-deploy-agents`) **or** use
  `az aks command invoke` (`run_command_enabled = true`, Entra-authorised) for Helm/kubectl.
- For a throw-away lab without agents: `private_cluster_enabled = false` **and** `authorized_ip_ranges`
  (validation enforces at least one range).

## Settings

`kubernetes_version`, `sku_tier` (Free/Standard), `automatic_upgrade_channel`, `node_os_upgrade_channel`,
`maintenance{}`, `private_cluster_enabled`, `private_dns_zone_id`, `authorized_ip_ranges`,
`run_command_enabled`, `admin_group_object_ids`, `cluster_admin_identities`, `cluster_admin_principals`,
`pod_cidr`, `service_cidr`, `dns_service_ip`, `outbound_type`, `system_pool{}`, `user_pool{}` (ceilings ≤ 10/20),
`azure_policy_enabled`, `image_cleaner_enabled`, `defender_enabled`, `host_encryption_enabled`,
`key_vault_secrets_provider_enabled`, `workload_identities` (identity key → namespace/service account).

## Cost at defaults (approx., USD/month, 24×7)

Free control plane 0 + 1 × D2s_v5 (~70) + 128 GB managed OS disk (~20) + Standard LB (~18) ≈ **110**.
Second autoscaled node ≈ +90. Use `az aks stop` / `az aks start` outside lab hours (no compute charges
while stopped; disks retained).

## Teardown / retention

Destroy removes the cluster, node resource group, and federated credentials. Workload data lives in the
databases (other roots); nothing persistent is kept in the cluster.

## Known limitations

- Ephemeral OS disks are not possible on Dsv5 (no temp disk) — justified for checkov.
- `userAssignedNATGateway` requires the NAT gateway association to exist before cluster creation (foundation).

## Docs

- https://learn.microsoft.com/azure/aks/supported-kubernetes-versions
- https://learn.microsoft.com/azure/aks/azure-cni-overlay
- https://learn.microsoft.com/azure/aks/workload-identity-overview
- https://learn.microsoft.com/azure/aks/manage-azure-rbac
- https://learn.microsoft.com/azure/aks/private-clusters
- https://learn.microsoft.com/azure/aks/nat-gateway
- https://learn.microsoft.com/azure/aks/auto-upgrade-cluster
- https://learn.microsoft.com/azure/aks/start-stop-cluster
