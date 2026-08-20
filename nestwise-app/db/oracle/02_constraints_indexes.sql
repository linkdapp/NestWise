-- =============================================================================
-- NestWise — 02_constraints_indexes.sql
-- Every FK column indexed (Oracle does not auto-index FKs — unindexed FKs are
-- the most common source of avoidable locking/full scans under load), plus
-- indexes matching the app's actual filter/sort patterns from each page.
-- =============================================================================

-- ---- Foreign key indexes (mandatory, not optional) -------------------------

CREATE INDEX ix_restaurants_neighborhood   ON restaurants(neighborhood_id);
CREATE INDEX ix_theaters_neighborhood      ON theaters(neighborhood_id);
CREATE INDEX ix_user_favorites_nbhd        ON user_favorites(neighborhood_id);

-- ---- Neighborhood Explorer: name search, city filter (single-city app, but
-- keep the column indexed since seed data / future cities may vary) --------

CREATE INDEX ix_neighborhoods_city         ON neighborhoods(city);
CREATE INDEX ix_neighborhoods_name         ON neighborhoods(name);

-- ---- Restaurant Finder: filter by cuisine, price range, rating, and the
-- dominant compound pattern "restaurants in this neighborhood, filtered by
-- cuisine" (used by the Neighborhood Detail page's restaurant list). -------

CREATE INDEX ix_restaurants_cuisine        ON restaurants(cuisine);
CREATE INDEX ix_restaurants_price_range    ON restaurants(price_range);
CREATE INDEX ix_restaurants_rating         ON restaurants(rating);
CREATE INDEX ix_restaurants_nbhd_cuisine   ON restaurants(neighborhood_id, cuisine);

-- ---- Recommendation scoring (Restaurant Finder "recommend for me"): the
-- heuristic filters/sorts on cuisine + price_range + rating together, so a
-- composite index matching that predicate order pays off under load. -------

CREATE INDEX ix_restaurants_reco           ON restaurants(cuisine, price_range, rating DESC);

COMMIT;
