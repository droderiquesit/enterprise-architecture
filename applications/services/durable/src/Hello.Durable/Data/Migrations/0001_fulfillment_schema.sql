-- Enterprise Hello / hello-durable — idempotent migration for SQL schema `fulfillment`
-- (business data only; Durable Functions runtime state lives in Azure Storage, not here).
SET XACT_ABORT ON;
BEGIN TRANSACTION;
DECLARE @lock int;
EXEC @lock = sp_getapplock @Resource = N'hello-fulfillment-migrations', @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
IF @lock < 0 THROW 50001, 'Could not acquire migration lock', 1;

IF SCHEMA_ID(N'fulfillment') IS NULL EXEC(N'CREATE SCHEMA fulfillment AUTHORIZATION dbo');

IF OBJECT_ID(N'fulfillment.fulfillments', N'U') IS NULL
    CREATE TABLE fulfillment.fulfillments (
        order_id             uniqueidentifier  NOT NULL CONSTRAINT PK_fulfillments PRIMARY KEY,
        sku                  nvarchar(64)      NOT NULL,
        quantity             int               NOT NULL,
        amount               decimal(18, 2)    NOT NULL,
        status               nvarchar(32)      NOT NULL,
        reason               nvarchar(512)     NULL,
        payment_id           nvarchar(128)     NULL,
        workflow_instance_id nvarchar(128)     NOT NULL,
        created_at           datetimeoffset(3) NOT NULL,
        updated_at           datetimeoffset(3) NOT NULL
    );

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fulfillments_updated_at' AND object_id = OBJECT_ID(N'fulfillment.fulfillments'))
    CREATE INDEX IX_fulfillments_updated_at ON fulfillment.fulfillments (updated_at) INCLUDE (status);

IF OBJECT_ID(N'fulfillment.batch_runs', N'U') IS NULL
    CREATE TABLE fulfillment.batch_runs (
        batch_id     nvarchar(128)     NOT NULL CONSTRAINT PK_batch_runs PRIMARY KEY,
        items        int               NOT NULL,
        succeeded    int               NOT NULL,
        failed       int               NOT NULL,
        total_value  decimal(18, 2)    NOT NULL,
        started_at   datetimeoffset(3) NOT NULL,
        completed_at datetimeoffset(3) NOT NULL
    );

IF OBJECT_ID(N'fulfillment.reconciliation_runs', N'U') IS NULL
    CREATE TABLE fulfillment.reconciliation_runs (
        run_id               nvarchar(128)     NOT NULL CONSTRAINT PK_reconciliation_runs PRIMARY KEY,
        since                datetimeoffset(3) NOT NULL,
        completed_at         datetimeoffset(3) NOT NULL,
        orders_checked       int               NOT NULL,
        fulfillments_checked int               NOT NULL,
        matched              int               NOT NULL,
        missing_fulfillment  int               NOT NULL,
        status_mismatch      int               NOT NULL,
        orphan_fulfillment   int               NOT NULL,
        stuck_orders         int               NOT NULL,
        samples              nvarchar(max)     NULL
    );

COMMIT TRANSACTION;
