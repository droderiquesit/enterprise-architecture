-- platform/data/cassandra-mi/scripts/create-keyspace.cql
-- Managed Instance for Apache Cassandra has no ARM resource for keyspaces, so the boundary keyspace is
-- created over CQL after apply by the pipeline (private agent), authenticating as the cluster admin whose
-- password is in Delinea DSV (contract.cluster.admin_password_secret_id = dsv://<prefix>/<env>/cassandra-mi-admin-password):
--   python3 tools/secrets/fetch.py exec --env <env> --map CQL_PW=cassandra-mi-admin-password \
--     --map DBA_PW=cassandra-mi-dbadapter-password -- bash -c 'sed "s/@DBADAPTER_PASSWORD@/$DBA_PW/" \
--     platform/data/cassandra-mi/scripts/create-keyspace.cql | cqlsh <seed node ip> 9042 --ssl -u cassandra -p "$CQL_PW"'
--   (values live only in that one process environment; never echo them)
CREATE KEYSPACE IF NOT EXISTS adapter
  WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'dc1': 3};
CREATE ROLE IF NOT EXISTS dbadapter WITH LOGIN = true AND PASSWORD = '@DBADAPTER_PASSWORD@';
GRANT ALL PERMISSIONS ON KEYSPACE adapter TO dbadapter;
