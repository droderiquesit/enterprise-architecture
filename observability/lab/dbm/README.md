# lab/dbm (component `obs-dbm`)

**Owner:** observability. **Purpose:** Datadog Database Monitoring for the lab databases through `modules/dbm`.
`settings.hosting = auto` (default) chooses: when the platform-aks contract is present (a cluster exists) the checks run
as **cluster checks** of the Datadog Cluster Agent - obs-kubernetes renders them from the same platform-db contracts
(`modules/dbm/contracts`) and this root deploys nothing; without a cluster an **ACI Agent** in the delegated `aci` subnet
runs them.

* **Consumes:**
  * `obs_telemetry_transport.datadog_site`
  * `foundation_network.subnets[settings.subnet_key]`
  * `foundation_identity` v2 (`identities["obs-dbm"]`, `secrets.base_path`), `obs_telemetry_transport` v2 (`api_key_ref`, `secrets`)
  * optional: `platform_aks` (presence only: selects cluster checks), `artifacts["img-dsv-fetch"]` (ACI init
    container copying the static dsv-fetch binary; else the transport contract's `secrets.fetch_image`)
  * optional: `platform_db_{postgresql,mysql,sql,sqlmi,sqlvm}`. Only their `dbm` block is read: supported,
    engine, deployment_type, auth_mode, identity_client_id, host, port, databases, password_secret_id.
    `self_hosted_azure_vm` maps to Datadog's `virtual_machine`.
* **Produces:** no contract. Outputs: `configured`, `hosting` (effective), `cluster_check_confd` (evidence),
  `agent_container_group_id`.

## Settings
* `hosting` (`auto` default | `cluster_checks` | `aci` | `none`). An explicit `aci` with a cluster present also needs
  obs-kubernetes `settings.dbm = off` (otherwise both would run the checks).
* `subnet_key` (default `aci`)
* `identity_key` (`obs-dbm`), `cpu`, `memory_gb`
* ACI Agent image: the fleet policy `<agent.image>:<agent.version>` (single pin; no fallback)

## Prerequisites
* ACI container groups need a subnet delegated to `Microsoft.ContainerInstance/containerGroups`. The default
  `subnet_key = "aci"` uses foundation-network's delegated `aci` subnet (shared with partner-sim); the
  `observability` subnet has no delegation (ADR-0001 §8) and only works with `hosting = cluster_checks`. Database
  firewalls / NSGs must allow the `aci` subnet range (spoke-internal by default).
* The DB monitoring users are created with the scripts in `modules/dbm/sql/`, run by the database platform
  roots (their `grant_script`) or by an operator.
* Server parameters (pg_stat_statements, performance_schema) are platform-owned.

## Cost at defaults
ACI (no cluster only) with 1 vCPU / 2 GB running always: about $45/month; cluster checks use the existing runner. Datadog DBM is billed per host.

## Teardown
Destroy removes the container group and its resource group. Database users and grants stay. Drop them with
`DROP ROLE` / `DROP USER datadog` if needed.

## Private networking
* The ACI gets a private IP only.
* Databases are reached through VNet injection or private endpoints. That needs private DNS resolution from
  the `aci` subnet (spoke VNet, linked private DNS zones).
* Egress is required to the Datadog intake and to the DSV tenant.

## Test
`terraform init -backend=false && terraform test` in this directory (mock providers, no credentials): `tests/lab.tftest.hcl`. From the repository root: `python3 tools/validate/all_terraform.py --only obs-dbm` (fmt, validate, test).
