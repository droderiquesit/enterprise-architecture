# lab/dbm (component `obs-dbm`)

**Owner:** observability. **Purpose:** Datadog Database Monitoring for the lab databases through `modules/dbm`.
The checks run as an ACI Agent in the delegated `aci` subnet by default, or as AKS cluster checks.

* **Consumes:**
  * `obs_telemetry_transport.datadog_site`
  * `foundation_network.subnets[settings.subnet_key]`
  * `foundation_identity` (key_vault_uri, `identities["obs-dbm"]`)
  * optional: `platform_db_{postgresql,mysql,sql,sqlmi,sqlvm}`. Only their `dbm` block is read: supported,
    engine, deployment_type, auth_mode, identity_client_id, host, port, databases, password_secret_id.
    `self_hosted_azure_vm` maps to Datadog's `virtual_machine`.
* **Produces:** no contract. Outputs: `configured`, `cluster_check_confd` (copy to obs-kubernetes
  `settings.dbm_cluster_checks`), `agent_container_group_id`.

## Settings
* `hosting` (aci | cluster_checks | none)
* `subnet_key` (default `aci`)
* `identity_key` (`obs-dbm`), `api_key_secret_name`, `cpu`, `memory_gb`

## Prerequisites
* ACI container groups need a subnet delegated to `Microsoft.ContainerInstance/containerGroups`. The default
  `subnet_key = "aci"` uses foundation-network's delegated `aci` subnet (shared with partner-sim); the
  `observability` subnet has no delegation (ADR-0001 §8) and only works with `hosting = cluster_checks`. Database
  firewalls / NSGs must allow the `aci` subnet range (spoke-internal by default).
* The DB monitoring users are created with the scripts in `modules/dbm/sql/`, run by the database platform
  roots (their `grant_script`) or by an operator.
* Server parameters (pg_stat_statements, performance_schema) are platform-owned.

## Cost at defaults
ACI with 1 vCPU / 2 GB running always: about $45/month. Datadog DBM is billed per host.

## Teardown
Destroy removes the container group and its resource group. Database users and grants stay. Drop them with
`DROP ROLE` / `DROP USER datadog` if needed.

## Private networking
* The ACI gets a private IP only.
* Databases are reached through VNet injection or private endpoints. That needs private DNS resolution from
  the `aci` subnet (spoke VNet, linked private DNS zones).
* Egress is required to the Datadog intake and to Key Vault.
