-- platform/data/postgresql/scripts/grant-db-users.sql
-- Registers one workload managed identity as a Microsoft Entra role and makes it owner of its
-- boundary schema in one database. Run once per entry in contract.databases.<db>.grants.
--
-- Run by the pipeline AFTER `terraform apply`, signed in as a member of the server's Entra admin
-- group (settings.entra_admin). Step 1 must run in the `postgres` database, step 2 in the target db:
--
--   export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)
--   psql "host=<fqdn> dbname=postgres user=<admin group name> sslmode=require" \
--        -v identity=hello-catalog-api -v object_id=<principal id> -v step=principal -f grant-db-users.sql
--   psql "host=<fqdn> dbname=catalog user=<admin group name> sslmode=require" \
--        -v identity=hello-catalog-api -v object_id=<principal id> -v schema=catalog -v step=schema -f grant-db-users.sql
--
-- pgaadauth_create_principal_with_oid binds the role to the identity's object ID ('service' =
-- service principal / managed identity). Tables are created by application migrations only.
\set ON_ERROR_STOP on

SELECT :'step' = 'principal' AS is_principal_step \gset
\if :is_principal_step
  SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'identity')
              THEN 'exists'
              ELSE (SELECT 'created: ' || pgaadauth_create_principal_with_oid(:'identity', :'object_id', 'service', false, false)) END;
\else
  SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'identity') \gexec
  SELECT format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', :'schema', :'identity') \gexec
  SELECT format('ALTER SCHEMA %I OWNER TO %I', :'schema', :'identity') \gexec
  SELECT format('REVOKE CREATE ON SCHEMA public FROM PUBLIC') \gexec
\endif
