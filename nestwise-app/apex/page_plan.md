# NestWise — APEX application structure (page plan)

## Build progress (updated as pages are actually built, not just planned)

**Page 1 (Home / Dashboard) — Oracle-backed portion done and confirmed against real data.**
Built as three separate regions rather than one combined 4-tile row, since the two
Mongo-backed tiles (Listings, Current Weather) are deferred to Task #3 (REST Data
Sources not yet registered):

- **Neighborhoods** — Metric Card region (not the generic "Cards" type originally
  planned; Metric Card is APEX's purpose-built single-KPI region and maps more
  directly to a tile than a repeating Cards region does). SQL:
  `SELECT COUNT(*) AS value, 'Neighborhoods' AS label FROM neighborhoods WHERE city = admin_pkg.get_current_city`.
  Confirmed rendering `28`, matching the `admin/dashboard-counts` REST endpoint.
- **Restaurants** — same Metric Card pattern, joined through `neighborhoods` since
  `restaurants` has no `city` column of its own:
  `SELECT COUNT(*) AS value, 'Restaurants' AS label FROM restaurants r WHERE r.neighborhood_id IN (SELECT neighborhood_id FROM neighborhoods WHERE city = admin_pkg.get_current_city)`.
  Confirmed rendering `87`, matching the REST endpoint.
- **Avg rating by neighborhood** — Chart region (Bar). One real gotcha worth noting
  for the next page built this way: **the SQL Query and Column Mapping (Label/Value)
  belong on the Series child node, not on the region's own Source panel** — despite
  the region-level Source panel also showing a SQL Query field, that field is not
  what the Series reads from for this region type. Confirmed rendering real,
  differentiated bars across all 28 neighborhoods (4-5 range).
- Listings and Current Weather tiles: **not yet built** — blocked on Task #3.

Login note: running the app for the first time redirects to the app's own sign-in
page (Page 9999) — expected behavior for the `Application Express Accounts` auth
scheme, not an error. The workspace admin account (`nestwise_admin`) can log
directly into the app; a dedicated lower-privilege test user (`nestwise_test`) was
also created via Administration → Manage Users and Groups for ongoing testing.

**Page 2 (Neighborhood Explorer) — built (Page 4 in the app) and confirmed against real data.**
Built as designed below, with one further real deviation worth documenting: the
favorite toggle does **not** use a Dynamic Action bound to the IR column, because
Interactive Reports don't support the "Column(s)" Dynamic Action Selection Type at
all — that option only exists for Interactive Grid regions (confirmed by an empty,
unpopulated region dropdown when attempted). Working pattern used instead, fully
declarative, no custom JavaScript: `IS_FAVORITED` column set to **Link** type
(Target: this page, Set Items: a new hidden item `P4_TOGGLE_ID` = `#NEIGHBORHOOD_ID#`),
paired with a **Before Header** page process (PL/SQL, Server-side Condition "Item is
NOT NULL" on `P4_TOGGLE_ID`) calling `nbhd_pkg.toggle_favorite(:APP_USER, :P4_TOGGLE_ID)`.
Confirmed working across multiple rows independently (each click reloads the page and
flips only that row's `Y`/`N`, unclicked rows unaffected). The search box similarly
required `Page Items to Submit` = `P2_SEARCH` on the IR region — a page item's typed
value isn't visible to a region's bind variables on AJAX refresh unless explicitly
listed there.

Original design notes (superseded above where they conflict):
Original plan called for the IR to source directly from `nbhd_pkg.list_neighborhoods`.
That won't work as written: the function returns a `SYS_REFCURSOR`, and an
Interactive Report's SQL Query source needs a real SQL string, not a REF CURSOR
function — the same class of bug already hit once in `ords/rest_modules.sql`
(see that file's header comment). Fix, applied up front this time instead of
discovered by trial: inline the equivalent SQL directly in the IR region, using
`:G_CURRENT_CITY` and a new page item `:P2_SEARCH` as binds, and call
`nbhd_pkg.is_favorited(:APP_USER, n.neighborhood_id)` per row (SQL-callable
because it's declared in the package spec, not body-private — same reasoning as
`restaurant_pkg.price_rank`). Listings-count column deferred with the rest of the
Mongo-backed content until Task #3.

**Page 3 (Neighborhood Detail) — built (Page 6 in the app) and confirmed against real data.**
Same REF CURSOR discipline as Page 2, applied up front: `nbhd_pkg.get_stats`,
`restaurant_pkg.search`, and `theater_pkg.list_by_neighborhood` all return
`SYS_REFCURSOR`, so Region A's three sub-regions (Stats, Restaurants here,
Theaters here) all inline equivalent plain SQL rather than calling the package
functions, filtered on page item `P6_NEIGHBORHOOD_ID` (the page number APEX
actually assigned — a stray `P5_...` placeholder in an early draft of this SQL
had to be corrected before running, caught before execution). Reached via a
Link column on Page 4's `NAME` (Target: Page in this Application, Page 6, Set
Items: `P6_NEIGHBORHOOD_ID` = `#NEIGHBORHOOD_ID#`) — same declarative
Link-column + page-item pattern as the favorite toggle, no custom JavaScript.
Confirmed end to end: clicking "Barracks Row" on Page 4 loads Page 6 with
`neighborhood_id = 35`, matching stats (4.3 avg rating, 3 restaurants, 1
theater) and the actual "Miracle Theatre" row.

**Region B (Stay & Weather Here, Mongo-backed) — built and confirmed against
real data, resolving a genuine cross-database structural bug along the way.**
Both regions use native REST Data Source region binding (Location: REST
Source) rather than `APEX_EXEC` — the right choice for list/tile-shaped
display regions, reserving `APEX_EXEC` for cases like Page 1's single
aggregate value. Stay Here is a **Cards** region (not Metric Card — the
original placeholder assumption), correctly showing every listing for the
neighborhood rather than a single-value summary. Weather Here renders as two
small Metric-Card-style tiles (temp + conditions from the two most recent
observations), sourced from `RDS_WEATHER_NEIGHBORHOOD`.

Two real, non-obvious REST Data Source bugs had to be diagnosed and fixed
before either region worked, worth flagging for any future REST-Source-backed
region on this project:

1. **A Data Source-level Parameter is not enough — it must also be attached
   as an Operation Parameter on the specific Operation that should use it.**
   `RDS_LISTINGS`'s `neighborhood_id` parameter existed and was correctly
   typed (`URL Query String`) at the Data Source level, and the region's own
   Parameters node correctly mapped it to `P6_NEIGHBORHOOD_ID` — yet the
   region still returned all 56 listings unfiltered. Root cause: the GET
   Operation's own **Operation Parameters** list was empty ("No Parameters
   defined"), so the value never made it into the outgoing request. Fixed by
   adding the parameter again at the Operation level (Operations tab → GET →
   Operation Parameters → Add Parameter), confirmed via **Test Operation**
   with a Static default value before removing the default and relying on
   the real page item.
2. **Test Operation needs a Default Value to test anything meaningful** —
   with `Default Value Type: None`, Test Operation calls the endpoint with no
   parameter at all, which can look identical to "filtering doesn't work"
   even when the wiring is correct. Setting a temporary Static default (then
   removing it once confirmed) is the reliable way to test.

**The bigger finding: a real, structural Oracle/MongoDB `neighborhood_id`
mismatch, confirmed and fixed.** Oracle's `neighborhood_id` IDENTITY values
had drifted from the original 1-28 seed range (via repeated
`admin_pkg.reload_oracle_seed_data` calls during earlier install/
troubleshooting — a caveat `db/mongodb/schema_notes.md` had documented as a
theoretical risk but never confirmed as live). MongoDB's `listings`,
`weather_snapshots`, and `mflix_movies` collections still used the original
1-28 numbering. Confirmed via `SELECT neighborhood_id, name FROM
neighborhoods ORDER BY neighborhood_id` against the live schema: every row
had shifted by a **uniform +8 offset** (Georgetown 1→9, Barracks Row 27→35,
West End 28→36). Notably, an early test against Georgetown's current ID (9)
*appeared* to work — Mongo returned non-empty data — but that data actually
belonged to the original ID 9 (Foggy Bottom), silently mislabeled as
Georgetown's. A same-city name collision made the wrong data look plausible,
which is a worse failure mode than Barracks Row's honest "No data found."
Fixed with `db/mongodb/remap_neighborhood_ids.js`, a one-time idempotent
script that shifts all three collections' `neighborhood_id` (and
`mflix_movies`' `neighborhood_ids` array) by +8. Run for real against the
lab's live MongoDB server and confirmed: 56 listings, 56 weather snapshots,
and 13 movies remapped; both Barracks Row and Georgetown then verified to
show correct, name-matched data (Georgetown: "Canal-View Rowhouse Suite,"
"M Street Boutique Loft" — M Street being Georgetown's actual main
commercial street).

A "Back to Neighborhood Explorer" button was also added to Page 6 (a
region-less button isn't possible in APEX — buttons always require a parent
region — so it lives in a Static Content region with its Title cleared and
Template set to render no visible chrome, giving the appearance of a
free-floating button).

**Restaurant Finder (plan pages 4-5, combined into one physical page) — built (Page 7) and confirmed against real data.**
`restaurant_pkg.search`, `restaurant_pkg.recommend_for_user`, and
`restaurant_pkg.list_cuisines` all return `SYS_REFCURSOR` — same inlining
discipline as every prior page. Two regions on one page rather than a
separate page for "Recommend for me," matching the original plan's framing of
it as "sub-tab or button toggle on page 4." The recommend region avoids the
original `NO_DATA_FOUND` exception-handling branch by using `LEFT JOIN
user_preferences ... NVL(...)` instead — the same fix already proven in
`ords/rest_modules.sql`'s `restaurants/recommend/:app_user` handler, applied
here up front rather than discovered by trial.

Real bugs hit and fixed during this build, both the same class of error —
a literal `P#_` placeholder (from copy-pasted guidance text) surviving into
production instead of being replaced with the actual page number (7): once
in a Dynamic Action's own "When → Item(s)" trigger config (`PRICE_REFRESH`),
and once as a stray leftover bind inside the Search Results SQL Query itself.
The second one produced a real, reproducible browser error
(`ERR-1002 Unable to find item ID for item "P#_..." in application "100"`),
caught via the browser's JavaScript console plus APEX's own Debug view
(Session tab), not guessed at — this project's standing discipline. Confirmed
fully resolved: filters tested individually and in combination (cuisine +
price + rating together) all return correct, real result sets with no
console errors.

Map alternate view deferred as a follow-up polish step, not required for
this page to be considered functionally complete.

**User Profile — built (Page 8) and confirmed against real data.** The only remaining fully
Oracle-only page (Stay/Listings ×3 and Entertainment are Mongo-touching,
Weather Context is Mongo-only, Admin/Seed Data has a Mongo-reload button) —
picked next for that reason. `prefs_pkg.get_preferences` also returns a
`SYS_REFCURSOR`, but this page avoids that class of bug structurally rather
than inlining a workaround: page items are populated by a Before Header
PL/SQL process doing a plain `SELECT ... INTO`, not by a SQL-Query-sourced
region. `save_preferences` is a procedure (not a function), so the save side
never touches a REF CURSOR at all. Once saved, this page is what makes
Restaurant Finder's "Recommended for Me" region actually personalized instead
of always falling back to `NVL(..., '$$')`.

Real bugs hit and fixed: (1) a duplicate-name mixup — one item ended up named
`P8_BUDGET` twice and no `P8_CUISINE` existed at all, from renaming an item
mid-build instead of creating a fresh one; caught via the error badge and
fixed by renaming the SQL-Query-LOV item back to `P8_CUISINE`. (2) The
`Save Preferences` button's **Button Name** (the internal identifier) cannot
contain spaces — only **Label** can; the button was initially named
`Save Preferences` (invalid) instead of `SAVE_PREFERENCES`. (3) APEX's
page-level **Warn on Unsaved Changes** setting fired a browser "Leave site?"
confirmation on every Save click, even though Submit is not an accidental
navigation — turned off via the page's own Navigation attributes. Confirmed
fully working via the strongest evidence yet used on this project: signing
`nestwise_test` fully out and back in and finding the saved preferences still
present, proving real server-side persistence, not session caching.

**Stay / Listings browse (plan page 6) — built (Page 2) and confirmed against real data.**
The fastest page built on this project so far, because `RDS_LISTINGS` had
already been fully debugged during Page 6's Region B work — a single Cards
region plus a neighborhood Select List (LOV from Oracle `neighborhoods`, with
a `- All neighborhoods -` null option) and one Dynamic Action refresh.
Confirmed: 56 cards on load, narrowing to exactly 2 for Georgetown and 2 for
Barracks Row.

Three deliberate scope cuts from this file's original spec for the page, named
rather than silently dropped:

1. **No amenities badges.** `AMENITIES` is an `Array` column and Cards regions
   render scalar columns. Rendering it would need custom HTML or a nested-rows
   sub-region — both violate this app's native-components-only rule for a
   cosmetic gain.
2. **No per-card neighborhood name.** The original spec called for a
   client-side lookup from a hidden Oracle LOV cached in a page item. When the
   filter is set, the Select List already shows the name; the mechanism isn't
   worth its own moving part.
3. **Not a "hybrid story" page.** The LOV is Oracle and the cards are Mongo,
   but they don't visibly sit side by side. Page 6 carries that narrative;
   this one is a straightforward browse.

**Listing Detail (plan page 7) — built (Page 3) and confirmed against real data.**
This page changed shape during the build, for a real and documented reason.

**Finding: APEX 26.1 picks the nested array as the row source for a
single-object JSON response.** The plan assumed `RDS_LISTING_DETAIL` would
return the listing document with `reviews` as an accessible nested array, using
the Array Column feature Oracle introduced in APEX 24.1 (Data Profile marks the
array, region picks it via **Data Profile → Array Column**, APEX generates
`JSON_TABLE ... NESTED PATH` underneath). That feature is real and works — but
it applies to responses shaped like `{items: [...]}`, where the outer structure
is already a rowset. `GET /api/listings/:id` returns a single object containing
one array, and discovery selects **Row Selector = `reviews`** on its own,
because that array is the only thing yielding multiple rows. This was confirmed
twice: once on the original Data Source, and again on a completely fresh one
created from scratch through the wizard — so it is deliberate APEX behavior,
not a corrupted profile.

**Resulting design, simpler than planned:** the Data Source *is* "the reviews
for one listing." Region B (Reviews, Classic Report) binds to it directly.
Region A (Listing) uses **Display Only page items populated by the card click**
— no REST call at all. One HTTP request serves the whole page. Stated
trade-off: a bookmarked detail URL shows reviews but blank header fields,
because the header data rides in on the link rather than being re-fetched.
Acceptable for a showcase; the fix, if ever wanted, is a second Data Source on
the same endpoint with Row Selector forced to `.`.

The page also carries a **"View Neighborhood"** button passing the listing's
`NEIGHBORHOOD_ID` to Page 6 — a MongoDB document handing off to an
Oracle-backed page, and a cheap addition worth pointing at during the demo.

Real bugs hit and fixed, all in the REST Data Source rather than the page:

1. **`:id` declared twice.** `URL Path Prefix` was `/api/listings/:id` *and*
   `URL Pattern` was `.:id`, producing a malformed URL and a proxy
   `400 {"error":"invalid listing id"}`. Rediscovery then faithfully profiled
   that *error response*, leaving a single `ERROR` column — a reminder that
   Rediscovery profiles whatever comes back, including failures.
2. **APEX does not insert a separator between URL Path Prefix and URL
   Pattern.** With prefix `/api/listings` and pattern `:id` the request went to
   `/api/listings6a8d...` (404). The pattern needs its own leading slash:
   `/:id`.
3. **Stale ObjectIds after a seed reload.** The `_id` used for discovery
   returned `404 {"error":"listing not found"}` because the MongoDB reseed run
   during the §8 smoke test regenerated every `_id`. Distinct from the
   `neighborhood_id` drift already documented in `db/mongodb/schema_notes.md` —
   different field, same lesson: **any hardcoded Mongo `_id` in config or docs
   has a short shelf life.** Runtime is unaffected (the page receives its id
   from whichever card was clicked), but discovery/test values need refreshing
   after every reseed. Current ids are easiest to obtain from `RDS_LISTINGS` →
   Test Operation, without leaving APEX.
4. **A Static default value masked a real failure.** A static `id` default was
   added so discovery had something to fetch, then left in place. When the
   parameterization step was subsequently missed, every listing silently showed
   *Capitol Dome View Studio's* review instead of failing visibly — the same
   confidently-wrong failure mode as the Georgetown/Foggy Bottom ID mismatch.
   Static defaults on REST parameters are useful during discovery and should be
   removed immediately afterward.
5. **The parameterization step was skipped entirely and the symptoms looked
   like a mapping bug.** The tell was on the Operation screen, not the page:
   `REST Source Base URL` still ended in a hardcoded ObjectId, `URL Pattern`
   was `.`, and Operation Parameters read "No Parameters defined." Worth
   checking those three fields first whenever a REST-backed region returns the
   same row regardless of input.

**Standing gotcha for every filter-bearing page on this app:** APEX's
page-level **Warn on Unsaved Changes** fires a browser "Leave site?" prompt when
navigating away from a page whose items have changed — including pages where
the items are *filters*, not data entry (Stay / Listings, Restaurant Finder,
Neighborhood Explorer). Turn it off in the page's Navigation attributes on any
read-only browse page. Already noted on User Profile above; recording it here
as a recurring pattern, not a one-off.

**Admin / Seed Data (plan page 12) — built (Page 5) and confirmed against real data.**
Building this page required fixing a schema problem first, because the page's
entire purpose — "reset state between demo runs" — was the thing *causing* the
worst bug in the app.

**The schema fix (`db/oracle/04_neighborhood_id_stability.sql`).**
`neighborhoods.neighborhood_id` was `NUMBER GENERATED ALWAYS AS IDENTITY`, and
`reload_oracle_seed_data` does `DELETE` + `INSERT`. `DELETE` does not reset an
identity sequence, so every reload produced a fresh higher range (1-28 → 9-36 →
…) while MongoDB's collections kept their own numbering. A two-button Admin
page built as originally specced would have recreated the cross-database
mismatch on every demo reset — the exact failure this session spent hours
diagnosing. Rather than compensate for the drift (a "re-sync IDs" button, or
remembering to run `remap_neighborhood_ids.js` after each reload), the key was
made deterministic at the source: the identity was dropped
(`ALTER TABLE neighborhoods MODIFY (neighborhood_id DROP IDENTITY)` — documented
12c+ syntax, and one-way) and the 28 seed `INSERT`s now supply IDs 1-28
explicitly, matching `db/mongodb/schema_notes.md`'s table. Nothing in the app
inserts a neighborhood at runtime, so a generated key bought nothing and cost
cross-database integrity.

`restaurants` and `theaters` needed no changes at all — they already resolve
`neighborhood_id` by name lookup (`SELECT neighborhood_id FROM neighborhoods
WHERE name = 'Georgetown'`), so they stay correct regardless of what the IDs
are. That existing choice is what kept the fix to one table.

Verified live: range went `9-36` → `1-28`, Georgetown = 1, Barracks Row = 27.
`remap_neighborhood_ids.js` is retired — kept only as a record of the original
fix. **Reload is now idempotent**, which is the property the page needed to be
worth building.

**The page.** Status region is a Classic Report (Value Attribute Pairs –
Column) inlining plain SQL rather than calling `admin_pkg.get_dashboard_counts`
— same `SYS_REFCURSOR` discipline as every prior page — and deliberately
displays **min/max neighborhood_id alongside the counts**, so the stability
property is visible on screen rather than assumed. Two buttons, both with
Requires Confirmation on. Oracle reload calls the package directly; MongoDB
reload uses `APEX_WEB_SERVICE.MAKE_REST_REQUEST` against the proxy's
`/api/admin/reload`.

Real findings during this build:

1. **Web Credentials are workspace-level, not application-level** — they live
   under **Workspace Utilities**, not Shared Components. Type `HTTP Header`
   with Credential Name `X-Nestwise-Admin-Token` is the right shape for this
   proxy's shared-secret guard, keeping the token out of the process source.
2. **The credential's Static ID is auto-derived as lowercase-hyphenated**
   (`nestwise-admin-token`, not `NESTWISE_ADMIN_TOKEN`) — the same trap as REST
   Data Source Static IDs (`rds-listings`). `p_credential_static_id` needs the
   real value.
3. **`MAKE_REST_REQUEST` does not raise on a non-200.** Without an explicit
   `apex_web_service.g_status_code` check the process would report success on a
   failed reload — the same silently-wrong failure mode as the stale REST
   parameter default and the Georgetown/Foggy Bottom ID collision. The check
   proved itself immediately by catching a real `HTTP 401
   {"error":"unauthorized"}`.
4. **That 401's root cause is unconfirmed.** Two changes were made together —
   clearing the credential's **"Valid for URLs"** field and re-entering the
   Credential Secret (APEX requires re-entering the secret whenever that field
   changes) — and the next attempt succeeded. Anyone reproducing this should
   try both. The plausible mechanism is that a URL-scope mismatch makes APEX
   omit the credential silently rather than error, producing a 401 that looks
   like a bad token.
5. **Page authorization and navigation visibility are separate settings.** The
   `Admin Only` authorization scheme (PL/SQL returning
   `UPPER(:APP_USER) = 'NESTWISE_ADMIN'`) on the page correctly blocks access,
   but the navigation menu is its own Shared Component and kept rendering the
   link for `nestwise_test` — clicking it produced the access-denied error
   rather than hiding the page. The entry needs the same scheme applied under
   **Navigation Menu**. Both are kept: hiding the link is UX, the page-level
   check is the actual boundary against someone typing the URL. Confirmed by
   signing in as `nestwise_test` and finding the entry gone.

**Entertainment (plan page 9) — built (Page 9) and confirmed against real data.**
The second page that renders both databases together, and the cleanest example
of the pattern now that the plumbing is proven: Oracle theaters (Classic
Report, inlined SQL rather than `theater_pkg.list_by_neighborhood`, which
returns `SYS_REFCURSOR`) beside MongoDB popular movies (Cards on
`RDS_MOVIES_POPULAR`), both at Column Span 6, both refreshed by a **single
Dynamic Action carrying two Refresh true actions**. Confirmed with Penn
Quarter / Chinatown: four theaters (E Street Cinema, National, Regal Gallery
Place, Warner) next to four movies sorted by popularity (94, 89, 88, 82).

Same Array-column scope cut as listings and reviews: `GENRES` and `CAST` are
Array columns, so the cards show title / year / popularity badge and leave the
arrays unrendered.

Two findings:

1. **`RDS_MOVIES_POPULAR`'s Data Profile was stale — the third occurrence of
   this bug**, after both weather sources. Test Operation returned real movie
   titles under *listings* column headings (`AVG_RATING`, `CREATED_AT`), because
   the profile had never been rediscovered against this endpoint. Left
   unfixed, the Cards region would have had no `POPULARITY_SCORE` column to
   bind a badge to. **Any REST Data Source registered but never used should be
   assumed to have a wrong profile until Rediscovery proves otherwise.** Its
   parameter, by contrast, was already correctly configured (`URL Query
   String`, `neighborhood_id`, `Omit when value is empty` on) — the attempt to
   add a duplicate failed with "Static ID must be unique," which is a useful
   tell that a parameter already exists.
2. **A literal `PX_` placeholder reached production SQL — the second instance
   of this class of bug**, after `P#_MIN_RATING` on Restaurant Finder. The
   theaters query shipped with `WHERE neighborhood_id = :PX_NEIGHBORHOOD_ID`,
   producing an empty region and an `ERR-1002`-style error badge in the
   developer toolbar. Diagnosed by checking the seed data first and
   establishing that Penn Quarter genuinely *has* four theaters, so "empty" had
   to be a bug rather than honest data — worth doing before debugging
   configuration. Both instances originated from placeholder notation in
   written build instructions being pasted verbatim; the fix is to write the
   real page number once it is known.

**Listings Recommend (plan page 8) — built as a second region on Stay / Listings
(Page 2) and confirmed against real data.** Not a separate page: the plan
described it as "a sub-tab or button on page 6," and Restaurant Finder already
set the precedent of combining plan pages 4+5 into one physical page. One less
page to navigate, consistent with the app.

`prefs_pkg.get_preferences` returns `SYS_REFCURSOR`, so — as on User Profile —
it is avoided structurally rather than worked around: a Before Header process
does a plain `SELECT ... INTO` two hidden items (`P2_BUDGET`, `P2_WEATHER`),
with a `NO_DATA_FOUND` branch defaulting to `$$`/`any` so a user who has never
saved preferences doesn't error on page load. The REST Data Source's `budget`
and `weather` parameters bind to those items.

`RDS_LISTINGS_RECOMMEND` was the fourth never-exercised REST Data Source, and
notably the **first one whose Data Profile was already correct** — every column
matched, including the proxy-computed `RECOMMEND_SCORE`. The habit of checking
first still paid: verifying took a minute, and the previous three were all
wrong.

**Verified by arithmetic, not by eyeballing.** The region always returns 10 rows
(the proxy does `.limit(10)`), so row count never changes and the region can
look inert. The proof is that the scores match the documented formula
(`avg_rating + 3 if price ≤ budget ceiling + 2 if weather band matches`) exactly:
at Budget = `$` (ceiling $120), Southeast DC Community Flat ($118, rating 3.9)
scored 6.9, and Wharf Pier View Condo ($260, rating 4.7) scored 4.7 — having
topped the list at 9.7 under `$$$$`. Ordering inverted completely. Worth
recording as a testing lesson: for a scored/ranked region, check the arithmetic
against a couple of known rows rather than judging by whether the list "looks
different."

One honest observation about the seed data: **no listing ever earns the weather
bonus at `weather = cold`**, because every DC snapshot in the seed sits in the
hot band. Correct behavior, but it makes half the heuristic invisible unless
the preference is set to `hot`.

Three UX fixes applied after first render, all real problems rather than polish:

1. **The recommendations were below the browse grid**, so the personalized
   content required scrolling past 56 cards. Fixed by lowering the region's
   Sequence.
2. **The neighborhood Select List sat loose at Body level**, which — once the
   recommend region moved to the top — made the filter appear to apply to the
   recommendations, which it does not (recommendations are city-wide by
   design). Fixed by moving the item inside the Browse All Listings region, so
   the filter visually belongs to the region it controls.
3. **Neither Cards region rendered a title** under the template originally
   applied, leaving two visually identical card grids stacked with different
   badge meanings (rating vs. score) and nothing distinguishing them — the same
   silent-title behavior seen on Neighborhood Detail's "Stay Here." Fixed via
   the region Template. Titles now read "Recommended for Me — across all
   neighborhoods" and "Browse All Listings," which does the explaining without
   extra text.

**Known cosmetic duplication, deliberately left alone.** Region Parameter nodes
appear twice (two `budget`, two `weather`, two `neighborhood_id`) because these
REST Data Sources define the parameter at both the Data Source level and the
Operation level. Only the **Operation-level** copy is functional — proven on
`RDS_LISTINGS`, where a source-level parameter alone produced an unfiltered
request until the operation-level one was added. Both copies are mapped to the
same page items, so the outgoing value is identical either way. Removing the
redundant source-level copies would be tidier but risks re-breaking pages that
currently work (three pages depend on `RDS_LISTINGS`), for no behavioral gain.
Recorded here so it reads as a decision rather than an oversight.

**Minimum Rating preference — added after the fact, end to end across all three
tiers.** Not in the original plan; added because User Profile had cuisine,
budget and weather but no rating, while Restaurant Finder already offered an
ad-hoc Min Rating filter. Applied as a **filter, not a scoring bonus** —
"minimum rating" means exactly that, and it matches the existing Restaurant
Finder control so the saved preference and the ad-hoc filter mean the same
thing.

What it touched:

- **Oracle** — `user_preferences.min_rating NUMBER(2,1) DEFAULT 0` with a
  `BETWEEN 0 AND 5` check; `prefs_pkg.get_preferences` returns it and
  `save_preferences` takes `p_min_rating` (defaulted, so existing callers still
  compile). Migration for existing schemas:
  `db/oracle/05_user_prefs_min_rating.sql`.
- **Proxy** — `/api/listings/recommend/for-user` accepts `?rating=` and applies
  it as a Mongo-side filter (`{ avg_rating: { $gte: minRating } }`) before
  scoring.
- **APEX** — `P8_MIN_RATING` Select List on User Profile, `P2_MIN_RATING` hidden
  item on Stay / Listings, a `rating` Operation Parameter on
  `RDS_LISTINGS_RECOMMEND`, and the region binding.

**The bug worth recording: a REST parameter's Name is case-sensitive.** The
parameter was created as **`Rating`**; the proxy reads `req.query.rating`. APEX
sent `?Rating=5`, Express saw nothing, the default of `0` applied, and no
filtering occurred — silently, with a full list of results that looked
plausible. Isolated in two commands by testing the proxy directly with `curl`
(`?rating=5` → `[]`, `?rating=4.5` → results), which proved the proxy correct
and confined the fault to APEX; the tree then showed `Rating` sitting between
lowercase `budget` and `weather`. **Parameter Name is the literal string sent
over HTTP and must match the API exactly; Static ID is APEX's internal handle
and is free-form.** This project has now been bitten by both halves of that
distinction — Static IDs turning out lowercase-hyphenated when uppercase was
assumed, and a Name whose case didn't match the endpoint.

**A documentation error surfaced by a good question.** Asked what distinguishes
the listing rating from the review ratings, checking the seed file rather than
restating the docs showed that `db/mongodb/schema_notes.md` was wrong: it
claimed `avg_rating` is "computed from the embedded reviews at seed time," but
*Wharf Pier View Condo* has one review rated 5 and `avg_rating: 4.7`. The two
are independent hand-authored values. Corrected in `schema_notes.md` with the
evidence. Both numbers are visible simultaneously on Listing Detail, so the
inaccuracy would have surfaced the first time anyone compared them on screen.

**Weather Context (plan page 10) — built (Page 10) and confirmed against real
data. This completes all 12 planned pages.** A bar chart of the last five
observations above a Classic Report of the raw snapshots, both driven by a
neighborhood Select List. Verified by cross-checking the two regions against
each other: for Friendship Heights the chart plots 86, 87, 85, 86, 84 across
Aug 16-20 and the report lists exactly those values.

**This is the one region on the project that does NOT use declarative REST
binding, and the reason is worth recording.** Every other Mongo-backed region —
Cards, Classic Reports, Metric Cards — binds to a REST Data Source directly and
works. A **Chart Series** would not, and it cost more troubleshooting rounds
than any other component in the app.

What was established along the way, and is genuinely useful to know:

- **A Chart Series carries its own Source; it does not inherit the region's.**
  A newly created Series defaults to `Local Database / Table` with a required
  Table Name, independent of whatever the region's Source is set to. An earlier
  assumption that the Series would inherit was wrong.
- Setting the Series' own Source to the REST Data Source, giving it
  `Page Items to Submit`, and binding its `id` parameter to the page item —
  every piece individually correct — still produced
  `ORA-20999: HTTP 404` from `/api/weather/neighborhood/`, i.e. the id never
  reached the URL. Rebuilding the region from scratch reproduced it exactly.
- The **404 itself was the useful diagnostic**, and only appeared after enabling
  Debug. Before that the region silently rendered "No data to display", which
  is indistinguishable from an empty result. Turning on Debug should come much
  earlier than it did here.

**Resolution: fetch the data in PL/SQL and chart plain SQL.** A Before Header
process calls `APEX_WEB_SERVICE.MAKE_REST_REQUEST` (already proven on the Admin
page), parses the response with `JSON_TABLE`, and writes rows into an APEX
Collection named `WEATHER_TREND`; the Series then runs an ordinary SQL query
against `APEX_COLLECTIONS`. Charts over SQL are completely reliable.

Two deliberate choices inside that process:

- `SUBSTR(observed_at, 1, 10)` rather than `TO_TIMESTAMP_TZ` with a format mask
  — the ISO date substring sorts correctly as text and carries no format-mask
  risk.
- An explicit `g_status_code != 200` check, for the same reason as the Admin
  page's Mongo reload: `MAKE_REST_REQUEST` does not raise on a non-200, so
  without it a failed fetch would render an empty chart rather than an error.

**Stated trade-offs:** the neighborhood Select List submits the page rather than
firing an AJAX refresh, because the fetch runs Before Header — heavier than the
refresh pattern used elsewhere. And this region breaks the app's otherwise
consistent "native components, declarative binding" rule. Both were accepted
knowingly: a working chart with one documented exception beats continuing to
fight a binding that would not cooperate. If a future APEX release fixes Chart
Series REST binding, this region is the one to revisit.

---

## Build status: 12 of 12 planned pages complete

| Plan # | Page | App page |
|---|---|---|
| 1 | Home / Dashboard | 1 |
| 2 | Neighborhood Explorer | 4 |
| 3 | Neighborhood Detail | 6 |
| 4+5 | Restaurant Finder + Recommend | 7 |
| 6 | Stay / Listings | 2 |
| 7 | Listing Detail | 3 |
| 8 | Listings Recommend | 2 (second region) |
| 9 | Entertainment | 9 |
| 10 | Weather Context | 10 |
| 11 | User Profile | 8 |
| 12 | Admin / Seed Data | 5 |

Added beyond the original plan: the `venues` collection and its Entertainment
region, the `min_rating` preference end-to-end across all three tiers, and
neighborhood context (restaurants, theaters, movies) on Listing Detail.


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
