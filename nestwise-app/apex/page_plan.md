# NestWise — APEX application structure (page plan)

Single APEX application, APEX built-in authentication (`Application Express Accounts` scheme — see `references/apex-page-structure.md`). Navigation menu maps 1:1 to the eight feature areas from the brief plus Admin. Every page filters implicitly by the "current city" app setting (`app_settings.current_city`, read once per session into an application item `G_CURRENT_CITY` on login) — there is no city switcher UI, matching the one-city-at-a-time scope decision in `docs/architecture.md`.

Application items: `G_CURRENT_CITY` (set on authentication post-processing from `admin_pkg.get_current_city`). Substitution string `&APP_USER.` is used everywhere a page needs the logged-in user (favorites, preferences, recommendations).

| # | Page | Type | Region(s) | Data source | Processes / Dynamic Actions |
|---|------|------|-----------|-------------|------------------------------|
| 1 | **Home / Dashboard** | Cards (value/tile mode) + Chart | 4 tiles: Neighborhoods, Restaurants, Listings, Current Weather; one small bar Chart region ("avg rating by neighborhood") | Oracle: `admin_pkg.get_dashboard_counts` (neighborhoods/restaurants tiles) + chart query. **Mongo (via REST Data Source `RDS_LISTINGS`)**: listings count computed as `COUNT(*)` region source against `/api/listings`. **Mongo (`RDS_WEATHER_CURRENT`)**: weather tile from `/api/weather/current?city=`. | Page Load process populates `G_CURRENT_CITY` if not already set. No DAs — pure read page. |
| 2 | **Neighborhood Explorer** | Interactive Report | One IR: name, description, avg restaurant rating, restaurant count, theater count, listings count (mongo, joined client-side via a post-query column formatter calling the REST Data Source), favorite icon | Oracle: `nbhd_pkg.list_neighborhoods(:P2_CITY, :P2_SEARCH)`. Listings-count column: **Mongo REST Data Source** `RDS_LISTINGS`, filtered per row via a PL/SQL dynamic column (or, simpler and preferred, a small AJAX callback per visible row — see note below). | DA on the favorite icon (click) → PL/SQL process `nbhd_pkg.toggle_favorite(:APP_USER, :ROW_NEIGHBORHOOD_ID)` → refresh the icon's column only (no full-page reload). Page item `P2_SEARCH` (text field) + Dynamic Action "keyup" → refresh IR. |
| 3 | **Neighborhood Detail** (`neighborhood_id` in URL) | Two regions stacked — **this is the hybrid-story page** | Region A "Overview" (Oracle): stats + restaurant list + theater list. Region B "Stay & Weather Here" (Mongo, side-by-side sub-regions): listings Cards region + weather mini-chart, both sourced from the proxy for this one `neighborhood_id`. | Oracle: `nbhd_pkg.get_stats(:P3_NEIGHBORHOOD_ID)`, `restaurant_pkg.search(p_neighborhood_id => :P3_NEIGHBORHOOD_ID)`, `theater_pkg.list_by_neighborhood`. Mongo: `RDS_LISTINGS` filtered `?neighborhood_id=`, `RDS_WEATHER_NEIGHBORHOOD` `/api/weather/neighborhood/:id`. | Same favorite-toggle DA as page 2, scoped to this neighborhood. Page Load sets a Region B caption noting "Oracle ↔ MongoDB, same page" for the demo. |
| 4 | **Restaurant Finder** | Interactive Report (default) with a "Map" alternate view | Filter region (Select Lists: Cuisine, Price Range, Rating minimum) + IR/Map region | Oracle: `restaurant_pkg.search(:P4_NEIGHBORHOOD_ID, :P4_CUISINE, :P4_PRICE_RANGE, :P4_MIN_RATING)`. Cuisine select list populated from `restaurant_pkg.list_cuisines`. Map region plotted on `latitude`/`longitude`. | DA on each filter item (change) → Submit/refresh region. No custom JS — native IR filtering plus the page items. |
| 5 | **Restaurant Finder — Recommend for Me** | Cards region (sub-tab or button toggle on page 4) | "Recommended for you" Cards, ordered by score, badge showing the score | Oracle: `restaurant_pkg.recommend_for_user(:APP_USER)`. | Button "Recommend for me" → region refresh. Explicit static text on the page: "Simple weighted heuristic — cuisine match + budget fit + rating, not a trained model." |
| 6 | **Stay / Listings** | Cards region | Listing cards: title, price/night, avg rating, amenities badges, neighborhood name (looked up client-side from a hidden Oracle neighborhoods LOV cached in a page item) | **Mongo REST Data Source** `RDS_LISTINGS` (`GET /api/listings?neighborhood_id=`, optional filter item `P6_NEIGHBORHOOD_ID`) | Filter item (neighborhood Select List, LOV from Oracle `neighborhoods`) → DA refresh Cards region. |
| 7 | **Stay / Listings — Detail** (`listing_id` in URL, Mongo `_id`) | Two regions | Region A: listing details (price, amenities, neighborhood link back to Oracle). Region B: embedded reviews as a Classic Report against the same JSON (APEX can walk the nested `reviews` array from a REST Data Source region with a nested list, or a small "Reviews" sub-region using the JSON path) | **Mongo REST Data Source** `RDS_LISTING_DETAIL` (`GET /api/listings/:id`) | None — read-only detail page. |
| 8 | **Stay / Listings — Recommend for Me** | Cards region (sub-tab or button on page 6) | Recommended listings, ordered by score | **Mongo REST Data Source** `RDS_LISTINGS_RECOMMEND` (`GET /api/listings/recommend/for-user?budget=&weather=`, params bound to the user's saved Oracle preferences via `prefs_pkg.get_preferences`, passed as REST Data Source parameters) | Page Load process reads `prefs_pkg.get_preferences(:APP_USER)` into page items `P8_BUDGET`/`P8_WEATHER`, then the REST Data Source region uses them as bind parameters. |
| 9 | **Entertainment** | Two regions side-by-side | Region A "Nearby Theaters" (Oracle, Classic Report). Region B "Popular Movies" (Mongo, Cards) | Oracle: `theater_pkg.list_by_neighborhood(:P9_NEIGHBORHOOD_ID)`. Mongo: `RDS_MOVIES_POPULAR` (`GET /api/movies/popular?neighborhood_id=`). | Neighborhood Select List (LOV from Oracle `neighborhoods`) → DA refreshes both regions in parallel. |
| 10 | **Weather Context** | Chart region + Classic Report | Line/bar Chart ("last 5 observations, this neighborhood"), plus a small report of raw snapshot rows | **Mongo REST Data Source** `RDS_WEATHER_NEIGHBORHOOD` (`GET /api/weather/neighborhood/:id`). City-level default view uses `RDS_WEATHER_CURRENT`. | Neighborhood Select List → DA refresh. |
| 11 | **User Profile** | Form | Simple form: Preferred Cuisine (Select List, LOV from `restaurant_pkg.list_cuisines`), Budget (Select List `$`.. `$$$$`), Weather Preference (Select List: cold/mild/warm/hot/any) | Oracle: `prefs_pkg.get_preferences` / `prefs_pkg.save_preferences` | Page Load: fetch existing prefs. Submit button → process calling `prefs_pkg.save_preferences(:APP_USER, :P11_CUISINE, :P11_BUDGET, :P11_WEATHER)`, then success message. |
| 12 | **Admin / Seed Data** | Classic Report (status) + Buttons | Small "last reload" status region + two buttons: "Reload Oracle Seed Data", "Reload MongoDB Seed Data" | Oracle: `admin_pkg.get_dashboard_counts` as a before/after sanity check. Mongo: none directly (write goes through the proxy). | Button 1 → PL/SQL process `admin_pkg.reload_oracle_seed_data`, then refresh the status region. Button 2 → PL/SQL process using `APEX_WEB_SERVICE.MAKE_REST_REQUEST` to `POST {proxy_base_url}/api/admin/reload` with header `X-Nestwise-Admin-Token` (stored in an APEX Web Credential, not hardcoded), then refresh the status region. Both buttons require the `Admin` authorization scheme (see below). |

## Region-type choices, and why (per `references/apex-page-structure.md`)

- **Interactive Report** for Neighborhood Explorer and default Restaurant Finder — free filter/sort/export, fastest to build, exactly the "browsable list with search" job.
- **Cards** for anything visual/browsable-by-eye: Dashboard tiles, Stay/Listings, Restaurant/Listings recommendations, Popular Movies. Cards' built-in image/badge/metadata attributes are used directly from the query — no custom HTML templates.
- **Map region** on Restaurant Finder (alternate view) because the data already has lat/long from seed — no geocoding infrastructure added just to unlock it, per the reference's explicit caution.
- **Chart region** only on the Dashboard (avg rating by neighborhood) and Weather Context (temperature/score trend) — both are genuinely clearer as a chart than as numbers; no chart added elsewhere just to have one.
- **Classic Report** for Entertainment's theater list and Weather Context's raw snapshot rows — simple, low-cardinality data where an IR's extra filter/export chrome isn't worth it.
- **Dynamic Action + PL/SQL process**, not a page submit/reload, for the favorite toggle — refreshes only the affected card/row per the reference's guidance.
- No custom JavaScript anywhere in this plan — every region above is a native APEX component.

## Recommendation scoring — explicit heuristic, not ML

Both "Recommend for me" surfaces (Restaurant Finder page 5, Stay/Listings page 8) use a plain weighted-sum score computed server-side (`restaurant_pkg.recommend_for_user` in PL/SQL; the equivalent logic in `proxy/routes/listings.js` for Mongo-backed listings, since that score needs to read Mongo's own `avg_rating`/`amenities`/neighborhood weather together). Both pages carry a one-line static-text disclosure ("simple weighted heuristic, not a trained model") — see `references/apex-page-structure.md`, which calls this out explicitly as the right level of honesty for this audience.

## REST Data Sources to register (Shared Components)

| Name | Endpoint | Used by page(s) |
|---|---|---|
| `RDS_LISTINGS` | `GET {proxy_base_url}/api/listings` | 1, 2, 3, 6 |
| `RDS_LISTING_DETAIL` | `GET {proxy_base_url}/api/listings/{id}` | 7 |
| `RDS_LISTINGS_RECOMMEND` | `GET {proxy_base_url}/api/listings/recommend/for-user` | 8 |
| `RDS_MOVIES_POPULAR` | `GET {proxy_base_url}/api/movies/popular` | 9 |
| `RDS_WEATHER_CURRENT` | `GET {proxy_base_url}/api/weather/current` | 1, 10 |
| `RDS_WEATHER_NEIGHBORHOOD` | `GET {proxy_base_url}/api/weather/neighborhood/{id}` | 3, 10 |

`{proxy_base_url}` is an APEX application substitution string set once in `docs/install.md` (e.g. `http://appserver:4000`), so switching proxy hosts is a one-line change, not a per-region edit. Test every one of the six in the REST Data Source wizard before wiring it into a region, per `references/ords-rest-modules.md`.

## Authorization scheme

One extra authorization scheme, `Admin`, restricted to a static list of APEX usernames (an application item or a small `ADMIN` check against `user_preferences`/a hardcoded allow-list — kept simple on purpose), applied only to page 12's two buttons. Everything else uses the default "must be logged in" authentication scheme.

## Navigation

Left nav (or top nav bar, standard APEX Universal Theme): Home, Neighborhoods, Restaurants, Stay, Entertainment, Weather, Profile, Admin — eight entries, matching the eight feature areas from the brief one-for-one, so the nav itself is the feature map.
