# NestWise — MongoDB collections

Standalone MongoDB server (not part of the Oracle RAC cluster). Three collections, one per document-shaped feature area. See `docs/architecture.md` for why these three specifically live outside Oracle.

`neighborhood_id` fields are plain integers that match `neighborhoods.neighborhood_id` in Oracle exactly — that's the join key the Node/Express proxy (`proxy/`) and APEX use to stitch a page together across both tiers. This seed data assumes a **fresh** Oracle install (`db/oracle/99_seed_data.sql` run against an empty schema), where `neighborhoods` IDENTITY values come out as 1-28 in this order (Washington, D.C.):

| ID | Neighborhood | ID | Neighborhood | ID | Neighborhood | ID | Neighborhood |
|---|---|---|---|---|---|---|---|
| 1 | Georgetown | 8 | Navy Yard / Capitol Riverfront | 15 | Brookland | 22 | Glover Park |
| 2 | Capitol Hill | 9 | Foggy Bottom | 16 | H Street NE / Atlas District | 23 | Tenleytown |
| 3 | Dupont Circle | 10 | Penn Quarter / Chinatown | 17 | Anacostia | 24 | Friendship Heights |
| 4 | Adams Morgan | 11 | Mount Pleasant | 18 | Southwest Waterfront / The Wharf | 25 | Congress Heights |
| 5 | Columbia Heights | 12 | Cleveland Park | 19 | NoMa | 26 | Deanwood |
| 6 | U Street / Shaw | 13 | Woodley Park | 20 | Bloomingdale | 27 | Barracks Row |
| 7 | Logan Circle | 14 | Petworth | 21 | LeDroit Park | 28 | West End |

If you reload Oracle seed data into a schema that already has other rows, re-check these IDs before reloading Mongo, or reload both from empty together (see `docs/install.md`) — `admin_pkg.reload_oracle_seed_data` deletes and re-inserts but does not reset the `neighborhood_id` IDENTITY sequence, so a reload against a non-empty schema produces different IDs than the table above.

**Confirmed for real against this project's own lab, not just a theoretical caveat:** after several `reload_oracle_seed_data` runs during install/troubleshooting, Georgetown — `1` in the table above — came back as `neighborhood_id = 9` (`GET /ords/nestwise/neighborhoods/9`, see `docs/install.md` §3). Don't assume `1` when testing, demoing, or writing new queries against a schema that isn't freshly installed — look the current ID up first (e.g. `GET /ords/nestwise/neighborhoods/` or `SELECT neighborhood_id, name FROM neighborhoods WHERE name = '...'`).

**UPDATE — this drift became a real, live bug, and has been fixed.** Building
Neighborhood Detail's Mongo-backed Region B (Stay & Weather Here) surfaced
the consequence directly: Oracle's IDs had drifted by a uniform **+8** across
all 28 rows (confirmed via `SELECT neighborhood_id, name FROM neighborhoods
ORDER BY neighborhood_id` — Georgetown 1→9, Barracks Row 27→35, West End
28→36), while every MongoDB collection below still used the original 1-28
numbering. This wasn't just cosmetic — a test against Georgetown's *current*
Oracle ID (9) returned real, non-empty MongoDB data that looked plausible
but actually belonged to the *original* ID 9, Foggy Bottom, silently
mislabeled as Georgetown's. Fixed for real via
`db/mongodb/remap_neighborhood_ids.js` (a one-time, idempotent +8 shift
across `listings`, `weather_snapshots`, and `mflix_movies`'
`neighborhood_ids` array), run against the live server and confirmed: 56
listings, 56 weather snapshots, and 13 movies remapped, with both Barracks
Row and Georgetown re-verified to show correct, name-matched data afterward.

**FINAL RESOLUTION — the table above is authoritative again, permanently.**
The +8 remap described above was a one-time repair of a symptom. The cause was
fixed properly while building the Admin / Seed Data page, because that page's
whole purpose (reset state between demo runs) was the thing triggering the
drift: `neighborhoods.neighborhood_id` was `GENERATED ALWAYS AS IDENTITY`, and
`DELETE` never resets an identity sequence.

The identity was dropped and the seed script now inserts IDs **1-28
explicitly**, exactly as listed in the table above — see
`db/oracle/04_neighborhood_id_stability.sql` for the one-time migration and
`db/oracle/01_tables.sql` for the corrected DDL on fresh installs. Verified
live: the range moved `9-36` → `1-28`, with Georgetown = 1 and Barracks
Row = 27.

Consequences, all good:

- **The table above is the live mapping again** — not a historical snapshot.
  Both databases use it.
- **Reloading is idempotent.** `admin_pkg.reload_oracle_seed_data` and the
  proxy's `POST /api/admin/reload` can each be run any number of times, in any
  order, and the join key stays correct. The Admin page exercises both.
- **`remap_neighborhood_ids.js` is retired.** It is kept in this directory only
  as a record of the original repair; it should not be needed again. If you
  ever find yourself reaching for it, something has regressed — check whether
  `neighborhood_id` has an identity column again before remapping anything.

One field that *does* still change on every Mongo reseed: **`_id`**. Document
ObjectIds are regenerated each time the collections are dropped and reloaded.
This does not affect the running app (the Listing Detail page receives its id
from whichever card was clicked), but any hardcoded ObjectId — in a REST Data
Source's discovery/test default, or pasted into docs — goes stale immediately.
Current values are easiest to read from `RDS_LISTINGS` → Test Operation inside
APEX.

## Collections

### `listings` — Airbnb-style stays (Stay/Listings feature)

Reviews and amenities are **embedded** — always read together with the listing, never queried independently, so embedding avoids a pointless join per `mongodb-patterns.md`. `avg_rating` is denormalized onto the parent document purely so the Stay/Listings list page can sort and filter by it without unwinding the reviews array per row.

**Correction — `avg_rating` is NOT computed from the embedded reviews.** An
earlier version of this file claimed it was "computed from the embedded reviews
at seed time." That is false, and the seed data disproves it plainly: *Wharf
Pier View Condo* has exactly one review rated **5** but `avg_rating: 4.7`, and
*Waterfront Concert Venue Studio* has one review rated **5** but
`avg_rating: 4.5`. The two values are independent hand-authored numbers in
`seed_data.js`.

This is a deliberate simplification, not a bug — each listing carries one
illustrative review rather than the several a real average would need, and
`avg_rating` is set to a plausible listing-level figure. But the distinction
matters and should be stated accurately, because both are visible in the UI at
once on the Listing Detail page:

- **`reviews[].rating`** — one reviewer's score for that stay (integer 1-5).
- **`avg_rating`** — the listing's own rating. **This is the field every filter,
  sort, badge, and the recommendation heuristic uses.** The saved
  `min_rating` preference compares against this, never against individual
  review ratings.

If the seed is ever expanded to multiple reviews per listing, recompute
`avg_rating` from them so the claim becomes true, rather than restoring the
claim to the docs.

```jsonc
{
  "_id": "ObjectId(...)",
  "neighborhood_id": 1,
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
  "neighborhood_ids": [10, 19],
  "popularity_score": 82
}
```

### `weather_snapshots` — Weather Context feature

One document per observation. Deliberately not normalized into "current" vs. "historical" collections — a demo app just appends and reads the latest by `observed_at`.

```jsonc
{
  "_id": "ObjectId(...)",
  "city": "Washington",
  "neighborhood_id": 1,
  "observed_at": "2026-08-20T09:00:00Z",
  "temp_f": 64,
  "conditions": "Fog, clearing by noon",
  "weather_score": 7.2
}
```

### `venues` — bars, lounges, live music, comedy, breweries, rooftops (Entertainment feature)

Paired with Oracle's `theaters` table on the same page, and the clearest
justification for MongoDB in the whole application. Every venue shares a small
common core — `name`, `neighborhood_id`, `venue_type`, `description` — and then
carries only the attributes that make sense for its own type:

| venue_type | Type-specific fields it actually carries |
|---|---|
| `bar` | `happy_hour`, `food_served`, `outdoor_seating`, sometimes `games`, `cash_only`, `quiz_night` |
| `live_music` | `cover_charge`, `music_genres[]`, `live_nights[]`, sometimes `capacity`, `seated_show`, `all_ages_shows` |
| `comedy` | `cover_charge`, `show_nights[]`, `minimum_purchase`, `age_policy`, `open_mic` |
| `brewery` | `on_site_brewing`, `taps_count`, `tours_offered` |
| `rooftop` | `view`, `seasonal`, `heated` |
| `lounge` | `cover_charge`, `dress_code`, sometimes `specialty` |

Relationally this is the classic bad choice between a wide sparse table of
mostly-`NULL` columns and an entity-attribute-value side table. Here each
document simply holds the fields it needs. Contrast with `theaters`, which
stays in Oracle precisely because every cinema *does* have the same three
attributes — that contrast on one page is the point.

```jsonc
{
  "_id": "ObjectId(...)",
  "neighborhood_id": 4,
  "name": "Madam's Organ",
  "venue_type": "live_music",
  "description": "Four floors of blues, a rooftop deck, and a mural you can see from blocks away.",
  "cover_charge": 10,
  "music_genres": ["blues", "soul", "bluegrass"],
  "live_nights": ["Wed", "Thu", "Fri", "Sat"]
}
```

**Deliberately not evenly distributed.** Venues are weighted toward D.C.'s real
nightlife corridors (Adams Morgan, U Street/Shaw, H Street, Dupont, The Wharf)
rather than spread one-per-neighborhood. Filtering by neighborhood therefore
produces realistic variation — several venues in some, none in others. That is
honest seed data, not a gap to be filled.

## Indexes (`indexes.js`)

Every field a page filters or sorts on is indexed, matching the same discipline as the Oracle FK-index rule:

- `listings`: `neighborhood_id` (join to Oracle neighborhood, used on every Stay list/detail query), `avg_rating` descending (list-page default sort), `amenities` (multikey, for amenity filtering in "Recommend for me").
- `mflix_movies`: `neighborhood_ids` (multikey — "movies playing near this neighborhood"), `popularity_score` descending (Entertainment page default sort).
- `weather_snapshots`: compound `{ neighborhood_id: 1, observed_at: -1 }` — the actual query shape used everywhere ("latest snapshot for this neighborhood"); also `{ city: 1, observed_at: -1 }` for the Dashboard's city-level current-weather tile.
- `venues`: `neighborhood_id` (the Entertainment page's only required filter), `venue_type` (optional type narrowing), and the compound `{ neighborhood_id: 1, venue_type: 1 }` for "bars in this neighborhood". Note that the type-specific fields (`music_genres`, `taps_count`, and so on) are deliberately **not** indexed — nothing queries them, they are display-only, and indexing fields that exist on a minority of documents earns nothing.

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
| `GET /api/venues?neighborhood_id=&type=` | `venues.find({neighborhood_id, venue_type})` sorted by `venue_type`, `name` — both filters optional |
| `GET /api/venues/types` | `venues.distinct('venue_type')` — populates a type filter without hardcoding the vocabulary |
| `POST /api/admin/reload` | drops and reseeds all four collections from `seed_data.js` (Admin/Seed page only) |

Each is registered in APEX Shared Components → REST Data Sources, one per endpoint, exactly matching the region that consumes it (see `ords/rest_modules.sql` for the equivalent Oracle-side pattern, and `apex/page_plan.md` for which page uses which).
