# NestWise — Install & Setup Guide

Assumes this project's own real infrastructure: the `usatclust1`/`usatclust2` 2-node Oracle RAC + Data Guard build (`apexdb`, 12.2.0.1, documented in `installation/` and `high-availability/`) is already running, ORDS is installed somewhere reachable from both clusters, APEX is installed in the database, and a standalone MongoDB server is reachable from that same app server. Nothing else is assumed to be configured yet. Hostnames/service names below are this project's real, already-established values (see `high-availability/README.md` and `phase-01-foundation-2node-rac-12cR2/ansible/group_vars/all.yml`) — adjust only if your own environment differs.

**Read this before step 1, not after a broken demo:** this project already learned, the hard way, that a client pointed at a single cluster's SCAN listener breaks *permanently* the moment a real Data Guard switchover relocates the service to the other cluster (`high-availability/part3-post-checks.md` Section 16, `known-risks.md` #139). One-off `sqlplus`/`curl` admin commands below (schema creation, DDL, ORDS module definitions) are fine against a single SCAN — they run once, against whichever cluster is currently primary. But ORDS's own connection pool, which serves every live page request, is a standing connection exactly like Swingbench's was — it needs the same two-cluster-aware descriptor from [`high-availability/tnsnames-application.ora`](../../high-availability/tnsnames-application.ora), not a single SCAN name. See step 6a below.

## 0. Topology reference

```
app-server (runs APEX/ORDS + the Node proxy)
  ├── ORDS  → connects to Oracle RAC via the apexdb_rw role-based service,
  │            through BOTH clusters' SCAN listeners (two-address descriptor —
  │            see high-availability/tnsnames-application.ora), so it survives
  │            a real switchover instead of stalling like the first Swingbench
  │            attempt did in Section 16
  └── nestwise-mongo-proxy (Node, port 4000) → connects to MongoDB
mongo-host (standalone MongoDB, port 27017)
```

## 1. Create the Oracle schema

Connect as a DBA-privileged user, via `apexdb_rw` (the role-based service from `high-availability/` Section 13 — automatically follows whichever cluster is currently primary), and create the application schema:

```sql
sqlplus sys/<sys_password>@//scan-usatclust1.usat.com:1521/apexdb_rw as sysdba

CREATE USER nestwise IDENTIFIED BY "<pick_a_strong_password>"
  DEFAULT TABLESPACE users
  QUOTA UNLIMITED ON users;

GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE PROCEDURE,
      CREATE VIEW, CREATE TRIGGER TO nestwise;

-- ORDS REST-enable the schema (needed before defining modules in step 4)
BEGIN
    ORDS.ENABLE_SCHEMA(
        p_enabled          => TRUE,
        p_schema           => 'NESTWISE',
        p_url_mapping_type => 'BASE_PATH',
        p_url_mapping_pattern => 'nestwise',
        p_auto_rest_auth   => FALSE
    );
    COMMIT;
END;
/
EXIT
```

**Real errors hit doing this against this project's own lab — both resolved, keep this handy if you're rebuilding:**

- **`ORA-06598: insufficient INHERIT PRIVILEGES privilege`** on the `ORDS.ENABLE_SCHEMA` call above. Since Oracle 12c, a privileged caller (`SYS`, here) can only invoke another schema's invoker-rights (`AUTHID CURRENT_USER`) code if that schema has been explicitly granted `INHERIT PRIVILEGES` on the caller — `ORDS_METADATA` never had it. Fix, run once as `sys`:
  ```sql
  GRANT INHERIT PRIVILEGES ON USER SYS TO ORDS_METADATA;
  ```
  (Alternative that avoids this class of error entirely: connect as `nestwise` itself and call `ORDS.ENABLE_SCHEMA` without `p_schema` — schema owners can self-enable without the DBA-role privilege-inheritance check. Only a DBA/`ORDS_ADMINISTRATOR_ROLE` account enabling *another* schema needs the `INHERIT PRIVILEGES` grant.)
- **`ORA-20011: Data Guard rolling upgrade is currently running. Please try again later.`** on the same call, even though this database's 12c→19c rolling upgrade ([`maintenance/`](../../maintenance/)) had genuinely finished days earlier. Root cause (confirmed against Oracle's own `DBMS_ROLLING` docs, not guessed): `FINISH_PLAN` completing an upgrade and `DESTROY_PLAN` purging its tracked plan state are two separate steps — the second one hadn't been run, and `ORDS_METADATA.ORDS_SECURITY_INTERNAL` checks for *any* persisted plan record, not just an actively-running one. Fix, run once as `sys`/`sysdba` on the database (not on this app server — needs `DBMS_ROLLING`, which lives on the DB host):
  ```sql
  EXEC DBMS_ROLLING.DESTROY_PLAN;
  ```
  Full root-cause writeup, and why this is now an automated step in the rolling-upgrade Ansible itself: [`maintenance/part2-finish-plan-and-troubleshooting.md` §13](../../maintenance/part2-finish-plan-and-troubleshooting.md#13-addendum--destroy_plan-wasnt-actually-optional).
- **`ORA-01403: no data found`**, deep inside `ORDS_METADATA.ORDS_INTERNAL`/`ORDS_SERVICES_INTERNAL`, on the very next retry — after both errors above were genuinely fixed. Root cause, confirmed by querying the metadata directly rather than guessing: `SELECT * FROM ords_metadata.ords_version` showed `STATUS = INSTALLING`, not a completed state — `ords_schemas`/`ords_modules`/`ords_handlers` were all empty too. The original `21-AUG` install attempt (`ords-server-install.md` §5) died on `oauth_internal.plb` before it ever reached whatever step marks that row finished; the 19c-upgrade recompile later fixed the *object* validity, but never touched that bookkeeping row; the `24-AUG` re-run (§7) then saw valid objects and an existing version and took the "verify existing schema" shortcut instead of a real install — which never finalizes that status either. Net effect: `ORDS_METADATA` had looked "installed" (valid objects, version row present) for days without ever actually completing its own install. Fix — clean uninstall + reinstall, the Oracle-documented remedy for an incomplete/corrupt ORDS metadata schema (safe here since nothing had ever been successfully registered — all three counts above were 0):
  ```bash
  sudo systemctl stop ords
  ords --config /u01/app/ords/config uninstall
  ords --config /u01/app/ords/config install
  sudo systemctl start ords
  ```
  Confirmed working — `ORDS.ENABLE_SCHEMA` for `NESTWISE` completed cleanly on the very next attempt after this. Full writeup: [`ords-server-install.md` §9](ords-server-install.md#9-addendum--the-ora-01403-stuck-installing-status).

## 2. Run the Oracle DDL, in order

Connect as `nestwise` and run the four scripts under `db/oracle/` **in filename order** — `03_packages.sql` must run before `99_seed_data.sql` because the seed script calls `admin_pkg.reload_oracle_seed_data`:

```bash
sqlplus nestwise/<password>@//scan-usatclust1.usat.com:1521/apexdb_rw \
  @db/oracle/01_tables.sql

sqlplus nestwise/<password>@//scan-usatclust1.usat.com:1521/apexdb_rw \
  @db/oracle/02_constraints_indexes.sql

sqlplus nestwise/<password>@//scan-usatclust1.usat.com:1521/apexdb_rw \
  @db/oracle/03_packages.sql

sqlplus nestwise/<password>@//scan-usatclust1.usat.com:1521/apexdb_rw \
  @db/oracle/99_seed_data.sql
```

Verify:

```sql
SELECT COUNT(*) FROM neighborhoods;   -- expect 28
SELECT COUNT(*) FROM restaurants;     -- expect 87
SELECT COUNT(*) FROM theaters;        -- expect 14
SELECT setting_value FROM app_settings WHERE setting_key = 'current_city'; -- Washington
```

Confirmed against this lab's own real load:

```
SQL> SELECT COUNT(*) FROM neighborhoods;
  COUNT(*)
----------
        28
SQL> SELECT COUNT(*) FROM restaurants;
  COUNT(*)
----------
        87
SQL> SELECT COUNT(*) FROM theaters;
  COUNT(*)
----------
        14
SQL> SELECT setting_value FROM app_settings WHERE setting_key = 'current_city';
SETTING_VALUE
--------------
Washington
```

(87, not the ~115 estimated when the D.C. dataset comments were first written — the comments in `03_packages.sql`/`99_seed_data.sql` said "~115" but that was never a real count, just an estimate at generation time. Corrected in-code too.)

**Real errors hit doing this against this project's own lab — both resolved:**

- **`nbhd_pkg.toggle_favorite` — `ORA-00905: missing keyword`, on a `MERGE ... WHEN MATCHED THEN DELETE;` statement.** `DELETE` is only valid as a sub-clause of `WHEN MATCHED THEN UPDATE` (it deletes the row the `UPDATE` just touched, with its own `WHERE`) — a bare `WHEN MATCHED THEN DELETE;` isn't valid MERGE syntax at all. Fixed by replacing the MERGE with a plain existence-check-and-branch (`SELECT COUNT(*)` then `IF`/`DELETE`/`INSERT`), which is the correct, idiomatic way to express toggle semantics in PL/SQL.
- **`restaurant_pkg` — `PLS-00231: function 'PRICE_RANK' may not be used in SQL`, plus a cascading `ORA-00904`.** Not an ordering problem (moving `price_rank` earlier in the body didn't fix it) — a real, confirmed Oracle restriction: a **private** package function (declared only in the body, never in the spec) can never be called from a SQL statement, even one embedded in that same package's own body. `recommend_for_user` calls `price_rank(...)` from inside its `SELECT`, so `price_rank` has to be public. Fixed by adding `price_rank`'s declaration to `restaurant_pkg`'s spec, not just its body — the exact same reasoning this project already applied to `nbhd_pkg.is_favorited` (public specifically so it's SQL-callable).

Confirmed clean on the next compile: `SELECT object_name, object_type, status FROM user_objects WHERE object_type LIKE 'PACKAGE%'` showed every package and package body `VALID`.

## 3. Define the ORDS REST modules

```bash
sqlplus nestwise/<password>@//scan-usatclust1.usat.com:1521/apexdb_rw \
  @ords/rest_modules.sql
```

**Real bugs caught in this script, one before it was ever run and one during the actual run against this lab:**

- **Caught in review, before running:** five handlers (`neighborhoods/:id`, `restaurants/` search, `restaurants/recommend/:app_user`, `preferences/:app_user` GET, `admin/dashboard-counts`) originally wrapped their PL/SQL function calls in `SELECT * FROM TABLE(CAST(fn(:bind) AS SYS_REFCURSOR))` — not valid Oracle SQL, since `TABLE()` only accepts a collection type, never a REF CURSOR. Confirmed against Oracle's documented ORDS pattern before fixing: a `FUNCTION` returning `SYS_REFCURSOR` is exposed with `p_source_type => ORDS.source_type_collection_feed` and a plain `SELECT function(:bind) FROM DUAL` — no `TABLE()`/`CAST`.
- **Hit for real on the first actual run:** `ORA-01400: cannot insert NULL into ("ORDS_METADATA"."ORDS_TEMPLATES"."URI_TEMPLATE")` on the very first `DEFINE_TEMPLATE` call. Root cause: the two module-root templates (`neighborhoods.api`, `restaurants.api`) used `p_pattern => ''` (empty string) — Oracle treats a zero-length `VARCHAR2` as `NULL`, and `URI_TEMPLATE` is `NOT NULL`. Confirmed against Oracle's own `ORDS_ADMIN` package reference before fixing: every documented example of a module's root resource uses `p_pattern => '.'` (a single dot), never `''`.
- **Hit for real once the script finally ran clean and requests reached this schema's modules (see §6a for the pool-routing detour that blocked this from being testable at all until it was resolved):** the five handlers wrapping a `SYS_REFCURSOR`-returning function with `SELECT function(:bind) FROM DUAL` (the fix for the first bug above, sourced from a documented ORDS blog pattern) compiled and ran without error, but returned `{"items":[{"<literal source text>":[]}]}` instead of real rows — ORDS 26.2 doesn't reliably unwrap a REF CURSOR cell into JSON this way, regardless of whether the function logically returns one row or many. Confirmed empirically against two of the five endpoints before fixing all five the same way: rewritten to inline the exact same SQL the underlying PL/SQL function already runs (read directly from `db/oracle/03_packages.sql`, not guessed), the same plain-SQL technique already proven working by this file's three table-backed handlers.

**All nine endpoints confirmed working against this lab's real, live data after every fix above landed:**

```
GET  /ords/nestwise/neighborhoods/                    → 25 of 28 neighborhoods, paginated
GET  /ords/nestwise/neighborhoods/9                    → Georgetown stats: 5 restaurants, 1 theater, avg rating 4.4
GET  /ords/nestwise/neighborhoods/9/restaurants        → (table-backed, unaffected by the REFCURSOR bug)
GET  /ords/nestwise/neighborhoods/9/theaters           → (table-backed, unaffected by the REFCURSOR bug)
GET  /ords/nestwise/restaurants/?neighborhood_id=1     → real rows once tested against a current ID
GET  /ords/nestwise/restaurants/recommend/DEMO         → 10 scored recommendations, real data
GET  /ords/nestwise/preferences/DEMO                   → empty, correctly — DEMO has favorites seeded, not preferences
GET  /ords/nestwise/admin/dashboard-counts             → {"neighborhood_count":28,"restaurant_count":87,"theater_count":14}
```

Note on `neighborhood_id`: this schema's `neighborhoods` IDENTITY sequence has advanced well past 28 from repeated `reload_oracle_seed_data` runs during this install/troubleshooting session (the drift already documented in `db/mongodb/schema_notes.md`) — Georgetown is `neighborhood_id = 9` here, not `1`. A genuinely fresh install is the only time the 1–28 mapping in `schema_notes.md` is guaranteed to hold; always look up a real current ID (e.g. from the plain neighborhoods list) rather than assuming `1` when testing or demoing.

All three fixed in the script itself; see the header comment in `ords/rest_modules.sql` for the full note. **Worth double-checking before re-running:** the `ORA-01400` came from a copy of this script already staged on the DB host — if a fix lands in this repo, it still has to be re-copied/re-pulled onto whichever host actually runs `sqlplus @rest_modules.sql`, the same "editing the repo doesn't touch an already-deployed copy" gotcha called out in `mongodb-server-install.md` §10.

Confirm each module is live (replace host/port with your ORDS listener):

```bash
curl http://<ords-host>:8080/ords/nestwise/neighborhoods/
curl http://<ords-host>:8080/ords/nestwise/restaurants/cuisines
curl http://<ords-host>:8080/ords/nestwise/admin/dashboard-counts
```

Each should return JSON, not a 404.

## 4. Set up MongoDB

Assumes the Mongo host is already installed and configured — see
[`mongodb-server-install.md`](mongodb-server-install.md) for the real, from-scratch server build
(package install, storage layout, service-account/sudo access model, auth bootstrap) done for
this project on `oradbserv04`. The commands below are just the schema/seed-data step that runs
against an already-running server.

Auth is enabled on this server (`mongodb-server-install.md` §8) and `mongod` is bound to
`127.0.0.1` only, deliberately, since the proxy runs on this same host
(`mongodb-server-install.md` §5) — run these **on the Mongo host itself**, as `nestwise_app`
(the scoped app user created in §8), not against the hostname/external IP:

```bash
mongosh "mongodb://nestwise_app:<password>@localhost:27017/nestwise?authSource=nestwise" db/mongodb/seed_data.js
mongosh "mongodb://nestwise_app:<password>@localhost:27017/nestwise?authSource=nestwise" db/mongodb/indexes.js
```

`<password>` is the same value already in `/etc/nestwise-proxy.env`'s `NESTWISE_MONGO_URL` on
the app server, if it needs to be looked up rather than remembered.

**Real gotcha hit doing this against this project's own lab:** connecting via the hostname
(`mongodb://oradbserv04:27017`) fails with `ECONNREFUSED` against the host's real NIC IP — not a
bug, just `bindIp: 127.0.0.1` doing exactly what it's documented to do. And the bare,
no-credentials connection string this section used to show would fail separately with
"requires authentication" once §8's auth bootstrap is done — both fixed by using `localhost`
plus the `nestwise_app` credentials as shown above.

Verify:

```bash
mongosh "mongodb://nestwise_app:<password>@localhost:27017/nestwise?authSource=nestwise" --eval \
  "print('listings: ' + db.listings.countDocuments({}) + ', movies: ' + db.mflix_movies.countDocuments({}) + ', weather: ' + db.weather_snapshots.countDocuments({}))"
```

Expect `listings: 56, movies: 13, weather: 56` — confirmed against this lab's own real run.

## 5. Install and start the Node/Express proxy

On the app server (needs Node.js 18+ and network access to both MongoDB and, for the admin reload, a local `mongosh` binary). Mongo auth is enabled (§4 above) so the connection string needs the `nestwise_app` credentials and `authSource`, matching what's actually deployed on `oradbserv04` — see `mongodb-server-install.md` §10 for the full systemd-unit version (`/etc/nestwise-proxy.env`), kept out of shell history and the unit file itself:

```bash
cd proxy
npm install
export NESTWISE_MONGO_URL="mongodb://nestwise_app:<password>@localhost:27017/nestwise?authSource=nestwise"
export NESTWISE_MONGO_DB="nestwise"
export NESTWISE_ADMIN_TOKEN="<pick-a-secret-matching-the-APEX-web-credential-in-step-7>"
export PORT=4000
npm start
```

Verify:

```bash
curl http://localhost:4000/health
curl "http://localhost:4000/api/listings?neighborhood_id=1"
curl "http://localhost:4000/api/weather/current?city=Washington"
```

Confirmed live and already running under systemd on `oradbserv04` — real output as of this writing:
```json
{"status":"ok","service":"nestwise-mongo-proxy"}
```
```json
[{"_id":"6a8da1cfbae797d61b97b546","neighborhood_id":1,"title":"Canal-View Rowhouse Suite","price_per_night":235,"amenities":["wifi","kitchen","air conditioning"],"avg_rating":4.6,"created_at":"2026-01-10T00:00:00Z"}, ...]
```
Run it under a process supervisor (systemd unit, or `pm2 start server.js --name nestwise-proxy`) so it survives a reboot — one unit file, no container orchestration needed for a single-server showcase.

## 6. Import/build the APEX application

Assumes APEX itself is already installed and reachable — see
[`apex-server-install.md`](apex-server-install.md) for the real, from-scratch install done for
this project on `oradbserv04` (software staging, SQLcl instead of a full Oracle client, dedicated
tablespace decision, `apexins.sql`, `APEX_PUBLIC_USER`/ORDS REST bridge, static images). The steps
below are just building the app itself, against an already-running Builder.

Either build the app by hand from `apex/page_plan.md`, or:

1. In APEX, create a new empty application named "NestWise" pointed at the `nestwise` schema.
2. Set Authentication Scheme to `Application Express Accounts` (Shared Components → Authentication Schemes).
3. Create the eight nav entries and pages listed in `apex/page_plan.md`, region by region.
4. Add application item `G_CURRENT_CITY`; set it on the "Post-Authentication" process by calling `admin_pkg.get_current_city` into the item.

## 6a. Point ORDS's own connection pool at the two-cluster descriptor

**Bottom line, corrected after a long real troubleshooting detour (kept below in full since the mistakes are instructive): this step is almost certainly already done. Verify it against `ords-server-install.md` §6 before configuring anything new.**

The original `ords install` run on `oradbserv04` (`ords-server-install.md`, lines ~119–144) already set the `default` pool's `db.customURL` to this exact two-address descriptor, `db.username` to `ORDS_PUBLIC_USER`, and `restEnabledSql.active` to `true`. That pool is what actually serves every schema-alias-routed REST request (`/ords/nestwise/...`) for a self-enabled schema like `NESTWISE`. Verify it's still correct:

```bash
ords --config /u01/app/ords/config config --db-pool default list
```

Expect `db.customURL` to already show both `scan-usatclust1` and `scan-usatclust2` addresses, `db.username = ORDS_PUBLIC_USER`, and `restEnabledSql.active = true`. If so, **this step is done — do not create a separate named pool.** If `default` is somehow missing the two-cluster descriptor, update it in place (`ords --config /u01/app/ords/config config --db-pool default set db.customURL "..."`, then `sudo systemctl restart ords`), never under a new pool name.

**Why this warning exists — the real detour taken on this project's own lab, root-caused end to end:**

The first attempt at this step (below, preserved for the record) created a *new*, separately-named pool called `nestwise` and pointed it at the same descriptor, on the mistaken assumption that ORDS's own connection needed its own dedicated pool. Two real, fixable bugs were hit and fixed along the way (CLI flag ordering, then a missing `db.username`) — but even after both were fixed, every REST request still returned a plain `NotFound`, including ORDS's own built-in `metadata-catalog` endpoint and a freshly auto-REST-enabled table that had nothing to do with this project's custom modules. That last fact was the key clue: the problem couldn't be anything about `rest_modules.sql` specifically, since even framework built-ins failed identically.

Root cause, confirmed with `debug.printDebugToScreen` turned on and the actual ORDS startup log (`Mapped local pools ... /ords/nestwise/ => nestwise => VALID`), cross-referenced against `user_ords_schemas` (which showed the self-enabled `NESTWISE` schema's own `BASE_PATH` URL alias is *also* the literal string `nestwise`): **a custom pool's name and a REST-enabled schema's URL alias share the same top-level namespace under `/ords/`.** Naming the pool identically to the schema's alias meant the pool-name routing rule (registered explicitly at ORDS startup) permanently shadowed the schema-alias routing rule that would otherwise have reached the already-correctly-configured `default` pool. The new pool was also missing `restEnabledSql.active`, so even without the naming collision it had no Database API context wired up at all — a second, independent reason it could never have worked.

Fix: the redundant pool was removed entirely (`mv .../config/databases/nestwise .../nestwise.disabled.bak`), letting requests fall through to `default`, which was already correctly configured this whole time. Confirmed working immediately after: `curl http://localhost:8080/ords/nestwise/neighborhoods/` returned real neighborhood JSON.

**Lesson for any future step in this project that touches ORDS pool configuration: check what `ords-server-install.md` already established before configuring anything new, and never name a custom pool identically to a schema's own REST alias.**

<details>
<summary>Original (misguided) attempt, preserved for the record — do not follow this path</summary>

```bash
ords --config /u01/app/ords/config config --db-pool nestwise set db.connectionType customurl
ords --config /u01/app/ords/config config --db-pool nestwise set db.customURL "jdbc:oracle:thin:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=scan-usatclust1.usat.com)(PORT=1521))(ADDRESS=(PROTOCOL=TCP)(HOST=scan-usatclust2.usat.com)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=apexdb_rw)))"
sudo systemctl restart ords
```

Gotcha 1: `ords config set --db-pool <pool> <key> <value>` (options after the subcommand) fails with "Unknown option: --db-pool" on ORDS 26.2 — `--db-pool` must sit directly after `config` and before `set`.

Gotcha 2: switching `db.customURL` alone left the pool with no `db.username`, causing `DatabaseCredentialError` / `ORA-01017`. Two attempts were burned chasing it as a password problem (`ALTER USER ORDS_PUBLIC_USER ...`, then `ords config secret db.password` against a copy-pasted placeholder path) before confirming `db.username` was simply never set. Fixed by giving the pool the schema's own login directly — which worked for authentication, but still hit the pool-naming collision above.

Gotcha 3 (the real one): even fully fixed, every request 404'd — root-caused as the pool-name/schema-alias collision described above. This entire path was abandoned in favor of using `default`, which had been correct from the start.

</details>

## 7. Register the MongoDB REST Data Sources

Shared Components → REST Data Sources → Create → **From Scratch**. For each row in the table in `apex/page_plan.md` ("REST Data Sources to register"):

1. Name it exactly as listed (e.g. `RDS_LISTINGS`).
2. Base URL: `http://<app-server>:4000` (the proxy).
3. Path: the endpoint path (e.g. `/api/listings`).
4. Add any query-string parameters the page needs as REST Data Source parameters (`neighborhood_id`, `budget`, `weather`, `city`).
5. Click **Test Request** before saving — catches URL/param typos immediately instead of mid-page-build.

For the Admin page's MongoDB reload button, instead create a **Web Credential** (Shared Components → Web Credentials) named `NESTWISE_PROXY_ADMIN` holding the `NESTWISE_ADMIN_TOKEN` value from step 5, and reference it from the page 12 PL/SQL process:

```sql
DECLARE
    l_response CLOB;
BEGIN
    APEX_WEB_SERVICE.SET_REQUEST_HEADERS(p_name_01 => 'X-Nestwise-Admin-Token',
                                          p_value_01 => :NESTWISE_ADMIN_TOKEN_CRED);
    l_response := APEX_WEB_SERVICE.MAKE_REST_REQUEST(
        p_url         => 'http://<app-server>:4000/api/admin/reload',
        p_http_method => 'POST'
    );
END;
```

## 8. Smoke-test the whole stack

1. Log into the APEX app.
2. Open **Home / Dashboard** — all four tiles should populate (two from Oracle, two from Mongo via the proxy).
3. Open **Neighborhood Explorer → Georgetown (detail)** — confirm the Oracle "Overview" region and the Mongo "Stay & Weather Here" region both render on the same page (this is the hybrid smoke test).
4. Toggle a favorite; confirm the icon flips without a full page reload.
5. Open **Admin / Seed Data** (sign in as `nestwise_admin` — the page and its navigation entry are both guarded by the `Admin Only` authorization scheme and are invisible to `nestwise_test`), click both reload buttons, confirm the status region's counts update **and that Min/Max Nbhd Id still read 1 and 28**. That last check is the important one: it proves the reset is idempotent and hasn't re-broken the Oracle↔MongoDB join. See `db/oracle/04_neighborhood_id_stability.sql` for why an earlier version of this schema could not make that guarantee.

If any REST Data Source region shows blank instead of erroring, check the proxy's logs (`npm start` output) first — that's almost always a filter parameter mismatch or the proxy not running, not an APEX config issue.

## 9. (Optional) Confirm RAC is actually being exercised

```sql
SELECT inst_id, COUNT(*) 
FROM gv$session 
WHERE username = 'NESTWISE' 
GROUP BY inst_id;
```

Run this while the app is in use (or during the Swingbench run in `loadtest/`) to confirm sessions are landing on both RAC instances, not just one — that's the actual point of building this app on RAC in the first place.

**Confirmed for real against this lab, and a caveat about how you generate the load.** Browsing the app by hand returns `no rows selected` every time — not because RAC isn't working, but because each page's database work completes in milliseconds, so by the time you switch windows and run the query, every session has already closed. Sustained concurrent load is required to observe anything.

`loadtest/rac_session_check.sh` exists for exactly this: it spawns N concurrent `sqlplus` sessions running NestWise's real hot-path queries in a loop, connecting through the **SCAN listener** (connecting directly to a single instance would defeat the test). Real result from this lab, 20 concurrent sessions:

```
   INST_ID   COUNT(*)
---------- ----------
         1         14
         2          6

-- and a moment later:
         1         11
         2          8
```

Both instances taking real load. The split is uneven and that's expected — SCAN balances on connection count and instance load, not a strict 50/50, and it re-balances over the life of the run (note how 14/6 drifted toward 11/8).

Two gotchas worth knowing if this returns nothing for you:

- **`NESTWISE_PASSWORD` must be exported before running the script**, or all sessions die instantly and the script's own `> /dev/null 2>&1` hides the error — it prints "Done" immediately instead of after the full duration. If the script returns in under a second, that's the tell. Use `read -s NESTWISE_PASSWORD && export NESTWISE_PASSWORD` to keep it out of shell history.
- **`username = 'NESTWISE'` is the right filter for this script**, which logs in as `nestwise` directly. It would *not* be the right filter for traffic arriving through APEX/ORDS, which runs through a pooled technical account and sets the schema via `ALTER SESSION SET CURRENT_SCHEMA` — for that path, filter on `schemaname` or `module` instead.
