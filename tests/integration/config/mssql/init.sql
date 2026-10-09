-- SQL Server bootstrap for the local e2e run: only the DATABASES are created here. Schemas and tables are
-- created by the applications' own idempotent startup migrations (orders-api: schema `orders`,
-- hello-durable: schema `fulfillment`). The Service Bus emulator creates its own databases on the same server.
IF DB_ID(N'orders') IS NULL CREATE DATABASE orders;
IF DB_ID(N'fulfillment') IS NULL CREATE DATABASE fulfillment;
GO
