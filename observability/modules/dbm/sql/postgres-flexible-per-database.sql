-- Run in EVERY monitored database (idempotent). Monitoring role: datadog (password) or the managed
-- identity principal name (Entra) - set psql variable dd_role accordingly (default datadog).
\if :{?dd_role}
\else
\set dd_role datadog
\endif
CREATE SCHEMA IF NOT EXISTS datadog;
GRANT USAGE ON SCHEMA datadog TO :"dd_role";
GRANT USAGE ON SCHEMA public TO :"dd_role";
CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public;

CREATE OR REPLACE FUNCTION datadog.explain_statement(
   l_query TEXT,
   OUT explain JSON
)
RETURNS SETOF JSON AS
$$
DECLARE
curs REFCURSOR;
plan JSON;

BEGIN
   SET TRANSACTION READ ONLY;

   OPEN curs FOR EXECUTE pg_catalog.concat('EXPLAIN (FORMAT JSON) ', l_query);
   FETCH curs INTO plan;
   CLOSE curs;
   RETURN QUERY SELECT plan;
END;
$$
LANGUAGE 'plpgsql'
RETURNS NULL ON NULL INPUT
SECURITY DEFINER;
