-- Least-privilege database account for the StockMate server.
-- Run once as a superuser after schema.sql / functions.sql / seed.sql:
--     psql -d stockmate -v pw="'choose-a-long-random-password'" -f app_role.sql
-- Then start the server with DB_USER=stockmate_app and DB_PASS=<that password> instead of the postgres superuser.
-- The server then cannot create/drop tables, change functions, read other databases or touch system settings, so a
-- mistake or attack in the web layer cannot become full control of the database.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stockmate_app') THEN
    CREATE ROLE stockmate_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
  END IF;
END $$;
ALTER ROLE stockmate_app PASSWORD :pw;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO stockmate_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO stockmate_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO stockmate_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO stockmate_app;

-- append-only tables: no updates or deletes even if the application were tricked
REVOKE UPDATE, DELETE ON audit_log, stock_move, payment FROM stockmate_app;
-- the user table: the server may only change what the user functions change
REVOKE UPDATE ON app_user FROM stockmate_app;
GRANT UPDATE (password_hash, must_change, active) ON app_user TO stockmate_app;
REVOKE DELETE ON app_user, company FROM stockmate_app;
