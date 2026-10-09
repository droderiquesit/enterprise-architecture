-- Datadog DBM with a managed identity on Azure SQL Database (Entra auth; no password anywhere).
-- Source: https://docs.datadoghq.com/database_monitoring/guide/managed_authentication/
-- Run as the Entra admin. Replace <MANAGED_IDENTITY_NAME> with the identity's display name.
-- Step 1 - in [master]:
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '<MANAGED_IDENTITY_NAME>')
    CREATE LOGIN [<MANAGED_IDENTITY_NAME>] FROM EXTERNAL PROVIDER;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '<MANAGED_IDENTITY_NAME>')
    CREATE USER [<MANAGED_IDENTITY_NAME>] FOR LOGIN [<MANAGED_IDENTITY_NAME>];
ALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER [<MANAGED_IDENTITY_NAME>];
ALTER SERVER ROLE ##MS_DefinitionReader## ADD MEMBER [<MANAGED_IDENTITY_NAME>];
-- Step 2 - in EVERY monitored database:
-- IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '<MANAGED_IDENTITY_NAME>') CREATE USER [<MANAGED_IDENTITY_NAME>] FOR LOGIN [<MANAGED_IDENTITY_NAME>];
