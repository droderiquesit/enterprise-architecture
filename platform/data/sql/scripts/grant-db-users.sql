-- platform/data/sql/scripts/grant-db-users.sql
-- Creates (idempotently) a contained database user for one workload managed identity and adds it
-- to the given database roles. Run once per entry in contract.databases.<db>.grants.
--
-- Executed by the pipeline AFTER `terraform apply` of platform-db-sql, connected to the target
-- database (not master) with an Entra access token of an identity that is a member of the
-- server's Entra admin group (settings.entra_admin), e.g.:
--
--   TOKEN=$(az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
--   sqlcmd -S tcp:<server fqdn>,1433 -d <db> -G --access-token "$TOKEN" -b \
--     -v IDENTITY_NAME="hello-orders-api" CLIENT_ID="<client id>" \
--        DB_ROLES="db_datareader,db_datawriter,db_ddladmin" SCHEMA_NAME="orders" \
--     -i platform/data/sql/scripts/grant-db-users.sql
--
-- `WITH SID = <client id>, TYPE = E` creates the user from the managed identity's client (application)
-- ID without a Microsoft Graph lookup, so the server identity does NOT need the Directory Readers role.
-- Business tables are created by application migrations, never here. Synthetic data only.
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @name   sysname        = N'$(IDENTITY_NAME)';
DECLARE @client uniqueidentifier = CAST(N'$(CLIENT_ID)' AS uniqueidentifier);
DECLARE @roles  nvarchar(4000) = N'$(DB_ROLES)';
DECLARE @schema sysname        = N'$(SCHEMA_NAME)';
DECLARE @sql    nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name)
BEGIN
  SET @sql = N'CREATE USER ' + QUOTENAME(@name) + N' WITH SID = '
           + CONVERT(nvarchar(64), CONVERT(varbinary(16), @client), 1) + N', TYPE = E;';
  EXEC sys.sp_executesql @sql;
END;

-- The boundary schema is owned by dbo; owners get DDL on it through db_ddladmin.
IF LEN(@schema) > 0 AND NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = @schema)
BEGIN
  SET @sql = N'CREATE SCHEMA ' + QUOTENAME(@schema) + N' AUTHORIZATION dbo;';
  EXEC sys.sp_executesql @sql;
END;

DECLARE @role sysname;
DECLARE role_cursor CURSOR LOCAL FAST_FORWARD FOR
  SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@roles, N',') WHERE LEN(LTRIM(RTRIM(value))) > 0;
OPEN role_cursor;
FETCH NEXT FROM role_cursor INTO @role;
WHILE @@FETCH_STATUS = 0
BEGIN
  IF @role NOT IN (N'db_datareader', N'db_datawriter', N'db_ddladmin')
    THROW 50001, N'Only db_datareader, db_datawriter and db_ddladmin may be granted by this script.', 1;
  IF IS_ROLEMEMBER(@role, @name) = 0
  BEGIN
    SET @sql = N'ALTER ROLE ' + QUOTENAME(@role) + N' ADD MEMBER ' + QUOTENAME(@name) + N';';
    EXEC sys.sp_executesql @sql;
  END;
  FETCH NEXT FROM role_cursor INTO @role;
END;
CLOSE role_cursor;
DEALLOCATE role_cursor;

PRINT CONCAT(N'granted ', @roles, N' to ', @name, N' in ', DB_NAME());
