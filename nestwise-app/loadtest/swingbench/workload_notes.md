# NestWise — Load testing (Swingbench + hybrid)

> **See also: `loadtest/k6/` — the path actually taken.** Swingbench cannot drive
> NestWise's own SQL without Java or PL/SQL transaction classes (see the
> correction below). k6 driving the **ORDS REST layer** produces the same
> database workload with no custom code, because those handlers call the same
> PL/SQL packages the APEX pages call. `loadtest/k6/nestwise_ords.js` implements
> the exact transaction mix specified in this file. Swingbench's bundled SOE
> benchmark remains useful as a cluster-ceiling reference, and this file's
> "what to measure" and index sections apply to either generator.

## Which of the three realistic paths, and why

Swingbench ships **prebuilt benchmarks with matching data generators** (SOE, SH, Calling Circle) — it is not a wizard that inspects an arbitrary schema like NestWise's and auto-generates matching transactions. Producing load numbers tied to NestWise's actual hot paths therefore means authoring a custom benchmark, and since the entire point of this app is to validate the RAC cluster with a real, app-specific workload (not a generic one), that's the direction this deliverable points. A generic OLTP number ("SOE does N tps") wouldn't say anything about whether *NestWise's* filter queries or the recommendation heuristic are the RAC-load bottleneck — and that's the number worth having.

> **Correction (added after actually reading Swingbench's docs and distribution):** an earlier version of this section said the custom path was "a custom Swingbench XML (`sample_config.xml`) with `Transaction` elements wrapping NestWise's actual queries." **That is wrong and would not run.** Swingbench's XML configures connections, user counts, think time, and *which transaction classes to run* — it cannot contain SQL. Custom transactions are either **Java classes** extending `JdbcTaskImpl` (source and an `ant` build script ship in `$SWINGHOME/source`) or a rewrite of the **PL/SQL stored procedure** behind Swingbench's shipped "blank" benchmark. The transaction table below is still the right specification of *what* to implement — it just describes Java/PL/SQL to be written, not XML. Concrete, verified setup and run instructions for all three paths (quick RAC check, bundled SOE, custom benchmark) are in [`README-swingbench.md`](README-swingbench.md).

As a fast sanity check *before* investing time in the custom XML, it is still worth running the bundled **SOE** benchmark once against a separate schema on the same RAC service, purely to characterize the cluster's general OLTP ceiling (baseline tps, interconnect behavior) independent of NestWise's schema. Treat that number as a ceiling reference, not a NestWise result — it's noted here so nobody mistakes it for one.

## What to measure

- Transactions/min per transaction type (see below).
- Average and p95 response time per transaction type.
- Error rate.
- `GV$SESSION` / AWR wait events during the run, specifically watching for unindexed-FK-scan symptoms (`db file scattered read` spikes on `restaurants`/`theaters`/`user_favorites`) and `log file sync` waits (RAC interconnect/redo pressure under concurrent writes from the favorite-toggle and admin-reload transactions).
- Session distribution across `gv$session` by `inst_id` — confirming both RAC nodes are actually taking load, not just one (see `docs/install.md` step 9).

## Custom Swingbench transactions (mapped to NestWise's actual hot paths)

Each of these becomes a `<Transaction>` block in `sample_config.xml`, backed by the exact SQL NestWise runs (via the PL/SQL packages in `db/oracle/03_packages.sql`):

| Transaction | Weight | Backing SQL |
|---|---|---|
| `BrowseNeighborhoods` | 25% | `nbhd_pkg.list_neighborhoods(:city, NULL)` — the Neighborhood Explorer IR, no search term (default landing state) |
| `SearchNeighborhoods` | 10% | `nbhd_pkg.list_neighborhoods(:city, :search_term)` — with a random 3-6 char substring from seeded neighborhood names |
| `FilterRestaurants` | 25% | `restaurant_pkg.search(p_cuisine => :cuisine, p_price_range => :price_range, p_min_rating => :min_rating)` — Restaurant Finder's dominant query, params drawn randomly from the seeded cuisine/price/rating domains |
| `ToggleFavorite` | 15% | `nbhd_pkg.toggle_favorite(:app_user, :neighborhood_id)` — write transaction, exercises the `user_favorites` MERGE/DELETE and RAC redo/interconnect behavior |
| `RecommendRestaurants` | 15% | `restaurant_pkg.recommend_for_user(:app_user)` — the heaviest read (full-table scored sort), worth isolating from `FilterRestaurants` since its plan is different |
| `GetNeighborhoodStats` | 10% | `nbhd_pkg.get_stats(:neighborhood_id)` — the Neighborhood Detail page's Oracle half, run alongside the Mongo-side load below to approximate the real hybrid detail-page hit |

`:app_user` values should be drawn from a small pool (10-20 synthetic usernames pre-inserted into `user_preferences`) so `ToggleFavorite` and `RecommendRestaurants` see realistic per-user state rather than hammering a single row.

## Sample config idea (`sample_config.xml`)

- **Users**: start at 10, step to 25, 50, 100 — a demo-scale schema (8 neighborhoods, ~20 restaurants) will plateau well before production numbers; the point is showing where the knee in the curve appears, not chasing a big absolute number.
- **Think time**: 0.5-2s between transactions (uniform random), to approximate real user pacing rather than a pure firehose — a firehose against an 8-neighborhood schema mostly just measures connection-pool contention, not query performance.
- **Duration**: 5-10 minutes steady-state per user-count step, after a short (~1 min) ramp-up excluded from the percentile calculation.
- **Connect string**: the RAC SCAN listener, exactly as the app connects — this is what makes the run representative of the real app's RAC behavior, not a single-instance shortcut.

## Hybrid portion: simulating concurrent load against MongoDB-backed pages too

Swingbench only drives Oracle. To make "hybrid under load" a real comparison rather than an Oracle-only story, run a concurrent script against the proxy's endpoints at the *same* concurrency step as the Swingbench run:

```bash
# simple example using `autocannon` (npm i -g autocannon), 50 concurrent, 5 min
autocannon -c 50 -d 300 "http://<app-server>:4000/api/listings?neighborhood_id=1" &
autocannon -c 50 -d 300 "http://<app-server>:4000/api/movies/popular?neighborhood_id=1" &
autocannon -c 50 -d 300 "http://<app-server>:4000/api/weather/current?city=San%20Francisco" &
wait
```

Or, with nothing but `curl` and a shell loop if `autocannon`/`k6` aren't available:

```bash
for i in $(seq 1 50); do
  ( while true; do curl -s -o /dev/null "http://<app-server>:4000/api/listings?neighborhood_id=$((RANDOM % 8 + 1))"; sleep 1; done ) &
done
sleep 300
kill $(jobs -p)
```

Measure the same shape of numbers (response time avg/p95, error rate) so the write-up is one combined table, not two disconnected reports — see `results.md` (create alongside this file after a real run) for the format.

## Index recommendations (specific to NestWise's actual query patterns)

**Oracle** (already applied in `db/oracle/02_constraints_indexes.sql`, restated here with the transaction each one targets):

- `ix_restaurants_neighborhood`, `ix_theaters_neighborhood`, `ix_user_favorites_nbhd` — every FK, mandatory; without these, `ToggleFavorite` and `GetNeighborhoodStats`'s joins degrade to full scans under concurrent load.
- `ix_restaurants_nbhd_cuisine (neighborhood_id, cuisine)` — matches `GetNeighborhoodStats`'s implicit filter pattern when the detail page also shows cuisine-filtered restaurants.
- `ix_restaurants_reco (cuisine, price_range, rating DESC)` — matches `FilterRestaurants`'s and `RecommendRestaurants`'s combined predicate/sort; verify with `EXPLAIN PLAN` on the exact bound SQL from `restaurant_pkg.search` and `.recommend_for_user` once the Swingbench XML is running, not just by intuition, per the reference's guidance.
- `ix_neighborhoods_name` — supports `SearchNeighborhoods`'s `UPPER(name) LIKE` predicate; note this is a plain B-tree, not a text index, so it helps prefix/substring searches on an 8-row seed set but would need a different approach (e.g. Oracle Text) if the neighborhood count grew into the thousands — not a concern at this app's intended scale.

**MongoDB** (already applied in `db/mongodb/indexes.js`):

- `listings.{neighborhood_id:1, avg_rating:-1}` — matches the proxy's `/api/listings?neighborhood_id=` query pattern (filter + sort in one index) hit by both the Stay/Listings browse page and the Neighborhood Detail page's Mongo region, run concurrently with `GetNeighborhoodStats` above.
- `weather_snapshots.{neighborhood_id:1, observed_at:-1}` and `{city:1, observed_at:-1}` — match the proxy's two "latest snapshot" aggregation entry points (`/api/weather/neighborhood/:id`, `/api/weather/current`) exactly; without the compound index, the `$sort` stage in the aggregation pipeline falls back to an in-memory sort per group.
- `mflix_movies.{neighborhood_ids:1}` (multikey) — matches `/api/movies/popular?neighborhood_id=`; verify with `.explain("executionStats")` that it's actually used (multikey indexes on array fields sometimes surprise people coming from Oracle's simpler index model).

## Write-up

After a real run, record results as a table (transaction/endpoint × avg response time × p95 × throughput) at 10/50/100 concurrent users in a `loadtest/swingbench/results.md`, with one sentence on where the knee appeared and which index change (if any) moved it. This belongs with the technical deliverables, not the demo script — load-test numbers are a detail for the Oracle-developer audience reading the docs, not part of the live click-through (see `docs/demo-script.md`).
