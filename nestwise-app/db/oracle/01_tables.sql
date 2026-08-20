-- =============================================================================
-- NestWise — 01_tables.sql
-- Oracle 12c R2 (RAC) — core structured/relational tables.
-- Run as the NESTWISE application schema (see docs/install.md for creation).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- app_settings: tiny key/value table for app-wide settings, notably the
-- single "current city" NestWise runs against (see docs/architecture.md —
-- this app is one-city-at-a-time by design, not a multi-city switcher).
-- ---------------------------------------------------------------------------
CREATE TABLE app_settings (
    setting_key     VARCHAR2(50)  NOT NULL,
    setting_value   VARCHAR2(200) NOT NULL,
    updated_at      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_app_settings PRIMARY KEY (setting_key)
);

-- ---------------------------------------------------------------------------
-- neighborhoods: the anchor entity. Every other domain object hangs off a
-- neighborhood (directly in Oracle, or via neighborhood_id reference in Mongo).
-- lat/long are seeded, not geocoded live (see architecture.md scope cuts) —
-- good enough for a Map region.
-- ---------------------------------------------------------------------------
CREATE TABLE neighborhoods (
    neighborhood_id   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name              VARCHAR2(100)  NOT NULL,
    city              VARCHAR2(100)  NOT NULL,
    description       VARCHAR2(4000),
    latitude          NUMBER(9,6),
    longitude         NUMBER(9,6),
    created_at        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT uq_neighborhoods_name_city UNIQUE (name, city)
);

-- ---------------------------------------------------------------------------
-- restaurants: Restaurant Finder domain. price_range and rating use CHECK
-- constraints rather than lookup tables — small, static domains, so a lookup
-- table would be dead weight per oracle-schema-patterns.md.
-- ---------------------------------------------------------------------------
CREATE TABLE restaurants (
    restaurant_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    neighborhood_id   NUMBER         NOT NULL,
    name              VARCHAR2(150)  NOT NULL,
    cuisine           VARCHAR2(50)   NOT NULL,
    price_range       VARCHAR2(4)    NOT NULL,
    rating            NUMBER(2,1)    NOT NULL,
    latitude          NUMBER(9,6),
    longitude         NUMBER(9,6),
    created_at        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_restaurants_neighborhood
        FOREIGN KEY (neighborhood_id) REFERENCES neighborhoods(neighborhood_id),
    CONSTRAINT ck_restaurants_price_range
        CHECK (price_range IN ('$','$$','$$$','$$$$')),
    CONSTRAINT ck_restaurants_rating
        CHECK (rating BETWEEN 0 AND 5)
);

-- ---------------------------------------------------------------------------
-- theaters: Entertainment domain, Oracle half (paired with mflix_movies in
-- MongoDB for "currently popular movies").
-- ---------------------------------------------------------------------------
CREATE TABLE theaters (
    theater_id        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    neighborhood_id   NUMBER         NOT NULL,
    name              VARCHAR2(150)  NOT NULL,
    screen_count      NUMBER(2)      DEFAULT 1 NOT NULL,
    address           VARCHAR2(250),
    latitude          NUMBER(9,6),
    longitude         NUMBER(9,6),
    created_at        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_theaters_neighborhood
        FOREIGN KEY (neighborhood_id) REFERENCES neighborhoods(neighborhood_id),
    CONSTRAINT ck_theaters_screen_count
        CHECK (screen_count BETWEEN 1 AND 30)
);

-- ---------------------------------------------------------------------------
-- user_favorites: favorited neighborhoods. Keyed on APEX's :APP_USER
-- (VARCHAR2) rather than a separate users table — APEX built-in
-- authentication already gives us a stable username, and a demo app doesn't
-- need a parallel identity table just to mirror it.
-- ---------------------------------------------------------------------------
CREATE TABLE user_favorites (
    app_user          VARCHAR2(255)  NOT NULL,
    neighborhood_id   NUMBER         NOT NULL,
    favorited_at      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_user_favorites PRIMARY KEY (app_user, neighborhood_id),
    CONSTRAINT fk_user_favorites_neighborhood
        FOREIGN KEY (neighborhood_id) REFERENCES neighborhoods(neighborhood_id)
);

-- ---------------------------------------------------------------------------
-- user_preferences: drives the recommendation heuristic used by Restaurant
-- Finder and Stay/Listings ("recommend for me"). One row per APEX user.
-- ---------------------------------------------------------------------------
CREATE TABLE user_preferences (
    app_user               VARCHAR2(255)  NOT NULL,
    preferred_cuisine      VARCHAR2(50),
    budget_price_range     VARCHAR2(4)    DEFAULT '$$',
    weather_preference     VARCHAR2(20)   DEFAULT 'mild',
    created_at             TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at             TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_user_preferences PRIMARY KEY (app_user),
    CONSTRAINT ck_user_prefs_budget
        CHECK (budget_price_range IN ('$','$$','$$$','$$$$')),
    CONSTRAINT ck_user_prefs_weather
        CHECK (weather_preference IN ('cold','mild','warm','hot','any'))
);
