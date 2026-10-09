# platform/data/sqlvm/scripts/init-adapter-db.ps1
# Executed by azurerm_virtual_machine_run_command (as SYSTEM) after SQL IaaS registration.
# Creates database [adapter] and the least-privileged SQL login [dbadapter] used by
# hello-dbadapter-sqlvm. Idempotent. Passwords arrive as protected parameters (never logged).
param(
  [Parameter(Mandatory = $true)][string]$AdminLogin,
  [Parameter(Mandatory = $true)][string]$AdminPassword,
  [Parameter(Mandatory = $true)][string]$AdapterPassword
)
$ErrorActionPreference = 'Stop'

$query = @"
IF DB_ID(N'adapter') IS NULL CREATE DATABASE [adapter];
GO
IF SUSER_ID(N'dbadapter') IS NULL
  CREATE LOGIN [dbadapter] WITH PASSWORD = N'$AdapterPassword', CHECK_POLICY = ON, DEFAULT_DATABASE = [adapter];
ELSE
  ALTER LOGIN [dbadapter] WITH PASSWORD = N'$AdapterPassword';
GO
USE [adapter];
IF USER_ID(N'dbadapter') IS NULL CREATE USER [dbadapter] FOR LOGIN [dbadapter];
IF SCHEMA_ID(N'adapter') IS NULL EXEC(N'CREATE SCHEMA [adapter] AUTHORIZATION dbo');
ALTER ROLE db_datareader ADD MEMBER [dbadapter];
ALTER ROLE db_datawriter ADD MEMBER [dbadapter];
ALTER ROLE db_ddladmin ADD MEMBER [dbadapter];
GO
"@

$env:SQLCMDPASSWORD = $AdminPassword
try {
  & sqlcmd -S "tcp:localhost,1433" -U $AdminLogin -C -b -Q $query | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed with exit code $LASTEXITCODE" }
  Write-Output "adapter database and dbadapter login are present"
}
finally {
  Remove-Item Env:\SQLCMDPASSWORD -ErrorAction SilentlyContinue
}
