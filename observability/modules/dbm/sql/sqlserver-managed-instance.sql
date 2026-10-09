-- Datadog DBM login for Azure SQL Managed Instance (password auth).
-- Source: https://docs.datadoghq.com/database_monitoring/setup_sql_server/azure/
USE [master];
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = 'datadog')
    CREATE LOGIN datadog WITH PASSWORD = '__DATADOG_PASSWORD__';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'datadog')
    CREATE USER datadog FOR LOGIN datadog;
GRANT CONNECT ANY DATABASE TO datadog;
GRANT VIEW SERVER STATE TO datadog;
GRANT VIEW ANY DEFINITION TO datadog;
-- Only for SQL Server Agent / log shipping monitoring:
-- USE [msdb]; IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'datadog') CREATE USER datadog FOR LOGIN datadog; GRANT SELECT TO datadog;
