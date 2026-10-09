# platform/compute/aro — Azure Red Hat OpenShift

| | |
|---|---|
| Component id | `platform-aro` |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`spoke_vnet_id`, `subnets.aro-master`, `subnets.aro-worker`); pull secret from Delinea DSV (`aro-pull-secret`, pipeline input) |
| Produces | `platform-aro` v1 (`status = blocked` unless enabled) |
| Status | **`blocked`** by default — prerequisites below cannot be satisfied by Terraform in this repo |

## Exact prerequisites (all required before `enabled = true`)

1. **Quota: 44 vCPUs** of the chosen families in the region (bootstrap 8 + 3 masters × 8 + 3 workers × 4;
   36 after install). Default subscription quota is not enough — request an increase for *Standard DSv5 Family*.
2. **Resource providers** registered (subscription scope, done once by an admin — not by this root, so destroy
   never unregisters them): `Microsoft.RedHatOpenShift`, `Microsoft.Compute`, `Microsoft.Storage`,
   `Microsoft.Authorization` (`az provider register -n <ns> --wait`).
3. **Subnets** `aro-master` and `aro-worker` (foundation-network), empty, no other delegation, ≥ /27; the
   precondition fails if absent.
4. **ARO RP service principal** object id (`az ad sp list --display-name "Azure Red Hat OpenShift RP" --query "[0].id" -o tsv`)
   → `aro_rp_principal_id`.
5. **Version**: `az aro get-versions --location <region>` → `version` (no static default; versions move fast).
6. **Red Hat pull secret** (optional but needed for Red Hat content): store the JSON in Delinea DSV at
   `<prefix>/<env>/aro-pull-secret` (element `value`). The pipeline passes it as `TF_VAR_pull_secret`
   (`tools/secrets/fetch.py`, registry `secret_env`); `cluster_profile.pull_secret` has no write-only form in
   azurerm 5.9, so the value is stored in Terraform state (never in outputs or contracts).
7. If NSGs/NAT gateways/route tables are attached to the ARO subnets, add their ids to
   `extra_network_resource_ids` so operator identities get the same scoped roles (Learn requirement).

## What it creates (when enabled)

- Cluster with **managed identities** (current ARO model; service principals are not used): cluster identity +
  8 platform workload identities (`cloud-controller-manager`, `ingress`, `machine-api`, `disk-csi-driver`,
  `cloud-network-config`, `image-registry`, `file-csi-driver`, `aro-operator`) with the built-in ARO roles and
  scopes from the Learn "create cluster with managed identities" article (role definition GUIDs in `main.tf`),
  plus *ARO Federated Credential* for the cluster identity and the ARO RP network role on the VNet.
- Private API server and private ingress by default; masters `Standard_D8s_v5`, workers 3 × `Standard_D4s_v5`.

## Cost when enabled (approx.)

> USD 2,000/month (3 × D8s_v5 + 3 × D4s_v5 + ARO worker fees + disks/LB). Disabled: 0.

## Docs

- https://learn.microsoft.com/azure/openshift/howto-create-openshift-cluster
- https://learn.microsoft.com/azure/openshift/howto-understand-managed-identities
- https://learn.microsoft.com/azure/openshift/concepts-networking
