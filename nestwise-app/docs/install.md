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
SELECT COUNT(*) FROM neighborhoods;   -- expect 8
SELECT COUNT(*) FROM restaurants;     -- expect ~20
SELECT COUNT(*) FROM theaters;        -- expect 5
SELECT setting_value FROM app_settings WHERE setting_key = 'current_city'; -- San Francisco
```

## 3. Define the ORDS REST modules

```bash
sqlplus nestwise/<password>@//scan-usatclust1.usat.com:1521/apexdb_rw \
  @ords/rest_modules.sql
```

Confirm each module is live (replace host/port with your ORDS listener):

```bash
curl http://<ords-host>:8080/ords/nestwise/neighborhoods/
curl http://<ords-host>:8080/ords/nestwise/restaurants/cuisines
curl http://<ords-host>:8080/ords/nestwise/admin/dashboard-counts
```

Each should return JSON, not a 404.

## 4. Set up MongoDB

On the Mongo host (or from any machine with `mongosh` pointed at it):

```bash
mongosh "mongodb://<mongo-host>:27017" db/mongodb/seed_data.js
mongosh "mongodb://<mongo-host>:27017" db/mongodb/indexes.js
```

Verify:

```bash
mongosh "mongodb://<mongo-host>:27017/nestwise" --eval \
  "print('listings: ' + db.listings.countDocuments({}) + ', movies: ' + db.mflix_movies.countDocuments({}) + ', weather: ' + db.weather_snapshots.countDocuments({}))"
```

Expect `listings: 16, movies: 12, weather: 16`.

## 5. Install and start the Node/Express proxy

On the app server (needs Node.js 18+ and network access to both MongoDB and, for the admin reload, a local `mongosh` binary):

```bash
cd proxy
npm install
export NESTWISE_MONGO_URL="mongodb://<mongo-host>:27017"
export NESTWISE_MONGO_DB="nestwise"
export NESTWISE_ADMIN_TOKEN="<pick-a-secret-matching-the-APEX-web-credential-in-step-7>"
export PORT=4000
npm start
```

Verify:

```bash
curl http://localhost:4000/health
curl "http://localhost:4000/api/listings?neighborhood_id=1"
curl "http://localhost:4000/api/weather/current?city=San%20Francisco"
```

Run it under a process supervisor (systemd unit, or `pm2 start server.js --name nestwise-proxy`) so it survives a reboot — one unit file, no container orchestration needed for a single-server showcase.

## 6. Import/build the APEX application

Either build the app by hand from `apex/page_plan.md`, or:

1. In APEX, create a new empty application named "NestWise" pointed at the `nestwise` schema.
2. Set Authentication Scheme to `Application Express Accounts` (Shared Components → Authentication Schemes).
3. Create the eight nav entries and pages listed in `apex/page_plan.md`, region by region.
4. Add application item `G_CURRENT_CITY`; set it on the "Post-Authentication" process by calling `admin_pkg.get_current_city` into the item.

## 6a. Point ORDS's own connection pool at the two-cluster descriptor

This is the step that actually matters for surviving a real switchover — everything in step 1-3 was a one-off admin command, but ORDS's connection pool is a standing connection serving every live page request, exactly like Swingbench's connection in Section 16. Configure ORDS's pool (via `ords config` / `ords.war` datasource properties, or Database Actions if using the pluggable-pool style) to use the same two-address descriptor from `high-availability/tnsnames-application.ora`, not a single SCAN name:

```
ords config set --db-pool nestwise db.connectionType customurl
ords config set --db-pool nestwise db.customURL "jdbc:oracle:thin:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=scan-usatclust1.usat.com)(PORT=1521))(ADDRESS=(PROTOCOL=TCP)(HOST=scan-usatclust2.usat.com)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=apexdb_rw)))"
```

Without this, a real Data Guard switchover leaves ORDS permanently stuck trying to reach `apexdb_rw` on whichever cluster it's no longer running on — the exact failure mode Section 16 diagnosed and fixed for Swingbench, now reproduced in the app server if skipped here.

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
3. Open **Neighborhood Explorer → Mission District (detail)** — confirm the Oracle "Overview" region and the Mongo "Stay & Weather Here" region both render on the same page (this is the hybrid smoke test).
4. Toggle a favorite; confirm the icon flips without a full page reload.
5. Open **Admin / Seed Data**, click both reload buttons, confirm the status region's counts update.

If any REST Data Source region shows blank instead of erroring, check the proxy's logs (`npm start` output) first — that's almost always a filter parameter mismatch or the proxy not running, not an APEX config issue.

## 9. (Optional) Confirm RAC is actually being exercised

```sql
SELECT inst_id, COUNT(*) 
FROM gv$session 
WHERE username = 'NESTWISE' 
GROUP BY inst_id;
```

Run this while the app is in use (or during the Swingbench run in `loadtest/`) to confirm sessions are landing on both RAC instances, not just one — that's the actual point of building this app on RAC in the first place.
