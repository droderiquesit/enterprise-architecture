#!/usr/bin/env python3
"""Generates catalog/contracts/platform-db-*.v1.schema.json and platform-data-analytics.v1.schema.json.

The schemas are committed; re-run this script after changing a platform/data root's contract output:
    python3 platform/data/tests/gen_contract_schemas.py
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = ROOT / "catalog" / "contracts"

RID = {"type": "string", "pattern": "^/subscriptions/[^/]+/"}
NRID = {"type": ["string", "null"], "pattern": "^/subscriptions/[^/]+/"}
SECRET = {"type": "string", "pattern": "^https://[^/]+/secrets/[A-Za-z0-9-]+$",
          "description": "Versionless Key Vault secret ID (never a value)."}
NSECRET = dict(SECRET, type=["string", "null"])
STR = {"type": "string"}
NSTR = {"type": ["string", "null"]}
PORT = {"type": "integer", "minimum": 1, "maximum": 65535}
BOOL = {"type": "boolean"}
STRLIST = {"type": "array", "items": STR}


def obj(required, props, extra=True):
    return {"type": "object", "required": required, "properties": props, "additionalProperties": extra}


def nullable(o):
    return {"oneOf": [{"type": "null"}, o]}


DEFS = {
    "privateEndpoint": obj(["enabled"], {
        "enabled": BOOL, "id": NRID, "private_ip_address": NSTR, "group_id": NSTR}),
    "grant": obj(["identity_name"], {
        "identity_name": STR, "client_id": STR, "object_id": STR,
        "roles": STRLIST, "privileges": STR, "schema": STR}),
    "rbac": obj(["identity_name", "principal_id", "role", "scope"], {
        "identity_name": STR, "principal_id": STR, "role": STR, "scope": STR}),
    "dbm": {
        "type": "object",
        "required": ["supported"],
        "properties": {
            "supported": BOOL, "reason": STR,
            "engine": {"enum": ["sqlserver", "postgres", "mysql"]},
            "deployment_type": {"enum": ["sql_database", "managed_instance", "self_hosted_azure_vm", "flexible_server"]},
            "auth_mode": {"enum": ["entra-managed-identity", "native-password", "sql-login"]},
            "identity_name": {"const": "obs-dbm"},
            "identity_client_id": NSTR,
            "host": STR, "port": PORT, "resource_id": RID,
            "databases": STRLIST,
            "excluded_databases": {"type": "object", "additionalProperties": STR},
            "password_secret_id": SECRET, "admin_secret_id": SECRET,
            "required_parameters": {"type": "object", "additionalProperties": STR},
            "setup_reference": {"type": "string", "format": "uri"},
        },
        "if": {"properties": {"supported": {"const": True}}},
        "then": {"required": ["engine", "deployment_type", "auth_mode", "identity_name", "host", "port", "resource_id", "databases"]},
        "else": {"required": ["reason"]},
    },
    "relationalDatabase": obj(["name", "boundary", "owner_identity_name", "auth_mode"], {
        "id": STR, "name": STR, "fqdn": STR, "port": PORT, "boundary": STR,
        "schemas": STRLIST, "auth_mode": STR, "owner_identity_name": STR,
        "reader_writer_identity_names": STRLIST,
        "grants": {"type": "array", "items": {"$ref": "#/$defs/grant"}},
        "password_secret_id": SECRET, "login": STR, "connection_hint": STR, "dbm_enabled": BOOL}),
    "logicalStore": obj(["name", "boundary", "owner_identity_name"], {
        "id": STR, "name": STR, "boundary": STR, "owner_identity_name": STR,
        "containers": {"type": "object", "additionalProperties": obj(["name"], {
            "id": STR, "name": STR, "partition_key": STR})}}),
}

REF = lambda n: {"$ref": f"#/$defs/{n}"}
DB_MAP = lambda n: {"type": "object", "minProperties": 1, "additionalProperties": REF(n)}
DB_MAP0 = lambda n: {"type": "object", "additionalProperties": REF(n)}
RBAC = {"type": "array", "items": REF("rbac")}

ENTRA_ADMIN = {"type": "object"}
SERVER_BASE = {"id": RID, "name": STR, "fqdn": STR, "port": PORT, "public_network_access_enabled": {"const": False},
               "auth_mode": STR, "entra_admin": ENTRA_ADMIN}


def cosmos(api, auth_modes):
    return obj(["resource_group_name", "engine", "api", "account", "auth_mode", "key_secret_id", "private_endpoint", "databases", "rbac", "dbm"], {
        "resource_group_name": STR, "engine": {"const": "cosmosdb"}, "api": {"const": api},
        "account": obj(["id", "name", "endpoint", "host", "port", "public_network_access_enabled", "local_auth_enabled", "capacity_mode"], {
            "id": RID, "name": STR, "endpoint": STR, "host": STR, "port": PORT,
            "public_network_access_enabled": {"const": False}, "local_auth_enabled": BOOL,
            "capacity_mode": {"enum": ["serverless", "provisioned"]}, "backup": STR}),
        "auth_mode": {"enum": auth_modes},
        "key_secret_id": NSECRET,
        "private_endpoint": REF("privateEndpoint"),
        "databases": DB_MAP("logicalStore"), "rbac": RBAC, "dbm": REF("dbm")})


CONTRACTS = {
    "platform-db-sql": obj(["resource_group_name", "engine", "server", "private_endpoint", "databases", "dbm"], {
        "resource_group_name": STR, "engine": {"const": "azure-sql-database"},
        "server": obj(["id", "name", "fqdn", "port", "auth_mode", "entra_admin"], dict(SERVER_BASE, auth_mode={"const": "entra-only"})),
        "private_endpoint": REF("privateEndpoint"), "elastic_pool_id": NRID,
        "databases": DB_MAP("relationalDatabase"), "grant_script": STR, "dbm": REF("dbm")}),
    "platform-db-sqlmi": obj(["enabled", "engine", "server", "databases", "dbm"], {
        "enabled": BOOL, "resource_group_name": NSTR, "engine": {"const": "azure-sql-managed-instance"},
        "server": nullable(obj(["id", "name", "fqdn", "port", "auth_mode", "pricing_model"], dict(SERVER_BASE, pricing_model={"enum": ["Regular", "Freemium"]}))),
        "databases": DB_MAP0("relationalDatabase"), "grant_script": STR, "dbm": nullable(REF("dbm"))}),
    "platform-db-sqlvm": obj(["resource_group_name", "engine", "vm", "server", "databases", "dbm"], {
        "resource_group_name": STR, "engine": {"const": "sql-server-on-azure-vm"},
        "vm": obj(["id", "name", "private_ip_address"], {"id": RID, "name": STR, "private_ip_address": STR}),
        "server": obj(["port", "auth_mode", "admin_password_secret_id"], {
            "port": PORT, "auth_mode": {"const": "sql-login"}, "public_network_access_enabled": {"const": False},
            "admin_password_secret_id": SECRET}),
        "databases": DB_MAP("relationalDatabase"), "dbm": REF("dbm")}),
    "platform-db-postgresql": obj(["resource_group_name", "engine", "server", "private_endpoint", "databases", "dbm"], {
        "resource_group_name": STR, "engine": {"const": "postgresql-flexible"},
        "server": obj(["id", "name", "fqdn", "port", "version", "network_mode", "auth_mode", "entra_admin"], dict(
            SERVER_BASE, version=STR, network_mode={"enum": ["vnet", "private-endpoint"]}, auth_mode={"const": "entra-only"},
            server_parameters={"type": "object", "additionalProperties": STR})),
        "private_endpoint": REF("privateEndpoint"),
        "databases": DB_MAP("relationalDatabase"),
        "elastic_cluster": nullable(obj(["id", "fqdn", "port", "database"], {"id": RID, "fqdn": STR, "port": PORT, "database": STR})),
        "grant_script": STR, "dbm": REF("dbm")}),
    "platform-db-mysql": obj(["resource_group_name", "engine", "server", "private_endpoint", "databases", "dbm"], {
        "resource_group_name": STR, "engine": {"const": "mysql-flexible"},
        "server": obj(["id", "name", "fqdn", "port", "version", "network_mode", "auth_mode", "entra_admin"], dict(
            SERVER_BASE, version=STR, network_mode={"enum": ["vnet", "private-endpoint"]})),
        "private_endpoint": REF("privateEndpoint"),
        "databases": DB_MAP("relationalDatabase"), "grant_script": STR, "dbm": REF("dbm")}),
    "platform-db-cosmos-nosql": cosmos("nosql", ["entra-rbac"]),
    "platform-db-cosmos-mongo": cosmos("mongo", ["key"]),
    "platform-db-cosmos-cassandra": cosmos("cassandra", ["key"]),
    "platform-db-cosmos-gremlin": cosmos("gremlin", ["key"]),
    "platform-db-cosmos-table": cosmos("table", ["entra-rbac"]),
    "platform-db-documentdb": obj(["resource_group_name", "engine", "cluster", "auth_mode", "private_endpoint", "databases", "rbac", "dbm"], {
        "resource_group_name": STR, "engine": {"const": "azure-documentdb"},
        "cluster": obj(["id", "name", "host", "port", "public_network_access_enabled", "admin_password_secret_id"], {
            "id": RID, "name": STR, "host": STR, "port": PORT, "public_network_access_enabled": {"const": False},
            "authentication_methods": STRLIST, "admin_password_secret_id": SECRET}),
        "auth_mode": {"const": "entra-oidc"}, "private_endpoint": REF("privateEndpoint"),
        "databases": DB_MAP("logicalStore"), "rbac": RBAC, "dbm": REF("dbm")}),
    "platform-db-cassandra-mi": obj(["enabled", "engine", "cluster", "databases", "dbm"], {
        "enabled": BOOL, "resource_group_name": NSTR, "engine": {"const": "managed-instance-apache-cassandra"},
        "cluster": nullable(obj(["id", "name", "port", "seed_node_ip_addresses", "admin_password_secret_id"], {
            "id": RID, "name": STR, "port": PORT, "seed_node_ip_addresses": STRLIST, "admin_password_secret_id": SECRET})),
        "auth_mode": STR, "databases": {"type": "object"}, "dbm": REF("dbm")}),
    "platform-db-redis": obj(["resource_group_name", "engine", "cache", "auth_mode", "private_endpoint", "databases", "rbac", "dbm"], {
        "resource_group_name": STR, "engine": {"const": "azure-managed-redis"},
        "cache": obj(["id", "name", "hostname", "port", "tls", "access_keys_enabled", "public_network_access_enabled"], {
            "id": RID, "name": STR, "hostname": STR, "port": PORT, "tls": {"const": True},
            "access_keys_enabled": {"const": False}, "public_network_access_enabled": {"const": False},
            "eviction_policy": STR, "persistence": STR}),
        "auth_mode": {"const": "entra-access-policy"}, "private_endpoint": REF("privateEndpoint"),
        "databases": {"type": "object", "additionalProperties": obj(["key_prefix", "owner_identity_name"], {
            "key_prefix": STR, "owner_identity_name": STR, "boundary": STR, "durable": {"const": False}})},
        "rbac": RBAC, "dbm": REF("dbm")}),
    "platform-db-table-storage": obj(["resource_group_name", "engine", "account", "auth_mode", "private_endpoint", "databases", "rbac", "dbm"], {
        "resource_group_name": STR, "engine": {"const": "azure-table-storage"},
        "account": obj(["id", "name", "endpoint", "public_network_access_enabled", "shared_key_enabled"], {
            "id": RID, "name": STR, "endpoint": STR, "port": PORT,
            "public_network_access_enabled": {"const": False}, "shared_key_enabled": {"const": False}}),
        "auth_mode": {"const": "entra-rbac"}, "private_endpoint": REF("privateEndpoint"),
        "databases": DB_MAP("logicalStore"), "rbac": RBAC, "dbm": REF("dbm")}),
    "platform-db-ledger": obj(["resource_group_name", "engine", "ledger", "auth_mode", "private_endpoint", "databases", "rbac", "dbm"], {
        "resource_group_name": STR, "engine": {"const": "azure-confidential-ledger"},
        "ledger": obj(["id", "name", "ledger_endpoint", "identity_service_endpoint", "ledger_type"], {
            "id": RID, "name": STR, "ledger_endpoint": STR, "identity_service_endpoint": STR,
            "ledger_type": {"enum": ["Private", "Public"]}, "public_network_access_enabled": BOOL}),
        "auth_mode": {"const": "entra-ledger-role"}, "private_endpoint": REF("privateEndpoint"),
        "databases": DB_MAP("logicalStore"), "rbac": RBAC, "dbm": REF("dbm")}),
    "platform-db-horizondb": obj(["enabled", "status", "engine", "cluster", "private_endpoint", "databases", "dbm"], {
        "enabled": BOOL, "status": {"enum": ["implemented", "blocked"]}, "blocked_reason": NSTR,
        "resource_group_name": NSTR, "engine": {"const": "azure-horizondb"}, "api_version": STR,
        "cluster": nullable(obj(["id", "name", "port", "auth_mode"], {"id": RID, "name": STR, "fqdn": NSTR, "port": PORT, "auth_mode": STR})),
        "private_endpoint": REF("privateEndpoint"), "databases": {"type": "object"}, "dbm": REF("dbm")}),
    "platform-data-analytics": obj(["resource_group_name", "blob", "adls", "data_explorer", "search", "synapse", "dbm"], {
        "resource_group_name": STR,
        "blob": nullable(obj(["id", "name", "endpoint", "container", "owner_identity_name"], {
            "id": RID, "name": STR, "endpoint": STR, "container": {"const": "adapter"}, "owner_identity_name": STR,
            "public_network_access_enabled": {"const": False}, "shared_key_enabled": {"const": False}})),
        "adls": nullable(obj(["id", "name", "endpoint", "filesystem", "owner_identity_name"], {
            "id": RID, "name": STR, "endpoint": STR, "filesystem": {"const": "adapter"}, "owner_identity_name": STR,
            "public_network_access_enabled": {"const": False}, "shared_key_enabled": {"const": False}})),
        "data_explorer": nullable(obj(["id", "uri", "database", "table", "owner_identity_name"], {
            "id": RID, "uri": STR, "database": {"const": "adapter"}, "table": STR, "owner_identity_name": STR,
            "public_network_access_enabled": {"const": False}})),
        "search": nullable(obj(["id", "endpoint", "index", "owner_identity_name"], {
            "id": RID, "endpoint": STR, "index": STR, "owner_identity_name": STR,
            "local_auth_enabled": {"const": False}, "public_network_access_enabled": {"const": False}})),
        "synapse": nullable(obj(["id", "name"], {"id": RID, "name": STR, "public_network_access_enabled": {"const": False}})),
        "dbm": REF("dbm")}),
}


def main():
    for name, schema in CONTRACTS.items():
        doc = {"$schema": "https://json-schema.org/draft/2020-12/schema",
               "$id": f"{name}.v1.schema.json",
               "title": f"{name} contract v1",
               "description": "Produced by platform/data (see the root README). No secrets: Key Vault versionless secret IDs only.",
               **schema, "$defs": DEFS}
        (OUT / f"{name}.v1.schema.json").write_text(json.dumps(doc, indent=2) + "\n")
        print("wrote", OUT / f"{name}.v1.schema.json")


if __name__ == "__main__":
    main()
