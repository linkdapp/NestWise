-- =============================================================================
-- NestWise — 99_seed_data.sql
-- Initial load. Delegates to admin_pkg.reload_oracle_seed_data so the
-- install-time seed and the Admin page's "Reload Seed Data" button are
-- guaranteed to produce the exact same dataset (single source of truth for
-- the seed rows lives in db/oracle/03_packages.sql — run that first).
-- Safe to re-run any time; it deletes and reinserts.
--
-- Washington, D.C. seed: 28 neighborhoods, 87 restaurants, 14 theaters,
-- plus sample user_favorites for DEMO / ADMIN / APEX_PUBLIC_USER / TESTUSER.
-- =============================================================================

SET SERVEROUTPUT ON

BEGIN
    admin_pkg.reload_oracle_seed_data;
    DBMS_OUTPUT.PUT_LINE('NestWise Oracle seed data loaded: 28 Washington neighborhoods, 87 restaurants, 14 theaters, sample user favorites.');
END;
/
