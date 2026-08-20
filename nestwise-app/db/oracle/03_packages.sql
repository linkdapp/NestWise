-- =============================================================================
-- NestWise — 03_packages.sql
-- One package per major entity/feature area. Business logic lives here, not
-- scattered across APEX page processes, so it's testable and reusable from
-- ORDS. Deliberately not a generic data-access layer — only the operations
-- the pages actually call.
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
    BEGIN
        MERGE INTO user_favorites uf
        USING (SELECT p_app_user AS app_user, p_neighborhood_id AS neighborhood_id FROM dual) src
        ON (uf.app_user = src.app_user AND uf.neighborhood_id = src.neighborhood_id)
        WHEN NOT MATCHED THEN
            INSERT (app_user, neighborhood_id) VALUES (src.app_user, src.neighborhood_id)
        WHEN MATCHED THEN
            DELETE; -- toggling: second click un-favorites
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

END restaurant_pkg;
/

CREATE OR REPLACE PACKAGE BODY restaurant_pkg AS

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

    -- Helper: maps '$'.. '$$$$' to 1..4 so budget comparisons are numeric.
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
        p_weather_preference IN VARCHAR2
    );

END prefs_pkg;
/

CREATE OR REPLACE PACKAGE BODY prefs_pkg AS

    FUNCTION get_preferences(p_app_user IN VARCHAR2) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT preferred_cuisine, budget_price_range, weather_preference
            FROM user_preferences
            WHERE app_user = p_app_user;
        RETURN v_cursor;
    END get_preferences;

    PROCEDURE save_preferences(
        p_app_user           IN VARCHAR2,
        p_preferred_cuisine  IN VARCHAR2,
        p_budget_price_range IN VARCHAR2,
        p_weather_preference IN VARCHAR2
    ) IS
    BEGIN
        MERGE INTO user_preferences up
        USING (SELECT p_app_user AS app_user FROM dual) src
        ON (up.app_user = src.app_user)
        WHEN MATCHED THEN
            UPDATE SET preferred_cuisine  = p_preferred_cuisine,
                       budget_price_range = p_budget_price_range,
                       weather_preference = p_weather_preference,
                       updated_at         = SYSTIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (app_user, preferred_cuisine, budget_price_range, weather_preference)
            VALUES (p_app_user, p_preferred_cuisine, p_budget_price_range, p_weather_preference);
        COMMIT;
    END save_preferences;

END prefs_pkg;
/

-- =============================================================================
-- ADMIN_PKG — Admin / Seed Data page
-- Reload procedure mirrors db/oracle/99_seed_data.sql exactly so the "Reload
-- Seed Data" button in APEX and a fresh install produce the same dataset.
-- =============================================================================
CREATE OR REPLACE PACKAGE admin_pkg AS

    -- Dashboard tile counts (Oracle side only — listings count is fetched
    -- from the Mongo proxy separately and combined on the page; see
    -- apex/page_plan.md, page 1).
    FUNCTION get_dashboard_counts RETURN SYS_REFCURSOR;

    -- Deletes and re-inserts all Oracle seed rows. Idempotent — safe to run
    -- repeatedly from the Admin page between demo runs.
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
            RETURN 'San Francisco';
    END get_current_city;

    PROCEDURE reload_oracle_seed_data IS
    BEGIN
        -- Children first (FK order), then parents.
        DELETE FROM user_favorites;
        DELETE FROM restaurants;
        DELETE FROM theaters;
        DELETE FROM neighborhoods;
        COMMIT;

        -- Delegate to the same statements as 99_seed_data.sql. Kept inline
        -- (not dynamic SQL against the .sql file) so this package has no
        -- filesystem dependency and can run identically from an APEX button.
        INSERT INTO neighborhoods (name, city, description, latitude, longitude) VALUES
            ('Mission District', 'San Francisco', 'Murals, taquerias, and Dolores Park.', 37.7599, -122.4148);
        INSERT INTO neighborhoods (name, city, description, latitude, longitude) VALUES
            ('Hayes Valley', 'San Francisco', 'Boutique shops and a walkable, leafy core.', 37.7759, -122.4245);
        INSERT INTO neighborhoods (name, city, description, latitude, longitude) VALUES
            ('North Beach', 'San Francisco', 'Italian cafes, City Lights Books, and jazz clubs.', 37.8060, -122.4103);
        INSERT INTO neighborhoods (name, city, description, latitude, longitude) VALUES
            ('SoMa', 'San Francisco', 'Museums, tech offices, and Oracle Park nearby.', 37.7785, -122.4056);
        INSERT INTO neighborhoods (name, city, description, latitude, longitude) VALUES
            ('Castro', 'San Francisco', 'Historic LGBTQ+ neighborhood with classic theaters.', 37.7609, -122.4350);
        INSERT INTO neighborhoods (name, city, description, latitude, longitude) VALUES
            ('Noe Valley', 'San Francisco', 'Sunny, family-friendly, and quiet compared to downtown.', 37.7502, -122.4337);
        INSERT INTO neighborhoods (name, city, description, latitude, longitude) VALUES
            ('Richmond District', 'San Francisco', 'Foggy, dense with Asian eateries, near Golden Gate Park.', 37.7806, -122.4644);
        INSERT INTO neighborhoods (name, city, description, latitude, longitude) VALUES
            ('Marina District', 'San Francisco', 'Waterfront views and upscale brunch spots.', 37.8030, -122.4377);
        COMMIT;

        -- restaurants: 3-4 per neighborhood, varied cuisine/price/rating
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'La Taqueria Real', 'Mexican', '$', 4.6, 37.7595, -122.4149 FROM neighborhoods WHERE name = 'Mission District';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Foreign Cinema', 'American', '$$$', 4.4, 37.7562, -122.4198 FROM neighborhoods WHERE name = 'Mission District';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Bi-Rite Creamery', 'Dessert', '$', 4.7, 37.7614, -122.4256 FROM neighborhoods WHERE name = 'Mission District';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Rintaro', 'Japanese', '$$$', 4.5, 37.7656, -122.4211 FROM neighborhoods WHERE name = 'Mission District';

        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Rich Table', 'American', '$$$$', 4.6, 37.7726, -122.4230 FROM neighborhoods WHERE name = 'Hayes Valley';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Souvla', 'Greek', '$$', 4.5, 37.7764, -122.4243 FROM neighborhoods WHERE name = 'Hayes Valley';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Absinthe Brasserie', 'French', '$$$', 4.2, 37.7770, -122.4238 FROM neighborhoods WHERE name = 'Hayes Valley';

        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Tony''s Pizza Napoletana', 'Italian', '$$', 4.5, 37.8064, -122.4098 FROM neighborhoods WHERE name = 'North Beach';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Molinari Delicatessen', 'Italian', '$', 4.6, 37.7986, -122.4079 FROM neighborhoods WHERE name = 'North Beach';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Caffe Trieste', 'Cafe', '$', 4.3, 37.8010, -122.4110 FROM neighborhoods WHERE name = 'North Beach';

        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'The Cheese School', 'American', '$$', 4.1, 37.7724, -122.4028 FROM neighborhoods WHERE name = 'SoMa';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Bar Agricole', 'American', '$$$', 4.4, 37.7719, -122.4092 FROM neighborhoods WHERE name = 'SoMa';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Sushi Zone', 'Japanese', '$$', 4.3, 37.7790, -122.4030 FROM neighborhoods WHERE name = 'SoMa';

        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Frances', 'French', '$$$$', 4.8, 37.7611, -122.4348 FROM neighborhoods WHERE name = 'Castro';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Hot Cookie', 'Dessert', '$', 4.5, 37.7614, -122.4351 FROM neighborhoods WHERE name = 'Castro';

        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Firefly', 'American', '$$$', 4.6, 37.7508, -122.4322 FROM neighborhoods WHERE name = 'Noe Valley';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Bacon Bacon', 'American', '$$', 4.0, 37.7514, -122.4340 FROM neighborhoods WHERE name = 'Noe Valley';

        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'House of Prime Rib', 'American', '$$$', 4.7, 37.7913, -122.4218 FROM neighborhoods WHERE name = 'Richmond District';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Burma Superstar', 'Burmese', '$$', 4.5, 37.7809, -122.4636 FROM neighborhoods WHERE name = 'Richmond District';

        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'A16', 'Italian', '$$$', 4.4, 37.8005, -122.4356 FROM neighborhoods WHERE name = 'Marina District';
        INSERT INTO restaurants (neighborhood_id, name, cuisine, price_range, rating, latitude, longitude)
            SELECT neighborhood_id, 'Blue Barn Gourmet', 'American', '$$', 4.2, 37.7998, -122.4386 FROM neighborhoods WHERE name = 'Marina District';
        COMMIT;

        -- theaters: 1-2 per neighborhood
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Alamo Drafthouse New Mission', 6, '2550 Mission St', 37.7566, -122.4189 FROM neighborhoods WHERE name = 'Mission District';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'AMC Metreon 16', 16, '135 4th St', 37.7846, -122.4034 FROM neighborhoods WHERE name = 'SoMa';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Castro Theatre', 1, '429 Castro St', 37.7621, -122.4350 FROM neighborhoods WHERE name = 'Castro';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'Vogue Theatre', 1, '3290 Sacramento St', 37.7896, -122.4409 FROM neighborhoods WHERE name = 'Richmond District';
        INSERT INTO theaters (neighborhood_id, name, screen_count, address, latitude, longitude)
            SELECT neighborhood_id, 'CGV Cinemas', 8, '1746 Post St', 37.7853, -122.4308 FROM neighborhoods WHERE name = 'Richmond District';
        COMMIT;

        -- app_settings: current city default
        MERGE INTO app_settings s
        USING (SELECT 'current_city' AS setting_key, 'San Francisco' AS setting_value FROM dual) src
        ON (s.setting_key = src.setting_key)
        WHEN MATCHED THEN UPDATE SET setting_value = src.setting_value, updated_at = SYSTIMESTAMP
        WHEN NOT MATCHED THEN INSERT (setting_key, setting_value) VALUES (src.setting_key, src.setting_value);
        COMMIT;
    END reload_oracle_seed_data;

END admin_pkg;
/
