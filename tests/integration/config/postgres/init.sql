-- PostgreSQL bootstrap for the local e2e run. POSTGRES_DB creates `catalog` (hello-catalog-api owns its schema
-- via its own migrations); hello-dbadapter-postgresql gets its own database `adapter` (one boundary per family).
CREATE DATABASE adapter;
