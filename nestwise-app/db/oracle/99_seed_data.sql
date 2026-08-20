-- =============================================================================
-- NestWise — 99_seed_data.sql
-- Initial load. Delegates to admin_pkg.reload_oracle_seed_data so the
-- install-time seed and the Admin page's "Reload Seed Data" button are
-- guaranteed to produce the exact same dataset (single source of truth for
-- the seed rows lives in db/oracle/03_packages.sql — run that first).
-- Safe to re-run any time; it deletes and reinserts.
-- =============================================================================

SET SERVEROUTPUT ON

BEGIN
    admin_pkg.reload_oracle_seed_data;
    DBMS_OUTPUT.PUT_LINE('NestWise Oracle seed data loaded: 8 neighborhoods, ~20 restaurants, 5 theaters.');
END;
/
