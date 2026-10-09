-- Enterprise Hello / hello-orders-api — idempotent schema migration for Azure SQL database `orders`.
-- Safe to run on every start and concurrently from several replicas (serialised with sp_getapplock).
SET XACT_ABORT ON;
BEGIN TRANSACTION;
DECLARE @lock int;
EXEC @lock = sp_getapplock @Resource = N'hello-orders-migrations', @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
IF @lock < 0 THROW 50001, 'Could not acquire migration lock', 1;

IF SCHEMA_ID(N'orders') IS NULL EXEC(N'CREATE SCHEMA orders AUTHORIZATION dbo');

IF OBJECT_ID(N'orders.orders', N'U') IS NULL
BEGIN
    CREATE TABLE orders.orders (
        id                   uniqueidentifier NOT NULL CONSTRAINT PK_orders PRIMARY KEY NONCLUSTERED,
        sku                  nvarchar(64)     NOT NULL,
        quantity             int              NOT NULL CONSTRAINT CK_orders_quantity CHECK (quantity > 0),
        unit_price           decimal(18, 2)   NOT NULL,
        amount               decimal(18, 2)   NOT NULL,
        status               nvarchar(32)     NOT NULL,
        customer_ref         nvarchar(128)    NOT NULL,
        created_at           datetimeoffset(3) NOT NULL,
        updated_at           datetimeoffset(3) NOT NULL,
        idempotency_key      nvarchar(128)    NULL,
        status_reason        nvarchar(512)    NULL,
        workflow_instance_id nvarchar(128)    NULL
    );
    CREATE CLUSTERED INDEX CIX_orders_created_at ON orders.orders (created_at);
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_orders_idempotency_key' AND object_id = OBJECT_ID(N'orders.orders'))
    CREATE UNIQUE INDEX UX_orders_idempotency_key ON orders.orders (idempotency_key) WHERE idempotency_key IS NOT NULL;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_orders_status' AND object_id = OBJECT_ID(N'orders.orders'))
    CREATE INDEX IX_orders_status ON orders.orders (status) INCLUDE (updated_at);

IF OBJECT_ID(N'orders.idempotency', N'U') IS NULL
BEGIN
    CREATE TABLE orders.idempotency (
        idempotency_key nvarchar(128)     NOT NULL CONSTRAINT PK_idempotency PRIMARY KEY,
        request_hash    char(64)          NOT NULL,
        order_id        uniqueidentifier  NOT NULL,
        created_at      datetimeoffset(3) NOT NULL
    );
END;

IF OBJECT_ID(N'orders.schema_version', N'U') IS NULL
    CREATE TABLE orders.schema_version (version int NOT NULL PRIMARY KEY, applied_at datetimeoffset(3) NOT NULL);

IF NOT EXISTS (SELECT 1 FROM orders.schema_version WHERE version = 1)
    INSERT INTO orders.schema_version (version, applied_at) VALUES (1, SYSDATETIMEOFFSET());

COMMIT TRANSACTION;
