-- =============================================================================
-- NestWise — 03_packages.sql
-- One package per major entity/feature area. Business logic lives here, not
-- scattered across APEX page processes, so it's testable and reusable from
-- ORDS. Deliberately not a generic data-access layer — only the operations
-- the pages actually call.
--
-- Seed data targets Washington, D.C. (28 neighborhoods, 87 restaurants,
-- 14 theaters). See admin_pkg.reload_oracle_seed_data.
-- =============================================================================

-- =============================================================================
-- NBHD_PKG — Neighborhood Explorer
-- =============================================================================
CREATE OR REPLACE PACKAGE nbhd_pkg AS

    -- Browsable list for the Neighborhood Explorer IR, with a rollup of
    -- avg restaurant rating / restaurant count / theater count per row.
    -- p_search is applied to name (case-insensitive contains).
    FUNCTION list_neighborhoods(
        p_city    IN neighborhoods.city%TYPE,
        p_search  IN VARCHAR2 DEFAULT NULL
    ) RETURN SYS_REFCURSOR;

    -- Stats block for the Neighborhood Detail page (Oracle half — the Mongo
    -- half of this page, listings/movies/weather, is fetched separately via
    -- the REST Data Sources; see apex/page_plan.md).
    FUNCTION get_stats(p_neighborhood_id IN neighborhoods.neighborhood_id%TYPE)
        RETURN SYS_REFCURSOR;

    -- Toggle favorite: second click un-favorites. Called from a Dynamic
    -- Action on the favorite icon; only the affected card/row is refreshed.
    PROCEDURE toggle_favorite(
        p_app_user          IN VARCHAR2,
        p_neighborhood_id   IN NUMBER
    );

    -- Y/N helper usable directly in a SQL SELECT (e.g. to show a filled vs.
    -- outline heart icon per row without a scalar subquery per column).
    FUNCTION is_favorited(
        p_app_user          IN VARCHAR2,
        p_neighborhood_id   IN NUMBER
    ) RETURN VARCHAR2;

END nbhd_pkg;
/

CREATE OR REPLACE PACKAGE BODY nbhd_pkg AS

    FUNCTION list_neighborhoods(
        p_city    IN neighborhoods.city%TYPE,
        p_search  IN VARCHAR2 DEFAULT NULL
    ) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT n.neighborhood_id,
                   n.name,
                   n.city,
                   n.description,
                   n.latitude,
                   n.longitude,
                   ROUND(AVG(r.rating), 1)         AS avg_restaurant_rating,
                   COUNT(DISTINCT r.restaurant_id)  AS restaurant_count,
                   COUNT(DISTINCT t.theater_id)     AS theater_count
            FROM neighborhoods n
            LEFT JOIN restaurants r ON r.neighborhood_id = n.neighborhood_id
            LEFT JOIN theaters t    ON t.neighborhood_id = n.neighborhood_id
            WHERE n.city = p_city
              AND (p_search IS NULL OR UPPER(n.name) LIKE '%' || UPPER(p_search) || '%')
            GROUP BY n.neighborhood_id, n.name, n.city, n.description, n.latitude, n.longitude
            ORDER BY n.name;
        RETURN v_cursor;
    END list_neighborhoods;

    FUNCTION get_stats(p_neighborhood_id IN neighborhoods.neighborhood_id%TYPE)
        RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT n.neighborhood_id,
                   n.name,
                   n.city,
                   n.description,
                   n.latitude,
                   n.longitude,
                   ROUND(AVG(r.rating), 1)         AS avg_restaurant_rating,
                   COUNT(DISTINCT r.restaurant_id)  AS restaurant_count,
                   COUNT(DISTINCT t.theater_id)     AS theater_count
            FROM neighborhoods n
            LEFT JOIN restaurants r ON r.neighborhood_id = n.neighborhood_id
            LEFT JOIN theaters t    ON t.neighborhood_id = n.neighborhood_id
            WHERE n.neighborhood_id = p_neighborhood_id
            GROUP BY n.neighborhood_id, n.name, n.city, n.description, n.latitude, n.longitude;
        RETURN v_cursor;
    END get_stats;

    PROCEDURE toggle_favorite(
        p_app_user          IN VARCHAR2,
        p_neighborhood_id   IN NUMBER
    ) IS
        v_count NUMBER;
    BEGIN
        -- Not a MERGE: MERGE's DELETE clause is only valid as a sub-clause of
        -- WHEN MATCHED THEN UPDATE (it deletes the row the UPDATE just
        -- touched, with its own WHERE) — a bare `WHEN MATCHED THEN DELETE;`
        -- is not valid MERGE syntax (confirmed against a real compile:
        -- ORA-00905, "missing keyword"). A plain existence check + branch is
        -- the correct way to express toggle semantics.
        SELECT COUNT(*) INTO v_count
        FROM user_favorites
        WHERE app_user = p_app_user
          AND neighborhood_id = p_neighborhood_id;

        IF v_count > 0 THEN
            DELETE FROM user_favorites
            WHERE app_user = p_app_user
              AND neighborhood_id = p_neighborhood_id;
        ELSE
            INSERT INTO user_favorites (app_user, neighborhood_id)
            VALUES (p_app_user, p_neighborhood_id);
        END IF;
        COMMIT;
    END toggle_favorite;

    FUNCTION is_favorited(
        p_app_user          IN VARCHAR2,
        p_neighborhood_id   IN NUMBER
    ) RETURN VARCHAR2 IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count
        FROM user_favorites
        WHERE app_user = p_app_user
          AND neighborhood_id = p_neighborhood_id;
        RETURN CASE WHEN v_count > 0 THEN 'Y' ELSE 'N' END;
    END is_favorited;

END nbhd_pkg;
/

-- =============================================================================
-- RESTAURANT_PKG — Restaurant Finder
-- =============================================================================
CREATE OR REPLACE PACKAGE restaurant_pkg AS

    -- Restaurant Finder filter query. Any parameter left NULL is not applied.
    FUNCTION search(
        p_neighborhood_id  IN NUMBER   DEFAULT NULL,
        p_cuisine          IN VARCHAR2 DEFAULT NULL,
        p_price_range      IN VARCHAR2 DEFAULT NULL,
        p_min_rating       IN NUMBER   DEFAULT NULL
    ) RETURN SYS_REFCURSOR;

    -- Simple weighted-sum recommendation heuristic (NOT a trained model —
    -- see apex/page_plan.md). Scores every restaurant against the calling
    -- user's saved preferences: cuisine match + budget fit + raw rating.
    FUNCTION recommend_for_user(p_app_user IN VARCHAR2) RETURN SYS_REFCURSOR;

    -- Distinct cuisine list, used to populate the Restaurant Finder filter
    -- select list without hardcoding values in APEX.
    FUNCTION list_cuisines RETURN SYS_REFCURSOR;

    -- Maps '$'.. '$$$$' to 1..4 so budget comparisons are numeric. Declared
    -- here (not just in the body) for a real, confirmed reason, not style:
    -- recommend_for_user calls it from inside a SQL SELECT, and Oracle does
    -- not allow a SQL statement — even one embedded in the same package's
    -- own body — to call a function that's private (body-only). Confirmed
    -- against a real compile: PLS-00231, unaffected by reordering the body,
    -- resolved only once this was added to the spec. Same reasoning this
    -- project already applied to nbhd_pkg.is_favorited.
    FUNCTION price_rank(p_price_range IN VARCHAR2) RETURN NUMBER;

END restaurant_pkg;
/

CREATE OR REPLACE PACKAGE BODY restaurant_pkg AS

    -- Helper: maps '$'.. '$$$$' to 1..4 so budget comparisons are numeric.
    -- Defined first, ahead of any subprogram that calls it from inside a SQL
    -- statement — a package body compiles top-down, and a private function
    -- called from SQL by an earlier subprogram must already be defined by
    -- that point, or the compile fails with PLS-00231 ("function ... may not
    -- be used in SQL"), confirmed against a real compile of an earlier
    -- version of this file that defined price_rank last.
    FUNCTION price_rank(p_price_range IN VARCHAR2) RETURN NUMBER IS
    BEGIN
        RETURN CASE p_price_range
                   WHEN '$'    THEN 1
                   WHEN '$$'   THEN 2
                   WHEN '$$$'  THEN 3
                   WHEN '$$$$' THEN 4
                   ELSE 2
               END;
    END price_rank;

    FUNCTION search(
        p_neighborhood_id  IN NUMBER   DEFAULT NULL,
        p_cuisine          IN VARCHAR2 DEFAULT NULL,
        p_price_range      IN VARCHAR2 DEFAULT NULL,
        p_min_rating       IN NUMBER   DEFAULT NULL
    ) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT r.restaurant_id,
                   r.name,
                   r.cuisine,
                   r.price_range,
                   r.rating,
                   r.latitude,
                   r.longitude,
                   n.neighborhood_id,
                   n.name AS neighborhood_name
            FROM restaurants r
            JOIN neighborhoods n ON n.neighborhood_id = r.neighborhood_id
            WHERE (p_neighborhood_id IS NULL OR r.neighborhood_id = p_neighborhood_id)
              AND (p_cuisine IS NULL OR r.cuisine = p_cuisine)
              AND (p_price_range IS NULL OR r.price_range = p_price_range)
              AND (p_min_rating IS NULL OR r.rating >= p_min_rating)
            ORDER BY r.rating DESC, r.name;
        RETURN v_cursor;
    END search;

    FUNCTION recommend_for_user(p_app_user IN VARCHAR2) RETURN SYS_REFCURSOR IS
        v_cursor        SYS_REFCURSOR;
        v_cuisine       user_preferences.preferred_cuisine%TYPE;
        v_budget        user_preferences.budget_price_range%TYPE;
    BEGIN
        BEGIN
            SELECT preferred_cuisine, budget_price_range
            INTO v_cuisine, v_budget
            FROM user_preferences
            WHERE app_user = p_app_user;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_cuisine := NULL;
                v_budget  := '$$';
        END;

        -- Heuristic: +3 for exact cuisine match, +2 for being within budget
        -- (price_range rank <= preferred budget rank), plus the restaurant's
        -- own rating. This is intentionally simple and explainable, not a
        -- trained model.
        OPEN v_cursor FOR
            SELECT r.restaurant_id,
                   r.name,
                   r.cuisine,
                   r.price_range,
                   r.rating,
                   n.name AS neighborhood_name,
                   (CASE WHEN r.cuisine = v_cuisine THEN 3 ELSE 0 END) +
                   (CASE WHEN price_rank(r.price_range) <= price_rank(v_budget) THEN 2 ELSE 0 END) +
                   r.rating AS recommend_score
            FROM restaurants r
            JOIN neighborhoods n ON n.neighborhood_id = r.neighborhood_id
            ORDER BY recommend_score DESC, r.rating DESC
            FETCH FIRST 10 ROWS ONLY;
        RETURN v_cursor;
    END recommend_for_user;

    FUNCTION list_cuisines RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT DISTINCT cuisine FROM restaurants ORDER BY cuisine;
        RETURN v_cursor;
    END list_cuisines;

END restaurant_pkg;
/

-- =============================================================================
-- THEATER_PKG — Entertainment (Oracle half; MongoDB half is mflix_movies)
-- =============================================================================
CREATE OR REPLACE PACKAGE theater_pkg AS

    FUNCTION list_by_neighborhood(p_neighborhood_id IN NUMBER)
        RETURN SYS_REFCURSOR;

END theater_pkg;
/

CREATE OR REPLACE PACKAGE BODY theater_pkg AS

    FUNCTION list_by_neighborhood(p_neighborhood_id IN NUMBER)
        RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT theater_id, name, screen_count, address, latitude, longitude
            FROM theaters
            WHERE neighborhood_id = p_neighborhood_id
            ORDER BY name;
        RETURN v_cursor;
    END list_by_neighborhood;

END theater_pkg;
/

-- =============================================================================
-- PREFS_PKG — User Profile (preferences that drive recommendation scoring)
-- =============================================================================
CREATE OR REPLACE PACKAGE prefs_pkg AS

    FUNCTION get_preferences(p_app_user IN VARCHAR2) RETURN SYS_REFCURSOR;

    PROCEDURE save_preferences(
        p_app_user           IN VARCHAR2,
        p_preferred_cuisine  IN VARCHAR2,
        p_budget_price_range IN VARCHAR2,
        p_weather_preference IN VARCHAR2,
        p_min_rating         IN NUMBER DEFAULT 0
    );

END prefs_pkg;
/

CREATE OR REPLACE PACKAGE BODY prefs_pkg AS

    FUNCTION get_preferences(p_app_user IN VARCHAR2) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT preferred_cuisine, budget_price_range, weather_preference, min_rating
            FROM user_preferences
            WHERE app_user = p_app_user;
        RETURN v_cursor;
    END get_preferences;

    PROCEDURE save_preferences(
        p_app_user           IN VARCHAR2,
        p_preferred_cuisine  IN VARCHAR2,
        p_budget_price_range IN VARCHAR2,
        p_weather_preference IN VARCHAR2,
        p_min_rating         IN NUMBER DEFAULT 0
    ) IS
    BEGIN
        MERGE INTO user_preferences up
        USING (SELECT p_app_user AS app_user FROM dual) src
        ON (up.app_user = src.app_user)
        WHEN MATCHED THEN
            UPDATE SET preferred_cuisine  = p_preferred_cuisine,
                       budget_price_range = p_budget_price_range,
                       weather_preference = p_weather_preference,
                       min_rating         = NVL(p_min_rating, 0),
                       updated_at         = SYSTIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (app_user, preferred_cuisine, budget_price_range, weather_preference, min_rating)
            VALUES (p_app_user, p_preferred_cuisine, p_budget_price_range, p_weather_preference, NVL(p_min_rating, 0));
        COMMIT;
    END save_preferences;

END prefs_pkg;
/

-- =============================================================================
-- ADMIN_PKG — Admin / Seed Data page
-- Reload procedure is the single source of truth for Oracle seed rows so the
-- "Reload Seed Data" button in APEX and a fresh install produce the same
-- dataset. Targets Washington, D.C.
-- =============================================================================
CREATE OR REPLACE PACKAGE admin_pkg AS

    -- Dashboard tile counts (Oracle side only — listings count is fetched
    -- from the Mongo proxy separately and combined on the page; see
    -- apex/page_plan.md, page 1).
    FUNCTION get_dashboard_counts RETURN SYS_REFCURSOR;

    -- Deletes and re-inserts all Oracle seed rows. Idempotent — safe to run
    -- repeatedly from the Admin page between demo runs. NOTE: because
    -- neighborhood_id/restaurant_id/theater_id are IDENTITY columns and this
    -- procedure DELETEs rather than drops/recreates the tables, re-running
    -- it against a non-empty schema does NOT reproduce the same IDs (the
    -- sequence keeps counting up) — the MongoDB seed data's neighborhood_id
    -- join values only match a genuinely fresh install. Same documented
    -- caveat as before, now against 28 IDs instead of 8 — see
    -- db/mongodb/schema_notes.md.
    PROCEDURE reload_oracle_seed_data;

    -- Returns the current city setting used to filter every page.
    FUNCTION get_current_city RETURN VARCHAR2;

END admin_pkg;
/

CREATE OR REPLACE PACKAGE BODY admin_pkg AS

    FUNCTION get_dashboard_counts RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT (SELECT COUNT(*) FROM neighborhoods WHERE city = get_current_city) AS neighborhood_count,
                   (SELECT COUNT(*) FROM restaurants r
                      JOIN neighborhoods n ON n.neighborhood_id = r.neighborhood_id
                     WHERE n.city = get_current_city)                                  AS restaurant_count,
                   (SELECT COUNT(*) FROM theaters t
                      JOIN neighborhoods n ON n.neighborhood_id = t.neighborhood_id
                     WHERE n.city = get_current_city)                                  AS theater_count
            FROM dual;
        RETURN v_cursor;
    END get_dashboard_counts;

    FUNCTION get_current_city RETURN VARCHAR2 IS
        v_city VARCHAR2(200);
    BEGIN
        SELECT setting_value INTO v_city FROM app_settings WHERE setting_key = 'current_city';
        RETURN v_city;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 'Washington';
    END get_current_city;

    PROCEDURE reload_oracle_seed_data IS
    BEGIN
        -- Children first (FK order), then parents.
        DELETE FROM user_favorites;
        DELETE FROM restaurants;
        DELETE FROM theaters;
        DELETE FROM neighborhoods;
        COMMIT;

        -- -------------------------------------------------------------------
        -- Neighborhoods (28) — Washington, D.C.
        --
        -- neighborhood_id is inserted EXPLICITLY, not generated. This is the
        -- fix for the cross-database ID drift documented in
        -- db/mongodb/schema_notes.md: MongoDB's listings/weather_snapshots/
        -- mflix_movies all reference these integers as their join key, so they
        -- must be stable across reloads. When this column was
        -- GENERATED ALWAYS AS IDENTITY, every DELETE+INSERT cycle here left the
        -- sequence untouched and produced a fresh, higher range (1-28 -> 9-36 ->
        -- ...), silently breaking every Mongo-backed region. IDs below match
        -- schema_notes.md's table exactly and must stay in sync with it.
        --
        -- restaurants/theaters below resolve neighborhood_id by name lookup, so
        -- they need no changes and stay correct regardless.
        -- -------------------------------------------------------------------
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (1, 'Georgetown', 'Washington', 'Historic waterfront neighborhood with cobblestone streets, high-end shopping, and the C&O Canal.', 38.9094, -77.0650);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (2, 'Capitol Hill', 'Washington', 'Home of the U.S. Capitol, Supreme Court, and Eastern Market; dense with 19th-century rowhouses.', 38.8860, -76.9995);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (3, 'Dupont Circle', 'Washington', 'Walkable hub of embassies, bookstores, and nightlife around the famous traffic circle.', 38.9096, -77.0434);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (4, 'Adams Morgan', 'Washington', 'Eclectic, international nightlife and dining corridor along 18th Street NW.', 38.9226, -77.0427);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (5, 'Columbia Heights', 'Washington', 'Diverse, rapidly evolving neighborhood centered on 14th Street and the DC USA complex.', 38.9257, -77.0294);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (6, 'U Street / Shaw', 'Washington', 'Historic African American cultural corridor with jazz history, murals, and a booming restaurant scene.', 38.9170, -77.0270);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (7, 'Logan Circle', 'Washington', 'Victorian architecture, 14th Street dining, and a lively LGBTQ+ community.', 38.9096, -77.0296);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (8, 'Navy Yard / Capitol Riverfront', 'Washington', 'Waterfront redevelopment around Nationals Park with new restaurants, parks, and views of the Anacostia.', 38.8765, -77.0075);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (9, 'Foggy Bottom', 'Washington', 'Home to George Washington University, the State Department, and the Kennedy Center.', 38.9000, -77.0500);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (10, 'Penn Quarter / Chinatown', 'Washington', 'Downtown entertainment district with Capital One Arena, museums, and a classic Chinatown arch.', 38.8990, -77.0210);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (11, 'Mount Pleasant', 'Washington', 'Leafy, international enclave known for its Latin American community and Mount Pleasant Street.', 38.9312, -77.0406);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (12, 'Cleveland Park', 'Washington', 'Quiet, residential neighborhood near the National Zoo and Washington National Cathedral.', 38.9360, -77.0580);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (13, 'Woodley Park', 'Washington', 'Elegant residential area adjacent to the National Zoo and Rock Creek Park.', 38.9280, -77.0520);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (14, 'Petworth', 'Washington', 'Emerging residential neighborhood with a growing restaurant row along Georgia Avenue.', 38.9500, -77.0250);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (15, 'Brookland', 'Washington', 'Tree-lined streets, the Basilica of the National Shrine, and a quiet residential feel.', 38.9300, -76.9900);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (16, 'H Street NE / Atlas District', 'Washington', 'Vibrant nightlife and dining corridor east of Union Station.', 38.9000, -76.9900);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (17, 'Anacostia', 'Washington', 'Historic neighborhood east of the Anacostia River with strong community roots and waterfront parks.', 38.8630, -76.9830);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (18, 'Southwest Waterfront / The Wharf', 'Washington', 'Modern waterfront destination with concert venues, piers, and a dense restaurant scene.', 38.8800, -77.0250);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (19, 'NoMa', 'Washington', 'Rapidly developing area north of Union Station with new apartments, parks, and food halls.', 38.9070, -77.0050);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (20, 'Bloomingdale', 'Washington', 'Quiet residential neighborhood known for its Victorian homes and community gardens.', 38.9150, -77.0120);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (21, 'LeDroit Park', 'Washington', 'Historic African American neighborhood adjacent to Howard University.', 38.9200, -77.0150);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (22, 'Glover Park', 'Washington', 'Residential neighborhood west of Georgetown near Glover-Archbold Park.', 38.9220, -77.0800);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (23, 'Tenleytown', 'Washington', 'Northwest neighborhood with American University nearby and a mix of residential and commercial streets.', 38.9480, -77.0800);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (24, 'Friendship Heights', 'Washington', 'Upscale shopping and residential area on the Maryland border.', 38.9600, -77.0850);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (25, 'Congress Heights', 'Washington', 'Southeast neighborhood with community institutions and proximity to St. Elizabeths.', 38.8400, -76.9900);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (26, 'Deanwood', 'Washington', 'Quiet residential neighborhood in far Northeast D.C.', 38.9100, -76.9300);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (27, 'Barracks Row', 'Washington', 'Historic commercial corridor on 8th Street SE near the Marine Barracks and Eastern Market.', 38.8800, -76.9950);
        INSERT INTO neighborhoods (neighborhood_id, name, city, description, latitude, longitude) VALUES
            (28, 'West End', 'Washington', 'Upscale residential and hotel district between Foggy Bottom and Georgetown.', 38.9050, -77.0500);
        COMMIT;

        -- -------------------------------------------------------------------
        -- Restaurants (87)
        -- -------------------------------------------------------------------
        -- Georgetown
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Filomena Ristorante', 'Italian', '$$$', 4.4, 38.9045, -77.0620 FROM neighborhoods WHERE name = 'Georgetown';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Farmers Fishers Bakers', 'American', '$$', 4.2, 38.9010, -77.0600 FROM neighborhoods WHERE name = 'Georgetown';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Cafe Milano', 'Italian', '$$$$', 4.5, 38.9055, -77.0635 FROM neighborhoods WHERE name = 'Georgetown';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Martin''s Tavern', 'American', '$$', 4.3, 38.9060, -77.0655 FROM neighborhoods WHERE name = 'Georgetown';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'La Chaumiere', 'French', '$$$', 4.4, 38.9050, -77.0610 FROM neighborhoods WHERE name = 'Georgetown';

        -- Capitol Hill
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Tunnicliff''s Tavern', 'American', '$$', 4.1, 38.8865, -76.9950 FROM neighborhoods WHERE name = 'Capitol Hill';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Rose''s Luxury', 'American', '$$$$', 4.7, 38.8800, -76.9955 FROM neighborhoods WHERE name = 'Capitol Hill';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Pascual', 'Mexican', '$$$', 4.6, 38.8850, -76.9980 FROM neighborhoods WHERE name = 'Capitol Hill';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Good Stuff Eatery', 'American', '$', 4.3, 38.8870, -76.9960 FROM neighborhoods WHERE name = 'Capitol Hill';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Ted''s Bulletin', 'American', '$$', 4.2, 38.8840, -76.9940 FROM neighborhoods WHERE name = 'Capitol Hill';

        -- Dupont Circle
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Tabard Inn Restaurant', 'American', '$$$', 4.5, 38.9090, -77.0400 FROM neighborhoods WHERE name = 'Dupont Circle';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Kramerbooks & Afterwords Cafe', 'Cafe', '$$', 4.3, 38.9100, -77.0430 FROM neighborhoods WHERE name = 'Dupont Circle';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Duke''s Grocery', 'British', '$$', 4.4, 38.9110, -77.0420 FROM neighborhoods WHERE name = 'Dupont Circle';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Boogy & Peel', 'Pizza', '$', 4.2, 38.9085, -77.0415 FROM neighborhoods WHERE name = 'Dupont Circle';

        -- Adams Morgan
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Tail Up Goat', 'Mediterranean', '$$$', 4.6, 38.9210, -77.0420 FROM neighborhoods WHERE name = 'Adams Morgan';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Lucky Buns', 'American', '$$', 4.4, 38.9220, -77.0430 FROM neighborhoods WHERE name = 'Adams Morgan';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Lapis', 'Afghan', '$$', 4.5, 38.9230, -77.0410 FROM neighborhoods WHERE name = 'Adams Morgan';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Perry''s', 'Japanese', '$$', 4.3, 38.9215, -77.0440 FROM neighborhoods WHERE name = 'Adams Morgan';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Tsehay Ethiopian', 'Ethiopian', '$', 4.4, 38.9225, -77.0405 FROM neighborhoods WHERE name = 'Adams Morgan';

        -- Columbia Heights
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Room 11', 'American', '$$', 4.3, 38.9270, -77.0300 FROM neighborhoods WHERE name = 'Columbia Heights';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Thip Khao', 'Laotian', '$$', 4.5, 38.9260, -77.0280 FROM neighborhoods WHERE name = 'Columbia Heights';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Meridian Pint', 'American', '$$', 4.2, 38.9280, -77.0310 FROM neighborhoods WHERE name = 'Columbia Heights';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Ulivo', 'Italian', '$$', 4.4, 38.9255, -77.0295 FROM neighborhoods WHERE name = 'Columbia Heights';

        -- U Street / Shaw
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'The Dabney', 'American', '$$$$', 4.7, 38.9160, -77.0250 FROM neighborhoods WHERE name = 'U Street / Shaw';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Ben''s Chili Bowl', 'American', '$', 4.6, 38.9175, -77.0275 FROM neighborhoods WHERE name = 'U Street / Shaw';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Maydan', 'Middle Eastern', '$$$', 4.6, 38.9150, -77.0260 FROM neighborhoods WHERE name = 'U Street / Shaw';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Baan Mae', 'Laotian', '$$', 4.5, 38.9165, -77.0280 FROM neighborhoods WHERE name = 'U Street / Shaw';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Le Diplomate', 'French', '$$$', 4.5, 38.9140, -77.0310 FROM neighborhoods WHERE name = 'U Street / Shaw';

        -- Logan Circle
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Chicatana', 'Mexican', '$$$', 4.7, 38.9100, -77.0300 FROM neighborhoods WHERE name = 'Logan Circle';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Estadio', 'Spanish', '$$$', 4.4, 38.9110, -77.0310 FROM neighborhoods WHERE name = 'Logan Circle';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Pearl Dive Oyster Palace', 'Seafood', '$$$', 4.3, 38.9090, -77.0280 FROM neighborhoods WHERE name = 'Logan Circle';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'MXDC', 'Mexican', '$$', 4.2, 38.9105, -77.0295 FROM neighborhoods WHERE name = 'Logan Circle';

        -- Navy Yard / Capitol Riverfront
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'The Salt Line', 'Seafood', '$$$', 4.5, 38.8750, -77.0060 FROM neighborhoods WHERE name = 'Navy Yard / Capitol Riverfront';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'All-Purpose Pizzeria', 'Pizza', '$$', 4.4, 38.8770, -77.0080 FROM neighborhoods WHERE name = 'Navy Yard / Capitol Riverfront';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Bluejacket', 'American', '$$', 4.3, 38.8740, -77.0050 FROM neighborhoods WHERE name = 'Navy Yard / Capitol Riverfront';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Due South', 'Southern', '$$', 4.2, 38.8760, -77.0070 FROM neighborhoods WHERE name = 'Navy Yard / Capitol Riverfront';

        -- Foggy Bottom
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Founding Farmers', 'American', '$$', 4.3, 38.9010, -77.0450 FROM neighborhoods WHERE name = 'Foggy Bottom';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Equinox', 'American', '$$$', 4.4, 38.8990, -77.0400 FROM neighborhoods WHERE name = 'Foggy Bottom';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Oval Room', 'American', '$$$$', 4.5, 38.8970, -77.0380 FROM neighborhoods WHERE name = 'Foggy Bottom';

        -- Penn Quarter / Chinatown
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Centrolina', 'Italian', '$$$', 4.6, 38.9000, -77.0250 FROM neighborhoods WHERE name = 'Penn Quarter / Chinatown';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Fiola', 'Italian', '$$$$', 4.5, 38.8980, -77.0230 FROM neighborhoods WHERE name = 'Penn Quarter / Chinatown';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'China Chilcano', 'Peruvian', '$$', 4.3, 38.8995, -77.0200 FROM neighborhoods WHERE name = 'Penn Quarter / Chinatown';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Matchbox', 'American', '$$', 4.2, 38.8975, -77.0220 FROM neighborhoods WHERE name = 'Penn Quarter / Chinatown';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Zaytinya', 'Mediterranean', '$$$', 4.4, 38.9005, -77.0240 FROM neighborhoods WHERE name = 'Penn Quarter / Chinatown';

        -- Mount Pleasant
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Don Juan Restaurant', 'Latin American', '$$', 4.3, 38.9320, -77.0380 FROM neighborhoods WHERE name = 'Mount Pleasant';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Haydee''s Restaurant', 'Salvadoran', '$', 4.4, 38.9310, -77.0410 FROM neighborhoods WHERE name = 'Mount Pleasant';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Marx Cafe', 'American', '$$', 4.1, 38.9305, -77.0390 FROM neighborhoods WHERE name = 'Mount Pleasant';

        -- Cleveland Park
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, '2 Amys', 'Pizza', '$$', 4.5, 38.9350, -77.0570 FROM neighborhoods WHERE name = 'Cleveland Park';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Palena Cafe', 'American', '$$$', 4.4, 38.9370, -77.0590 FROM neighborhoods WHERE name = 'Cleveland Park';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Open City', 'Cafe', '$$', 4.2, 38.9340, -77.0560 FROM neighborhoods WHERE name = 'Cleveland Park';

        -- Woodley Park
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Lebanese Taverna', 'Lebanese', '$$', 4.3, 38.9270, -77.0500 FROM neighborhoods WHERE name = 'Woodley Park';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'New Heights', 'American', '$$$', 4.4, 38.9290, -77.0530 FROM neighborhoods WHERE name = 'Woodley Park';

        -- Petworth
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Himchuli', 'Nepalese', '$$', 4.4, 38.9510, -77.0240 FROM neighborhoods WHERE name = 'Petworth';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Qualia Coffee', 'Cafe', '$', 4.5, 38.9490, -77.0260 FROM neighborhoods WHERE name = 'Petworth';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Brookland''s Finest', 'American', '$$', 4.2, 38.9505, -77.0230 FROM neighborhoods WHERE name = 'Petworth';

        -- Brookland
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Menomale', 'Pizza', '$$', 4.5, 38.9290, -76.9910 FROM neighborhoods WHERE name = 'Brookland';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Brookland Pint', 'American', '$$', 4.2, 38.9310, -76.9890 FROM neighborhoods WHERE name = 'Brookland';

        -- H Street NE / Atlas District
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Toki Underground', 'Japanese', '$$', 4.5, 38.9005, -76.9880 FROM neighborhoods WHERE name = 'H Street NE / Atlas District';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Daru', 'Indian', '$$$', 4.6, 38.8990, -76.9910 FROM neighborhoods WHERE name = 'H Street NE / Atlas District';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Sticky Rice', 'Asian Fusion', '$$', 4.3, 38.9010, -76.9890 FROM neighborhoods WHERE name = 'H Street NE / Atlas District';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'The Atlas Room', 'American', '$$$', 4.4, 38.9000, -76.9920 FROM neighborhoods WHERE name = 'H Street NE / Atlas District';

        -- Anacostia
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Uniontown Bar & Grill', 'American', '$$', 4.2, 38.8640, -76.9840 FROM neighborhoods WHERE name = 'Anacostia';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Anacostia Coffee', 'Cafe', '$', 4.3, 38.8620, -76.9820 FROM neighborhoods WHERE name = 'Anacostia';

        -- Southwest Waterfront / The Wharf
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Del Mar', 'Spanish', '$$$$', 4.6, 38.8790, -77.0240 FROM neighborhoods WHERE name = 'Southwest Waterfront / The Wharf';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Kaliwa', 'Asian Fusion', '$$$', 4.4, 38.8810, -77.0260 FROM neighborhoods WHERE name = 'Southwest Waterfront / The Wharf';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Whaley''s', 'Seafood', '$$', 4.3, 38.8780, -77.0230 FROM neighborhoods WHERE name = 'Southwest Waterfront / The Wharf';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Cantina Bambina', 'Mexican', '$$', 4.2, 38.8805, -77.0255 FROM neighborhoods WHERE name = 'Southwest Waterfront / The Wharf';

        -- NoMa
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Union Market Food Hall', 'American', '$$', 4.3, 38.9080, -77.0030 FROM neighborhoods WHERE name = 'NoMa';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Masseria', 'Italian', '$$$$', 4.5, 38.9060, -77.0040 FROM neighborhoods WHERE name = 'NoMa';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'St. Anselm', 'Steakhouse', '$$$', 4.4, 38.9075, -77.0060 FROM neighborhoods WHERE name = 'NoMa';

        -- Bloomingdale
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Red Hen', 'Italian', '$$$', 4.5, 38.9140, -77.0110 FROM neighborhoods WHERE name = 'Bloomingdale';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Boundary Stone', 'American', '$$', 4.2, 38.9160, -77.0130 FROM neighborhoods WHERE name = 'Bloomingdale';

        -- LeDroit Park
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Florida Avenue Grill', 'Southern', '$$', 4.4, 38.9180, -77.0160 FROM neighborhoods WHERE name = 'LeDroit Park';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'The Royal', 'American', '$$', 4.3, 38.9190, -77.0140 FROM neighborhoods WHERE name = 'LeDroit Park';

        -- Glover Park
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Surfside', 'Mexican', '$$', 4.2, 38.9210, -77.0780 FROM neighborhoods WHERE name = 'Glover Park';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Bread Furst', 'Bakery', '$', 4.5, 38.9230, -77.0810 FROM neighborhoods WHERE name = 'Glover Park';

        -- Tenleytown
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Cactus Cantina', 'Mexican', '$$', 4.1, 38.9470, -77.0790 FROM neighborhoods WHERE name = 'Tenleytown';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Guapo''s', 'Mexican', '$$', 4.2, 38.9490, -77.0810 FROM neighborhoods WHERE name = 'Tenleytown';

        -- Friendship Heights
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Chef Geoff''s', 'American', '$$$', 4.3, 38.9590, -77.0840 FROM neighborhoods WHERE name = 'Friendship Heights';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Maggiano''s Little Italy', 'Italian', '$$', 4.1, 38.9610, -77.0860 FROM neighborhoods WHERE name = 'Friendship Heights';

        -- Congress Heights
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Anacostia Restaurant', 'Southern', '$$', 4.0, 38.8410, -76.9910 FROM neighborhoods WHERE name = 'Congress Heights';

        -- Deanwood
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Kenilworth Market Cafe', 'American', '$', 4.1, 38.9110, -76.9320 FROM neighborhoods WHERE name = 'Deanwood';

        -- Barracks Row
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Belga Cafe', 'Belgian', '$$$', 4.4, 38.8810, -76.9940 FROM neighborhoods WHERE name = 'Barracks Row';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Matchbox Barracks Row', 'American', '$$', 4.3, 38.8790, -76.9960 FROM neighborhoods WHERE name = 'Barracks Row';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Banana Cafe', 'Cuban', '$$', 4.2, 38.8805, -76.9955 FROM neighborhoods WHERE name = 'Barracks Row';

        -- West End
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Marcel''s', 'French', '$$$$', 4.6, 38.9040, -77.0480 FROM neighborhoods WHERE name = 'West End';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Ris', 'American', '$$$', 4.4, 38.9060, -77.0510 FROM neighborhoods WHERE name = 'West End';
        COMMIT;

        -- -------------------------------------------------------------------
        -- Theaters (14)
        -- -------------------------------------------------------------------
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'AMC Georgetown 14', 14, '3111 K Street NW', 38.9030, -77.0610 FROM neighborhoods WHERE name = 'Georgetown';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Regal Gallery Place & 4DX', 14, '701 7th Street NW', 38.8985, -77.0215 FROM neighborhoods WHERE name = 'Penn Quarter / Chinatown';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Landmark Atlantic Plumbing Cinema', 6, '807 V Street NW', 38.9175, -77.0255 FROM neighborhoods WHERE name = 'U Street / Shaw';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Alamo Drafthouse DC Bryant Street', 9, '630 Rhode Island Avenue NE', 38.9200, -76.9950 FROM neighborhoods WHERE name = 'NoMa';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Angelika Pop-Up at Union Market', 3, '550 Penn Street NE', 38.9085, -77.0020 FROM neighborhoods WHERE name = 'NoMa';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Avalon Theatre', 2, '5612 Connecticut Avenue NW', 38.9500, -77.0700 FROM neighborhoods WHERE name = 'Friendship Heights';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Miracle Theatre', 1, '535 8th Street SE', 38.8800, -76.9950 FROM neighborhoods WHERE name = 'Barracks Row';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Suns Cinema', 1, '3107 Mount Pleasant Street NW', 38.9310, -77.0380 FROM neighborhoods WHERE name = 'Mount Pleasant';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Lockheed Martin IMAX Theater', 1, 'National Air and Space Museum, Independence Ave SW', 38.8880, -77.0200 FROM neighborhoods WHERE name = 'Southwest Waterfront / The Wharf';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Lincoln Theatre', 1, '1215 U Street NW', 38.9170, -77.0280 FROM neighborhoods WHERE name = 'U Street / Shaw';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Howard Theatre', 1, '620 T Street NW', 38.9160, -77.0220 FROM neighborhoods WHERE name = 'U Street / Shaw';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Warner Theatre', 1, '513 13th Street NW', 38.8970, -77.0290 FROM neighborhoods WHERE name = 'Penn Quarter / Chinatown';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'National Theatre', 1, '1321 Pennsylvania Avenue NW', 38.8960, -77.0310 FROM neighborhoods WHERE name = 'Penn Quarter / Chinatown';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'E Street Cinema (Landmark)', 8, '555 11th Street NW', 38.8965, -77.0270 FROM neighborhoods WHERE name = 'Penn Quarter / Chinatown';
        COMMIT;

        -- -------------------------------------------------------------------
        -- Sample user_favorites (demo APEX users)
        -- -------------------------------------------------------------------
        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'DEMO', neighborhood_id FROM neighborhoods WHERE name = 'Georgetown';
        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'DEMO', neighborhood_id FROM neighborhoods WHERE name = 'Capitol Hill';
        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'DEMO', neighborhood_id FROM neighborhoods WHERE name = 'Dupont Circle';
        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'DEMO', neighborhood_id FROM neighborhoods WHERE name = 'U Street / Shaw';

        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'ADMIN', neighborhood_id FROM neighborhoods WHERE name = 'Navy Yard / Capitol Riverfront';
        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'ADMIN', neighborhood_id FROM neighborhoods WHERE name = 'Southwest Waterfront / The Wharf';
        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'ADMIN', neighborhood_id FROM neighborhoods WHERE name = 'Penn Quarter / Chinatown';

        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'APEX_PUBLIC_USER', neighborhood_id FROM neighborhoods WHERE name = 'Adams Morgan';
        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'APEX_PUBLIC_USER', neighborhood_id FROM neighborhoods WHERE name = 'Columbia Heights';
        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'APEX_PUBLIC_USER', neighborhood_id FROM neighborhoods WHERE name = 'Logan Circle';
        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'APEX_PUBLIC_USER', neighborhood_id FROM neighborhoods WHERE name = 'H Street NE / Atlas District';

        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'TESTUSER', neighborhood_id FROM neighborhoods WHERE name = 'Mount Pleasant';
        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'TESTUSER', neighborhood_id FROM neighborhoods WHERE name = 'Cleveland Park';
        INSERT INTO user_favorites (app_user, neighborhood_id)
            SELECT 'TESTUSER', neighborhood_id FROM neighborhoods WHERE name = 'Petworth';
        COMMIT;

        -- -------------------------------------------------------------------
        -- app_settings: current city default
        -- -------------------------------------------------------------------
        MERGE INTO app_settings s
        USING (SELECT 'current_city' AS setting_key, 'Washington' AS setting_value FROM dual) src
        ON (s.setting_key = src.setting_key)
        WHEN MATCHED THEN UPDATE SET setting_value = src.setting_value, updated_at = SYSTIMESTAMP
        WHEN NOT MATCHED THEN INSERT (setting_key, setting_value) VALUES (src.setting_key, src.setting_value);
        COMMIT;
    END reload_oracle_seed_data;

END admin_pkg;
/
