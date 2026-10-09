-- Datadog DBM login for SQL Server on an Azure VM (self-hosted SQL Server 2014+), password auth.
-- Source: https://docs.datadoghq.com/database_monitoring/setup_sql_server/selfhosted/
-- The check can run from the VM's own Agent (modules/host-agents) or from the observability-subnet Agent.
USE [master];
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = 'datadog')
    CREATE LOGIN datadog WITH PASSWORD = '__DATADOG_PASSWORD__';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'datadog')
    CREATE USER datadog FOR LOGIN datadog;
GRANT CONNECT ANY DATABASE TO datadog;
GRANT VIEW SERVER STATE TO datadog;
GRANT VIEW ANY DEFINITION TO datadog;
