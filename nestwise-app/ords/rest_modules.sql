-- =============================================================================
-- NestWise — ords/rest_modules.sql
-- Run connected as the NESTWISE schema (ORDS.DEFINE_MODULE etc. operate on
-- the current schema's REST modules). One module per resource family,
-- resource-oriented templates, PUBLISHED explicitly (see
-- references/ords-rest-modules.md checklist). GET-only except the
-- favorite-toggle and admin-reload actions, which reuse APEX's own
-- authenticated session context when called from the app, and are otherwise
-- guarded at the ORDS privilege level for any external caller.
--
-- Caught before ever being run against this project's own lab: the five
-- handlers wrapping a SYS_REFCURSOR-returning function (nbhd_pkg.get_stats,
-- restaurant_pkg.search, restaurant_pkg.recommend_for_user,
-- prefs_pkg.get_preferences, admin_pkg.get_dashboard_counts) originally used
-- `SELECT * FROM TABLE(CAST(fn(:bind) AS SYS_REFCURSOR))` — not valid Oracle
-- SQL; TABLE() only accepts a nested-table/collection type, never a REF
-- CURSOR, so every one of those five endpoints would have failed at request
-- time with a SQL error. Confirmed against Oracle's own documented ORDS
-- pattern (thatjeffsmith.com, "Four options for working with ORDS PL/SQL
-- REFCURSORS") before fixing, not guessed: for a FUNCTION that returns
-- SYS_REFCURSOR, the correct p_source_type is ORDS.source_type_collection_feed
-- with a plain `SELECT function(:bind) FROM DUAL` — no TABLE()/CAST wrapper.
-- All five fixed below.
--
-- Second bug, hit for real against this project's own lab (ORA-01400: cannot
-- insert NULL into ORDS_METADATA.ORDS_TEMPLATES.URI_TEMPLATE, on the very
-- first DEFINE_TEMPLATE call): the module-root templates for neighborhoods.api
-- and restaurants.api used p_pattern => '' (empty string). Oracle treats a
-- zero-length VARCHAR2 as NULL, and URI_TEMPLATE is NOT NULL, so this fails
-- immediately. Confirmed against Oracle's own ORDS_ADMIN package reference
-- before fixing: every documented example of a module's root resource uses
-- p_pattern => '.' (a single dot), never ''. Both occurrences fixed below.
--
-- Third bug, only found once this script actually ran clean and every
-- endpoint still returned an empty/garbled result: the "SELECT
-- fn(:bind) FROM DUAL" pattern (the fix for the first bug above) compiles
-- and runs without error, but does NOT reliably unwrap a SYS_REFCURSOR into
-- real rows on ORDS 26.2 — confirmed empirically, not by more guessing: the
-- five affected endpoints returned {"items":[{"<literal source
-- text>":[]}]}, i.e. ORDS treated the REF CURSOR cell as an opaque,
-- unserializable value instead of unwrapping it, regardless of whether the
-- underlying function logically returns one row or many. All five handlers
-- rewritten below to inline the same SQL the PL/SQL function already runs
-- (verified against the real function bodies in db/oracle/03_packages.sql)
-- instead of wrapping the function call — the exact technique already
-- proven working by this file's three plain-SQL handlers
-- (neighborhoods/, neighborhoods/:id/restaurants, neighborhoods/:id/theaters).
-- =============================================================================

BEGIN
    -- =========================================================================
    -- neighborhoods.api
    -- =========================================================================
    ORDS.DEFINE_MODULE(
        p_module_name    => 'neighborhoods.api',
        p_base_path      => '/neighborhoods/',
        p_items_per_page => 25,
        p_status         => 'PUBLISHED',
        p_comments       => 'Neighborhood browse + stats + favorite-toggle endpoints'
    );

    ORDS.DEFINE_TEMPLATE(p_module_name => 'neighborhoods.api', p_pattern => '.');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'neighborhoods.api',
        p_pattern        => '.',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_source         =>
            'SELECT neighborhood_id, name, city, description, latitude, longitude
               FROM neighborhoods
              WHERE city = NVL(:city, city)
              ORDER BY name'
    );

    ORDS.DEFINE_TEMPLATE(p_module_name => 'neighborhoods.api', p_pattern => ':id');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'neighborhoods.api',
        p_pattern        => ':id',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_source         =>
            'SELECT n.neighborhood_id,
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
              WHERE n.neighborhood_id = :id
              GROUP BY n.neighborhood_id, n.name, n.city, n.description, n.latitude, n.longitude'
    );

    ORDS.DEFINE_TEMPLATE(p_module_name => 'neighborhoods.api', p_pattern => ':id/restaurants');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'neighborhoods.api',
        p_pattern        => ':id/restaurants',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_source         =>
            'SELECT restaurant_id, name, cuisine, price_range, rating, latitude, longitude
               FROM restaurants
              WHERE neighborhood_id = :id
              ORDER BY rating DESC'
    );

    ORDS.DEFINE_TEMPLATE(p_module_name => 'neighborhoods.api', p_pattern => ':id/theaters');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'neighborhoods.api',
        p_pattern        => ':id/theaters',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_source         =>
            'SELECT theater_id, name, screen_count, address, latitude, longitude
               FROM theaters
              WHERE neighborhood_id = :id
              ORDER BY name'
    );

    ORDS.DEFINE_TEMPLATE(p_module_name => 'neighborhoods.api', p_pattern => ':id/favorite');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'neighborhoods.api',
        p_pattern        => ':id/favorite',
        p_method         => 'POST',
        p_source_type    => ORDS.source_type_plsql,
        p_source         =>
            'BEGIN
                nbhd_pkg.toggle_favorite(p_app_user => :app_user, p_neighborhood_id => :id);
             END;'
    );

    -- =========================================================================
    -- restaurants.api
    -- =========================================================================
    ORDS.DEFINE_MODULE(
        p_module_name    => 'restaurants.api',
        p_base_path      => '/restaurants/',
        p_items_per_page => 25,
        p_status         => 'PUBLISHED',
        p_comments       => 'Restaurant Finder search + recommendation endpoints'
    );

    ORDS.DEFINE_TEMPLATE(p_module_name => 'restaurants.api', p_pattern => '.');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'restaurants.api',
        p_pattern        => '.',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_source         =>
            'SELECT r.restaurant_id,
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
              WHERE (:neighborhood_id IS NULL OR r.neighborhood_id = :neighborhood_id)
                AND (:cuisine IS NULL OR r.cuisine = :cuisine)
                AND (:price_range IS NULL OR r.price_range = :price_range)
                AND (:min_rating IS NULL OR r.rating >= :min_rating)
              ORDER BY r.rating DESC, r.name'
    );

    ORDS.DEFINE_TEMPLATE(p_module_name => 'restaurants.api', p_pattern => 'cuisines');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'restaurants.api',
        p_pattern        => 'cuisines',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_source         => 'SELECT DISTINCT cuisine FROM restaurants ORDER BY cuisine'
    );

    ORDS.DEFINE_TEMPLATE(p_module_name => 'restaurants.api', p_pattern => 'recommend/:app_user');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'restaurants.api',
        p_pattern        => 'recommend/:app_user',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_source         =>
            'SELECT r.restaurant_id,
                    r.name,
                    r.cuisine,
                    r.price_range,
                    r.rating,
                    n.name AS neighborhood_name,
                    (CASE WHEN r.cuisine = up.preferred_cuisine THEN 3 ELSE 0 END) +
                    (CASE WHEN restaurant_pkg.price_rank(r.price_range)
                               <= restaurant_pkg.price_rank(NVL(up.budget_price_range, ''$$''))
                          THEN 2 ELSE 0 END) +
                    r.rating AS recommend_score
               FROM restaurants r
               JOIN neighborhoods n ON n.neighborhood_id = r.neighborhood_id
               LEFT JOIN user_preferences up ON up.app_user = :app_user
              ORDER BY recommend_score DESC, r.rating DESC
              FETCH FIRST 10 ROWS ONLY'
    );

    -- =========================================================================
    -- preferences.api  (User Profile)
    -- =========================================================================
    ORDS.DEFINE_MODULE(
        p_module_name    => 'preferences.api',
        p_base_path      => '/preferences/',
        p_items_per_page => 1,
        p_status         => 'PUBLISHED',
        p_comments       => 'Simple user preference get/save, drives recommendation scoring'
    );

    ORDS.DEFINE_TEMPLATE(p_module_name => 'preferences.api', p_pattern => ':app_user');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'preferences.api',
        p_pattern        => ':app_user',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_source         =>
            'SELECT preferred_cuisine, budget_price_range, weather_preference
               FROM user_preferences
              WHERE app_user = :app_user'
    );

    ORDS.DEFINE_HANDLER(
        p_module_name    => 'preferences.api',
        p_pattern        => ':app_user',
        p_method         => 'PUT',
        p_source_type    => ORDS.source_type_plsql,
        p_source         =>
            'BEGIN
                prefs_pkg.save_preferences(
                    p_app_user           => :app_user,
                    p_preferred_cuisine  => :preferred_cuisine,
                    p_budget_price_range => :budget_price_range,
                    p_weather_preference => :weather_preference
                );
             END;'
    );

    -- =========================================================================
    -- admin.api  (Admin / Seed Data page — Oracle side)
    -- =========================================================================
    ORDS.DEFINE_MODULE(
        p_module_name    => 'admin.api',
        p_base_path      => '/admin/',
        p_items_per_page => 1,
        p_status         => 'PUBLISHED',
        p_comments       => 'Dashboard counts + Oracle seed-data reload for the Admin page'
    );

    ORDS.DEFINE_TEMPLATE(p_module_name => 'admin.api', p_pattern => 'dashboard-counts');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'admin.api',
        p_pattern        => 'dashboard-counts',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_collection_feed,
        p_source         =>
            'SELECT (SELECT COUNT(*) FROM neighborhoods WHERE city = admin_pkg.get_current_city) AS neighborhood_count,
                    (SELECT COUNT(*) FROM restaurants r
                       JOIN neighborhoods n ON n.neighborhood_id = r.neighborhood_id
                      WHERE n.city = admin_pkg.get_current_city)                                  AS restaurant_count,
                    (SELECT COUNT(*) FROM theaters t
                       JOIN neighborhoods n ON n.neighborhood_id = t.neighborhood_id
                      WHERE n.city = admin_pkg.get_current_city)                                  AS theater_count
               FROM dual'
    );

    ORDS.DEFINE_TEMPLATE(p_module_name => 'admin.api', p_pattern => 'reload-oracle');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'admin.api',
        p_pattern        => 'reload-oracle',
        p_method         => 'POST',
        p_source_type    => ORDS.source_type_plsql,
        p_source         => 'BEGIN admin_pkg.reload_oracle_seed_data; END;'
    );

    COMMIT;
END;
/
