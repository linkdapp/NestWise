-- =============================================================================
-- NestWise — 04_neighborhood_id_stability.sql
--
-- One-time migration for an EXISTING NestWise schema. Fresh installs don't
-- need this: 01_tables.sql already creates neighborhood_id as a plain NUMBER.
--
-- WHY THIS EXISTS
-- ---------------
-- neighborhoods.neighborhood_id was originally NUMBER GENERATED ALWAYS AS
-- IDENTITY. MongoDB's listings, weather_snapshots, and mflix_movies collections
-- all reference that integer as their cross-database join key. But
-- admin_pkg.reload_oracle_seed_data does DELETE + INSERT, and DELETE does not
-- reset an identity sequence -- so every reload produced a fresh, higher range
-- (1-28, then 9-36, then 37-64...) while MongoDB kept the original 1-28
-- numbering. Result: Mongo-backed regions either returned nothing, or -- worse
-- -- returned a DIFFERENT neighborhood's data that happened to occupy the same
-- ID, which looks plausible and passes a casual eyeball check.
--
-- The fix is to stop generating the key at all. These 28 rows come from a seed
-- script and nothing in the application inserts a neighborhood at runtime, so
-- a generated key buys nothing and costs cross-database integrity. After this
-- migration the IDs are a property of the seed data, identical on every
-- install and every reload, and db/mongodb/remap_neighborhood_ids.js is no
-- longer needed.
--
-- ORDER OF OPERATIONS
-- -------------------
-- Run this BEFORE re-running the updated admin_pkg. Dropping the identity is
-- what makes the explicit-ID INSERTs in the new reload_oracle_seed_data legal
-- (an IDENTITY ALWAYS column rejects them with ORA-32795).
--
-- Who:   nestwise (the schema owner -- no DBA privileges required)
-- What:  @04_neighborhood_id_stability.sql
-- Where: SQLcl or SQL*Plus, connected to the NestWise schema via the SCAN
--        listener, e.g.
--        sqlplus nestwise@//scan-usatclust1.usat.com:1521/apexdb_rw
--
-- NOTE: DROP IDENTITY is one-way. The sequence generator is removed and cannot
-- be re-attached with ALTER; restoring it would mean recreating the table.
-- That is the intended outcome here, not a side effect.
-- =============================================================================

SET SERVEROUTPUT ON

-- 1. Show the current (drifted) state, so the before/after is on the record.
PROMPT === neighborhood_id range BEFORE migration ===
SELECT MIN(neighborhood_id) AS min_id,
       MAX(neighborhood_id) AS max_id,
       COUNT(*)             AS row_count
FROM   neighborhoods;

-- 2. Drop the identity property. Documented Oracle 12c+ syntax.
ALTER TABLE neighborhoods MODIFY (neighborhood_id DROP IDENTITY);

-- 3. Reload the seed data using the updated package, which now supplies
--    neighborhood_id explicitly as 1-28. This deletes and reinserts
--    neighborhoods, restaurants, theaters, and user_favorites.
--
--    Run db/oracle/03_packages.sql first if you have not already -- this step
--    depends on the updated reload_oracle_seed_data.
BEGIN
    admin_pkg.reload_oracle_seed_data;
END;
/

-- 4. Confirm. Expect min_id = 1, max_id = 28, row_count = 28.
PROMPT === neighborhood_id range AFTER migration ===
SELECT MIN(neighborhood_id) AS min_id,
       MAX(neighborhood_id) AS max_id,
       COUNT(*)             AS row_count
FROM   neighborhoods;

-- 5. Spot-check the two neighborhoods used throughout the build notes.
--    Expect Georgetown = 1 and Barracks Row = 27, matching
--    db/mongodb/schema_notes.md's table.
PROMPT === spot check against schema_notes.md ===
SELECT neighborhood_id, name
FROM   neighborhoods
WHERE  name IN ('Georgetown', 'Barracks Row')
ORDER  BY neighborhood_id;

-- =============================================================================
-- AFTERWARDS: re-seed MongoDB back to its original 1-28 numbering.
--
-- If remap_neighborhood_ids.js was run previously, MongoDB is currently offset
-- (9-36) to match Oracle's old drifted IDs. Oracle is now back at 1-28, so
-- MongoDB needs to go back too. The simplest way is a plain reseed, which
-- writes the original numbering:
--
--   curl -X POST -H "X-Nestwise-Admin-Token: <token>" \
--        http://localhost:4000/api/admin/reload
--
-- After this migration, that reload is safe to run on its own -- it no longer
-- needs to be followed by the remap script, because Oracle's IDs no longer
-- move. db/mongodb/remap_neighborhood_ids.js is kept only as a record of the
-- original fix; it should not be needed again.
-- =============================================================================
