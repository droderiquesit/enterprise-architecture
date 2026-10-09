-- platform/data/postgresql/scripts/elastic-distribute.sql (optional Elastic Cluster only)
-- Distributes the adapter boundary table across the Citus worker nodes. The table itself is created by
-- hello-dbadapter-postgresql-elastic migrations; this runs after them, as the Entra admin, in db `adapter`:
--   psql "host=<cluster fqdn> port=5432 dbname=adapter user=<admin group> sslmode=require" -f elastic-distribute.sql
\set ON_ERROR_STOP on
CREATE SCHEMA IF NOT EXISTS adapter;
CREATE TABLE IF NOT EXISTS adapter.records (
  id          text        NOT NULL,
  payload     jsonb       NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id)
);
SELECT create_distributed_table('adapter.records', 'id')
WHERE NOT EXISTS (SELECT 1 FROM pg_dist_partition WHERE logicalrelid = 'adapter.records'::regclass);
