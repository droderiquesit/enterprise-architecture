-- Datadog Database Monitoring user for Azure Database for MySQL Flexible Server (password auth;
-- Entra managed identity is not supported by the MySQL DBM integration).
-- Source: https://docs.datadoghq.com/database_monitoring/setup_mysql/azure/
-- Server parameter required (MySQL platform root): performance_schema = ON (restart). Azure enables the
-- events_statements_* consumers by default. Replace __DATADOG_PASSWORD__ at execution time from Delinea DSV (dsv secret get, or tools/secrets/fetch.py on a self-hosted agent)
-- (e.g. sed in the pipeline step); never commit the rendered file.
CREATE USER IF NOT EXISTS datadog@'%' IDENTIFIED BY '__DATADOG_PASSWORD__';
ALTER USER datadog@'%' IDENTIFIED BY '__DATADOG_PASSWORD__';
ALTER USER datadog@'%' WITH MAX_USER_CONNECTIONS 5;
GRANT REPLICATION CLIENT ON *.* TO datadog@'%';
GRANT PROCESS ON *.* TO datadog@'%';
GRANT SELECT ON performance_schema.* TO datadog@'%';
CREATE SCHEMA IF NOT EXISTS datadog;
GRANT EXECUTE ON datadog.* TO datadog@'%';
GRANT SELECT ON mysql.innodb_index_stats TO datadog@'%';

DROP PROCEDURE IF EXISTS datadog.explain_statement;
DELIMITER $$
CREATE PROCEDURE datadog.explain_statement(IN query TEXT)
    SQL SECURITY DEFINER
BEGIN
    SET @explain := CONCAT('EXPLAIN FORMAT=json ', query);
    PREPARE stmt FROM @explain;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
END $$
DELIMITER ;
-- Repeat the procedure in each application schema for explain plans, e.g. for schema `catalog`:
--   CREATE PROCEDURE catalog.explain_statement(...) (same body) ; GRANT EXECUTE ON PROCEDURE catalog.explain_statement TO datadog@'%';
