-- platform/data/cassandra-mi/scripts/create-keyspace.cql
-- Managed Instance for Apache Cassandra has no ARM resource for keyspaces, so the boundary keyspace is
-- created over CQL after apply by the pipeline (private agent), authenticating as the cluster admin whose
-- password is in Key Vault (contract.cluster.admin_password_secret_id):
--   cqlsh <seed node ip> 9042 --ssl -u cassandra -p "$(az keyvault secret show --id <secret id> --query value -o tsv)" \
--         -f platform/data/cassandra-mi/scripts/create-keyspace.cql
CREATE KEYSPACE IF NOT EXISTS adapter
  WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'dc1': 3};
CREATE ROLE IF NOT EXISTS dbadapter WITH LOGIN = true AND PASSWORD = '@DBADAPTER_PASSWORD@';
GRANT ALL PERMISSIONS ON KEYSPACE adapter TO dbadapter;
