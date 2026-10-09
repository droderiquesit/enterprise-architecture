-- Datadog DBM with Microsoft Entra (managed identity) authentication on PostgreSQL Flexible Server.
-- Source: https://docs.datadoghq.com/database_monitoring/guide/managed_authentication/
-- Run as the Entra administrator of the server, connected to database "postgres":
--   psql "host=<fqdn> dbname=postgres user=<entra-admin> sslmode=require" -v dd_role=<IDENTITY_NAME> -f postgres-flexible-entra.sql
-- The Agent config uses azure.managed_authentication.client_id = <identity client id>, username = <IDENTITY_NAME>.
SELECT format('SELECT * FROM pgaadauth_create_principal(%L, false, false)', :'dd_role')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'dd_role') \gexec
GRANT pg_monitor TO :"dd_role";
\ir postgres-flexible-per-database.sql
