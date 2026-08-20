# NestWise — Architecture

## Assumptions (read this first)

NestWise is built as a **single-city** neighborhood/restaurant/stay/entertainment/weather showcase on top of an **existing 2-node Oracle RAC cluster running Oracle Database 12c Release 2**. That cluster is real infrastructure the user already stood up, and this app is deliberately built to be a genuine application workload against it — not just a slide-deck demo — so its query patterns, the Swingbench numbers in `loadtest/`, and the concurrent-session behavior all say something real about the RAC build. A public concept page (linkdapp.github.io/NestWise) describes a phased v1 (pure Oracle) → v2 (add MongoDB) roadmap; the user explicitly opted out of that phasing for this build and asked for the **full hybrid feature set in one MVP**, so everything below — Oracle and MongoDB both — is built now, not staged. "Current city" is a single app setting (`app_settings.current_city`), not a multi-city switcher — NestWise runs for one city at a time by design.

Because the target Oracle version is 12c R2, this build does **not** use ORDS's native MongoDB Database API as the hybrid access path — that API's SODA-backed collection proxying is only reliably supported on newer Oracle/ORDS combinations (effectively 19c+), and betting a demo on an unsupported path on a 12c cluster would be the opposite of minimalist. Instead, MongoDB is fronted by a small, single-purpose Node/Express proxy (`proxy/`) that exposes plain JSON GET endpoints shaped exactly like what each APEX page needs, registered in APEX as REST Data Sources — see "How APEX reaches each tier" below. Authentication is APEX's built-in `Application Express Accounts` scheme; no LDAP/SSO. Scoped out of this MVP on purpose: multi-city switching, real geocoding/mapping APIs (lat/long is seeded, not geocoded live), a trained recommendation model (the "recommend for me" logic is an explicit weighted-sum heuristic, not ML), and user-to-user features (messaging, social). Each of those follows the same patterns already in this codebase if added later.

## The pattern

One app server runs APEX + ORDS together in front of two data tiers. Oracle (on the RAC cluster) is the source of truth for anything structured and relational; MongoDB (a single standalone server) owns the document-shaped content — Airbnb-style listings with embedded reviews, mflix-style movie documents, and weather snapshots.

```
                        ┌───────────────────────────────┐
                        │         Browser / User          │
                        └────────────────┬─────────────────┘
                                          │ HTTPS
                        ┌─────────────────▼─────────────────┐
                        │     APEX + ORDS   (one app server)  │
                        │   - APEX engine renders pages        │
                        │   - ORDS serves REST + web listener  │
                        └───────┬───────────────────┬─────────┘
              native SQL/PLSQL   │                   │  REST Data Source
              (fast path, no      │                   │  (APEX Shared Component)
               extra hop)         │                   │  → GET /api/... JSON
                                   │                   │
                    ┌──────────────▼──────┐   ┌────────▼─────────────────┐
                    │   Oracle RAC 12cR2     │   │   Node/Express proxy      │
                    │   (2-node cluster,     │   │   (thin, read-only,       │
                    │    SCAN listener)      │   │    a handful of GET       │
                    │                        │   │    endpoints + one        │
                    │   source of truth:     │   │    admin reload POST)     │
                    │   neighborhoods,       │   └────────┬──────────────┘
                    │   restaurants,         │            │ MongoDB driver
                    │   theaters,            │            │
                    │   user_preferences,    │   ┌────────▼──────────────┐
                    │   user_favorites,      │   │   MongoDB (standalone)  │
                    │   app_settings         │   │   listings (+ reviews)  │
                    └────────────────────────┘   │   mflix_movies          │
                                                  │   weather_snapshots     │
                                                  └─────────────────────────┘
```

**Why this split:** Oracle enforces referential integrity and does cheap joins/aggregates for anything with a fixed shape — a neighborhood has a fixed set of columns, a restaurant has a fixed set of columns, a rating rollup is a GROUP BY. MongoDB is the better fit for records whose shape genuinely varies per record: a listing's amenities array differs listing to listing, its reviews are a nested array of arbitrary length, and an mflix-style movie document has fields (cast, awards, plot) that don't map cleanly to a rigid relational table without either a wide nullable table or a maze of child tables. Forcing those into Oracle would mean modeling document-shaped data relationally for no real benefit; forcing neighborhoods/restaurants into MongoDB would throw away Oracle's referential integrity and join performance for data that is already a great relational fit. Each tier does the part it's actually good at.

## How APEX reaches each tier

- **Oracle data** (neighborhoods, restaurants, theaters, favorites, preferences, settings): native SQL in page regions and PL/SQL packages (`nbhd_pkg`, `restaurant_pkg`, `prefs_pkg`, `admin_pkg`) called from page processes and Dynamic Actions. This is the fast, zero-extra-hop path and is used everywhere the data already lives in Oracle. The same packages are also exposed via ORDS handlers for anything an external consumer might need.
- **MongoDB data** (listings, mflix_movies, weather_snapshots): APEX **REST Data Sources** pointed at the Node/Express proxy in `proxy/`. The proxy is intentionally thin — five read GET endpoints that match the exact shape each page needs (`/api/listings`, `/api/listings/:id`, `/api/movies/popular`, `/api/theaters/:id/movies`, `/api/weather/current`) plus one `POST /api/admin/reload` used only by the Admin/Seed page. No generic passthrough, no ORM, no business logic in the proxy beyond "run this query, return this JSON." Direct PL/SQL-to-Mongo drivers were deliberately avoided — that would re-introduce the coupling the Oracle/Mongo split exists to avoid.
- The **detail page that visibly stitches both tiers together** — Neighborhood Detail, which shows Oracle-sourced restaurant/theater data next to Mongo-sourced listings/weather/movies for that neighborhood on one page — is the page that carries the "hybrid" story in the demo (see `docs/demo-script.md`).

## Data ownership summary

| Domain | Tier | Why |
|---|---|---|
| Neighborhoods, restaurants, theaters | Oracle | Fixed shape, relational, needs joins/aggregates |
| User preferences, favorites, app settings | Oracle | Transactional, small, referential integrity matters (FK to neighborhoods) |
| Airbnb-style listings + embedded reviews | MongoDB | Variable amenities array, nested reviews of arbitrary length |
| mflix-style popular movies | MongoDB | Sample mflix dataset shape (cast, genres, awards) varies per document |
| Weather snapshots | MongoDB | Time-series-ish, schema varies by provider/field availability, cheap to just append |

## RAC validation angle

Every APEX page in NestWise that touches Oracle runs through the app server's connection pool against the RAC SCAN listener, so ordinary demo usage — Browse Neighborhoods, Restaurant Finder filters, the favorite toggle, the recommendation-score query — is already exercising both RAC nodes under normal load-balanced connections. The Swingbench section (`loadtest/swingbench/`) pushes that further with actual concurrent sessions, which is the real point of building NestWise on this cluster rather than a single-instance XE box: it produces genuine AWR/RAC wait-event data, not synthetic traffic, to validate the HA build.
