-- =============================================================================
-- NestWise — ords/rest_modules.sql
-- Run connected as the NESTWISE schema (ORDS.DEFINE_MODULE etc. operate on
-- the current schema's REST modules). One module per resource family,
-- resource-oriented templates, PUBLISHED explicitly (see
-- references/ords-rest-modules.md checklist). GET-only except the
-- favorite-toggle and admin-reload actions, which reuse APEX's own
-- authenticated session context when called from the app, and are otherwise
-- guarded at the ORDS privilege level for any external caller.
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

    ORDS.DEFINE_TEMPLATE(p_module_name => 'neighborhoods.api', p_pattern => '');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'neighborhoods.api',
        p_pattern        => '',
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
        p_source_type    => ORDS.source_type_media,
        p_mimes_allowed  => 'application/json',
        p_source         => 'SELECT * FROM TABLE(CAST(nbhd_pkg.get_stats(:id) AS SYS_REFCURSOR))'
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

    ORDS.DEFINE_TEMPLATE(p_module_name => 'restaurants.api', p_pattern => '');
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'restaurants.api',
        p_pattern        => '',
        p_method         => 'GET',
        p_source_type    => ORDS.source_type_media,
        p_mimes_allowed  => 'application/json',
        p_source         =>
            'SELECT * FROM TABLE(CAST(
                 restaurant_pkg.search(
                     p_neighborhood_id => :neighborhood_id,
                     p_cuisine         => :cuisine,
                     p_price_range     => :price_range,
                     p_min_rating      => :min_rating
                 ) AS SYS_REFCURSOR))'
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
        p_source_type    => ORDS.source_type_media,
        p_mimes_allowed  => 'application/json',
        p_source         =>
            'SELECT * FROM TABLE(CAST(restaurant_pkg.recommend_for_user(:app_user) AS SYS_REFCURSOR))'
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
        p_source_type    => ORDS.source_type_media,
        p_mimes_allowed  => 'application/json',
        p_source         => 'SELECT * FROM TABLE(CAST(prefs_pkg.get_preferences(:app_user) AS SYS_REFCURSOR))'
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
        p_source_type    => ORDS.source_type_media,
        p_mimes_allowed  => 'application/json',
        p_source         => 'SELECT * FROM TABLE(CAST(admin_pkg.get_dashboard_counts() AS SYS_REFCURSOR))'
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
