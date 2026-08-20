# NestWise — MongoDB collections

Standalone MongoDB server (not part of the Oracle RAC cluster). Three collections, one per document-shaped feature area. See `docs/architecture.md` for why these three specifically live outside Oracle.

`neighborhood_id` fields are plain integers that match `neighborhoods.neighborhood_id` in Oracle exactly — that's the join key the Node/Express proxy (`proxy/`) and APEX use to stitch a page together across both tiers. This seed data assumes a **fresh** Oracle install (`db/oracle/99_seed_data.sql` run against an empty schema), where `neighborhoods` IDENTITY values come out as 1-8 in this order: 1 Mission District, 2 Hayes Valley, 3 North Beach, 4 SoMa, 5 Castro, 6 Noe Valley, 7 Richmond District, 8 Marina District. If you reload Oracle seed data into a schema that already has other rows, re-check these IDs before reloading Mongo, or reload both from empty together (see `docs/install.md`).

## Collections

### `listings` — Airbnb-style stays (Stay/Listings feature)

Reviews and amenities are **embedded** — always read together with the listing, never queried independently, so embedding avoids a pointless join per `mongodb-patterns.md`. `avg_rating` is denormalized onto the parent document (computed from the embedded reviews at seed time) purely so the Stay/Listings list page can sort by it without unwinding the reviews array per row.

```jsonc
{
  "_id": "ObjectId(...)",
  "neighborhood_id": 42,
  "title": "Sunny 1BR near the park",
  "price_per_night": 145,
  "amenities": ["wifi", "kitchen", "washer", "pet friendly"],
  "reviews": [
    { "author": "J. Rivera", "rating": 5, "text": "Great location.", "date": "2026-05-02" }
  ],
  "avg_rating": 4.5,
  "created_at": "2026-01-10T00:00:00Z"
}
```

### `mflix_movies` — currently popular movies (Entertainment feature)

mflix-style shape (genres/year/runtime/cast), paired with Oracle's `theaters` table. `neighborhood_ids` is an array reference — one movie can be "currently popular" near several neighborhoods' theaters, which is exactly the kind of variable-cardinality relationship that's awkward in a rigid junction table but natural as an array field.

```jsonc
{
  "_id": "ObjectId(...)",
  "title": "Midnight in the Garden",
  "genres": ["Drama", "Mystery"],
  "year": 2025,
  "runtime": 118,
  "cast": ["A. Chen", "M. Okonkwo"],
  "neighborhood_ids": [42, 57],
  "popularity_score": 82
}
```

### `weather_snapshots` — Weather Context feature

One document per observation. Deliberately not normalized into "current" vs. "historical" collections — a demo app just appends and reads the latest by `observed_at`.

```jsonc
{
  "_id": "ObjectId(...)",
  "city": "San Francisco",
  "neighborhood_id": 42,
  "observed_at": "2026-08-20T09:00:00Z",
  "temp_f": 64,
  "conditions": "Fog, clearing by noon",
  "weather_score": 7.2
}
```

## Indexes (`indexes.js`)

Every field a page filters or sorts on is indexed, matching the same discipline as the Oracle FK-index rule:

- `listings`: `neighborhood_id` (join to Oracle neighborhood, used on every Stay list/detail query), `avg_rating` descending (list-page default sort), `amenities` (multikey, for amenity filtering in "Recommend for me").
- `mflix_movies`: `neighborhood_ids` (multikey — "movies playing near this neighborhood"), `popularity_score` descending (Entertainment page default sort).
- `weather_snapshots`: compound `{ neighborhood_id: 1, observed_at: -1 }` — the actual query shape used everywhere ("latest snapshot for this neighborhood"); also `{ city: 1, observed_at: -1 }` for the Dashboard's city-level current-weather tile.

## Access from APEX

Fronted by the Node/Express proxy in `proxy/` (see `docs/architecture.md` for why the native ORDS MongoDB API path was not used on this Oracle 12c R2 build). The proxy exposes:

| Endpoint | Backing query |
|---|---|
| `GET /api/listings?neighborhood_id=` | `listings.find({neighborhood_id})` sorted by `avg_rating desc` |
| `GET /api/listings/:id` | `listings.findOne({_id})` — full document incl. embedded reviews |
| `GET /api/listings/recommend?cuisine=&budget=&weather=` | `listings.find()` scored client-side against amenities/price (see `apex/page_plan.md`) |
| `GET /api/movies/popular?neighborhood_id=` | `mflix_movies.find({neighborhood_ids: id})` sorted by `popularity_score desc` |
| `GET /api/weather/current?city=` | `weather_snapshots.find({city}).sort({observed_at:-1}).limit(1)` |
| `GET /api/weather/neighborhood/:id` | `weather_snapshots.find({neighborhood_id}).sort({observed_at:-1}).limit(5)` |
| `POST /api/admin/reload` | drops and reseeds all three collections from `seed_data.js` (Admin/Seed page only) |

Each is registered in APEX Shared Components → REST Data Sources, one per endpoint, exactly matching the region that consumes it (see `ords/rest_modules.sql` for the equivalent Oracle-side pattern, and `apex/page_plan.md` for which page uses which).
