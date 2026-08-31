-- =============================================================================
-- NestWise — 05_user_prefs_min_rating.sql
--
-- One-time migration for an EXISTING NestWise schema. Fresh installs don't need
-- it: 01_tables.sql already creates user_preferences with min_rating.
--
-- WHY
-- ---
-- Adds a saved "minimum acceptable rating" preference alongside cuisine, budget
-- and weather. It is applied as a FILTER, not a scoring bonus, by both
-- recommendation surfaces:
--   * Oracle:  restaurant_pkg.recommend_for_user
--   * MongoDB: the proxy's /api/listings/recommend/for-user (?rating=)
-- Same semantics as Restaurant Finder's existing Min Rating control, so the
-- saved preference and the ad-hoc filter mean the same thing.
--
-- Existing rows default to 0, which filters nothing — so behaviour is unchanged
-- for anyone who never sets it.
--
-- Who:   nestwise (schema owner)
-- What:  @05_user_prefs_min_rating.sql
-- Where: SQLcl or SQL*Plus against the NestWise schema via the SCAN listener
--
-- ORDER: run this BEFORE re-running 03_packages.sql — prefs_pkg's new
-- min_rating references won't compile against a table that lacks the column.
-- =============================================================================

SET SERVEROUTPUT ON

ALTER TABLE user_preferences ADD (
    min_rating NUMBER(2,1) DEFAULT 0
);

ALTER TABLE user_preferences ADD CONSTRAINT ck_user_prefs_min_rating
    CHECK (min_rating BETWEEN 0 AND 5);

-- Backfill any pre-existing rows explicitly. DEFAULT only applies to new rows
-- inserted after the ALTER on older Oracle releases, so don't rely on it.
UPDATE user_preferences SET min_rating = 0 WHERE min_rating IS NULL;
COMMIT;

PROMPT === user_preferences after migration ===
SELECT app_user, preferred_cuisine, budget_price_range, weather_preference, min_rating
FROM   user_preferences
ORDER  BY app_user;

-- =============================================================================
-- NEXT STEPS (this script does not do these for you):
--
-- 1. Recompile the packages:        @03_packages.sql
--    prefs_pkg.get_preferences now returns min_rating, and save_preferences
--    takes p_min_rating (defaulted to 0, so existing callers still compile).
--
-- 2. Deploy the updated proxy and restart it — routes/listings.js now reads a
--    `rating` query parameter on the recommend endpoint:
--       systemctl restart nestwise-proxy
--    Check ownership after copying the file; a root-owned file the `nestwise`
--    service account cannot read will fail the service with EACCES.
--
-- 3. In APEX: add the `rating` parameter to RDS_LISTINGS_RECOMMEND at the
--    OPERATION level (source level alone does not reach the request), add the
--    item to User Profile, and bind it on Stay / Listings.
--    See apex/page_plan.md for the full sequence.
-- =============================================================================
