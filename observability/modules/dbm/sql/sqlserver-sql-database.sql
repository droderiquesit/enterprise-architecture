-- Datadog DBM login/user for Azure SQL Database (password auth).
-- Source: https://docs.datadoghq.com/database_monitoring/setup_sql_server/azure/
-- Step 1 - run in [master] (replace __DATADOG_PASSWORD__ from Delinea DSV (dsv secret get, or tools/secrets/fetch.py on a self-hosted agent) at execution time):
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = 'datadog')
    CREATE LOGIN datadog WITH PASSWORD = '__DATADOG_PASSWORD__';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'datadog')
    CREATE USER datadog FOR LOGIN datadog;
ALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER datadog;
ALTER SERVER ROLE ##MS_DefinitionReader## ADD MEMBER datadog;
-- Step 2 - run in EVERY monitored user database (e.g. orders, fulfillment):
-- IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'datadog') CREATE USER datadog FOR LOGIN datadog;
