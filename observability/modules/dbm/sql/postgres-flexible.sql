-- Datadog Database Monitoring: least-privilege monitoring user for Azure Database for PostgreSQL
-- Flexible Server (PostgreSQL 15+), password authentication.
-- Source: https://docs.datadoghq.com/database_monitoring/setup_postgres/azure/
-- Server parameters required first (owned by the PostgreSQL platform root):
--   azure.extensions += PG_STAT_STATEMENTS ; shared_preload_libraries += pg_stat_statements
--   pg_stat_statements.track = ALL ; track_activity_query_size = 4096 ; track_io_timing = on (recommended)
-- Run as the server admin with psql, the password injected from Delinea DSV (dsv secret get, or tools/secrets/fetch.py on a self-hosted agent) (never committed):
--   psql "host=<fqdn> dbname=postgres sslmode=require" -v dd_password="$(python3 tools/secrets/fetch.py ...)" -f postgres-flexible.sql
-- Then run postgres-flexible-per-database.sql in EVERY database to monitor (idempotent).
SELECT format('CREATE ROLE datadog WITH LOGIN PASSWORD %L', :'dd_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'datadog') \gexec
SELECT format('ALTER ROLE datadog WITH LOGIN PASSWORD %L', :'dd_password') \gexec
ALTER ROLE datadog INHERIT;
GRANT pg_monitor TO datadog;
\ir postgres-flexible-per-database.sql
