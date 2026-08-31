# APEX application export — source of truth for reproducibility

`f100.sql` is a **Standard Export** (Format: SQL) of Application 100 (NestWise),
generated from App Builder → Application 100 → Export. This is the real,
runnable artifact that reproduces every page, region, item, process, and
Dynamic Action exactly as built — not a prose description of the steps.

`apex/page_plan.md` remains the human-readable design record (why each region
is shaped the way it is, real gotchas hit and fixed) but is not a substitute
for this file. If the two ever disagree, this export is the ground truth for
what the running application actually contains.

## Convention

Re-export and overwrite `f100.sql` after each milestone (a page reaching
"built and confirmed against real data" status in `page_plan.md`). Git
history preserves every prior checkpoint, so there's no need for versioned
filenames (`f100_v2.sql`, etc.) — just overwrite.

## To reinstall from this export

**Who:** Whoever is rebuilding the app (a future you, or anyone reproducing this lab)
**What:** In SQLcl or SQL*Plus, connected as a user with rights to install into
the target workspace: `@f100.sql`. APEX will prompt for the target workspace,
schema, and whether to reuse or generate new application/page IDs.
**Where:** Run against the target Oracle database's APEX instance (see
`../docs/apex-server-install.md` for how APEX itself gets installed first).

## Checkpoints so far

| Checkpoint | App pages included | Status |
|---|---|---|
| 1 | Page 1 (Home/Dashboard, Oracle-backed tiles + chart) | Superseded by checkpoint 2 |
| 2 | + Page 4 (Neighborhood Explorer: IR, search, favorite toggle) | Superseded by checkpoint 3 |
| 3 | + Page 6 (Neighborhood Detail: Stats/Restaurants/Theaters, Region B placeholder) | Superseded by checkpoint 4 |
| 4 | + Page 7 (Restaurant Finder), Page 8 (User Profile), 6 REST Data Sources registered, Page 1's Mongo tiles, Page 6 Region B (Stay & Weather Here) fully wired, back-nav button, MongoDB `neighborhood_id` drift fixed (+8 remap) | Superseded by checkpoint 5 |
| 5 | + Page 2 (Stay / Listings), Page 3 (Listing Detail), Page 5 (Admin / Seed Data), `Admin Only` authorization scheme, `nestwise-admin-token` Web Credential. **Also depends on a schema change** — `neighborhood_id` is no longer an IDENTITY column (`db/oracle/04_neighborhood_id_stability.sql`), so this export must be paired with an up-to-date `db/oracle/` for the seed reload to work. | Superseded by checkpoint 6 |
| 6 | + Page 9 (Entertainment), plus a corrected `RDS_MOVIES_POPULAR` Data Profile | Superseded by checkpoint 7 |
| 7 | + Listings Recommend (region on Page 2), Page 10 (Weather Context), the `min_rating` preference, the `venues` collection and its Entertainment region, neighborhood context on Listing Detail, and navigation reordering. **All 12 planned pages complete.** | Current — this file |

### Checkpoint 7 depends on more than this export

`f100.sql` alone will not reproduce a working application at this checkpoint.
It must be paired with:

- **`db/oracle/`** — `04_neighborhood_id_stability.sql` (drops the
  `neighborhood_id` identity), `05_user_prefs_min_rating.sql` (adds the
  `min_rating` column), and the updated `03_packages.sql`.
- **`db/mongodb/`** — the updated `seed_data.js` (now includes the `venues`
  collection) and `indexes.js`.
- **`proxy/`** — the updated `server.js` (mounts `/api/venues`),
  `routes/venues.js` (new), `routes/listings.js` (accepts `?rating=`), and
  `routes/admin.js` (uses authenticated `NESTWISE_MONGO_URL`).
- **Workspace-level** — the `nestwise-admin-token` Web Credential, which is
  workspace-scoped rather than application-scoped and therefore **not contained
  in this export**. It must be recreated by hand on any new workspace.
