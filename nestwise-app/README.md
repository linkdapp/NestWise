---
title: NestWise App
---

# NestWise

A hybrid Oracle + MongoDB application built to put **real, application-shaped
traffic** through a 2-node Oracle RAC cluster — not synthetic load, and not a
static mockup.

One Oracle APEX application in front of two databases. Oracle (on the RAC
cluster) owns everything relational and transactional. MongoDB owns the
genuinely document-shaped data. Twelve pages, all built and verified against
real data.

Washington, D.C. is the seeded city: 28 neighborhoods, 87 restaurants, 14
theaters in Oracle; 56 listings with embedded reviews, 13 movies, 56 weather
snapshots and 28 nightlife venues in MongoDB.

---

## Why it exists

The point isn't the app. The point is that a RAC cluster, a Data Guard
configuration, and an ORDS/APEX stack are much easier to *claim* you can
operate than to actually run something on. NestWise is the something.

Everything below was found by building it, not by reading about it.

---

## Architecture at a glance

```
                    ┌───────────────────────────┐
                    │  APEX 26.1 + ORDS 26.2    │
                    │      (oradbserv04)        │
                    └─────────┬─────────┬───────┘
                              │         │
              ORDS / SQL      │         │   REST Data Sources
                              │         │
                    ┌─────────▼──┐   ┌──▼──────────────┐
                    │  Oracle    │   │  Node/Express   │
                    │  19c RAC   │   │  proxy :4000    │
                    │  2 nodes   │   └──┬──────────────┘
                    │ + Data Guard│      │
                    └────────────┘   ┌───▼──────────┐
                                     │  MongoDB     │
                                     └──────────────┘
```

Full reasoning, including why the ORDS-native MongoDB API path wasn't used on
this build, is in [`docs/architecture.md`](docs/architecture.md).

**The split, and why:**

| Data | Tier | Reason |
|---|---|---|
| Neighborhoods, restaurants, theaters, favorites, preferences | Oracle | Fixed shape, referential integrity, transactional |
| Listings with embedded reviews | MongoDB | Variable-length nested arrays read with the parent |
| Movies | MongoDB | `neighborhood_ids` is an array — awkward as a junction table |
| Weather snapshots | MongoDB | Append-only time series |
| **Venues** (bars, lounges, live music, comedy, breweries, rooftops) | MongoDB | **The strongest case in the app** — attributes differ *per venue type*. A brewery has a tap count; a music room has set nights and a cover charge; a rooftop has a view and seasonality. Relationally that's a wide sparse table or an EAV side table. Here each document holds only what it needs. |

The `theaters` table stays in Oracle *precisely because* every cinema has the
same three attributes. Both models on one page is the argument.

---

## What's built

All 12 planned pages. Details and per-page build notes in
[`apex/page_plan.md`](apex/page_plan.md).

| Page | What it demonstrates |
|---|---|
| Home / Dashboard | Four tiles — two Oracle, two MongoDB — plus a chart |
| Neighborhood Explorer | Interactive Report, live search, favorite toggle |
| **Neighborhood Detail** | **Oracle and MongoDB rendering side by side on one page** |
| Restaurant Finder (+ Recommend) | Declarative filters; preference-scored recommendations |
| Stay / Listings (+ Recommend) | Cards over MongoDB; city-wide scored recommendations |
| Listing Detail | Embedded reviews, plus Oracle neighborhood context |
| **Entertainment** | **Oracle theaters beside MongoDB movies and venues, one filter driving both** |
| Weather Context | Five-observation trend chart and raw snapshots |
| User Profile | Preferences driving both recommendation surfaces |
| **Admin / Seed Data** | **Live reset of both databases from the UI** |

---

## Findings worth reading

These are the parts a practitioner will care about. Each is documented in full
where noted.

### An IDENTITY column silently broke cross-database integrity

`neighborhoods.neighborhood_id` was `GENERATED ALWAYS AS IDENTITY`, and the seed
reload does `DELETE` + `INSERT`. **`DELETE` does not reset an identity
sequence** — so every reload produced a fresh, higher range (1-28 → 9-36 → …)
while MongoDB kept its original numbering.

The failure mode was the dangerous kind: not an error, but *one neighborhood
quietly showing another neighborhood's listings*, because both were plausible
D.C. neighborhoods and nothing looked wrong. It was caught only by checking that
Georgetown's data actually described Georgetown.

Fixed at the cause rather than with a sync script: the identity was dropped and
the seed now supplies IDs explicitly. Nothing in the app inserts a neighborhood
at runtime, so a generated key bought nothing and cost integrity. Reloads are
now idempotent — which is what made the Admin page safe to build at all.
→ [`db/oracle/04_neighborhood_id_stability.sql`](db/oracle/04_neighborhood_id_stability.sql),
[`db/mongodb/schema_notes.md`](db/mongodb/schema_notes.md)

### REST Data Source traps that fail silently

Four distinct ones, each of which produced plausible-looking wrong data rather
than an error:

- **A Data Source-level parameter isn't enough.** It must also be attached to
  the specific **Operation**. Without that, the request goes out unfiltered — a
  region returned all 56 listings while appearing correctly configured.
- **APEX doesn't insert a separator** between URL Path Prefix and URL Pattern.
  `/api/listings` + `:id` becomes `/api/listings:id`.
- **Parameter Name is the literal string sent over HTTP and is case-sensitive.**
  A parameter named `Rating` against an endpoint reading `rating` silently
  applied no filter at all.
- **Rediscovery profiles whatever comes back — including error responses.** A
  404 body was once profiled as the schema. Three Data Sources registered but
  never exercised turned out to have stale profiles inherited from a different
  endpoint's shape.

Assume any REST Data Source that has never actually run has the wrong Data
Profile until Rediscovery proves otherwise. → [`apex/page_plan.md`](apex/page_plan.md)

### `MAKE_REST_REQUEST` does not raise on non-200

It returns the body and sets `apex_web_service.g_status_code`. Without an
explicit check, a failed call reports success. The check caught a real `HTTP
401` on the Admin page's MongoDB reload immediately after being added.

### The database was never the bottleneck

Three load runs against the ORDS layer, which exercises the same PL/SQL packages
the APEX pages call:

| Run | Concurrency | Throughput | p95 | NESTWISE sessions |
|---|---|---|---|---|
| Stepped, human think time | 10 → 100 VUs | 39.6 req/s | 5-14 ms, **flat** | ~6 |
| Saturate, 50 ms think time | 100 → 1000 VUs | **928 req/s** | ~1000 ms, uniform | ~100 (pool ceiling) |

The second run's tell is the **uniformity**: all six transaction types converged
within 30 ms of each other at p95, including the heaviest scored-sort query that
was 5× slower than the rest under light load. Identical latency for
unequal work is queuing, not query execution.

But it wasn't the connection pool either. Minimum observed latency stayed at
**2-6 ms**, so 100 connections could theoretically serve ~20,000 req/s. Actual
database work was roughly **five busy sessions' worth**. The connections were
open but idle; the constraint sat above Oracle.

**Stated honestly: this run cannot cleanly attribute the ~928 req/s ceiling**,
because the load generator was running on the same host as ORDS and competing
for CPU. What it *does* establish is that the database tier was coasting.
→ [`loadtest/k6/README-k6.md`](loadtest/k6/README-k6.md)

RAC session distribution was confirmed separately and repeatedly — sessions land
on both instances, unevenly and re-balancing over a run, which is correct SCAN
behaviour rather than a strict split. → [`docs/install.md`](docs/install.md) §9

### One region that isn't declarative, and why

Every MongoDB-backed region binds declaratively to a REST Data Source — except
the Weather Context chart. **An APEX Chart Series carries its own Source and
does not inherit the region's.** Even with the Series' own source, page items,
and parameter binding all individually correct, it issued requests without the
`id` and returned `HTTP 404`. A clean rebuild reproduced it exactly.

Resolution: fetch in PL/SQL with `APEX_WEB_SERVICE`, parse with `JSON_TABLE`,
write to an APEX Collection, chart plain SQL. Documented as a deliberate
exception with its trade-offs rather than hidden.
→ [`apex/page_plan.md`](apex/page_plan.md)

---

## Repository layout

```
nestwise-app/
├── docs/
│   ├── architecture.md            The hybrid split and its reasoning
│   ├── install.md                 Full install, smoke test, RAC session check
│   ├── demo-script.md             Click-by-click presenter script
│   ├── apex-server-install.md     APEX 26.1 install
│   ├── ords-server-install.md     ORDS 26.2 install
│   └── mongodb-server-install.md  MongoDB + Node proxy install
├── db/
│   ├── oracle/                    01-05: tables, indexes, packages, seed, migrations
│   └── mongodb/                   seed_data.js, indexes.js, schema_notes.md
├── ords/rest_modules.sql          ORDS REST layer over the Oracle tables
├── proxy/                         Node/Express proxy fronting MongoDB
├── apex/
│   ├── page_plan.md               Design + full build log for all 12 pages
│   └── export/f100.sql            Application export (see export/README.md)
└── loadtest/
    ├── rac_session_check.sh       Concurrent sessions for the gv$session check
    ├── k6/                        ORDS load generation — the path actually used
    └── swingbench/                Notes, and why the custom path needs Java
```

---

## Getting started

Start with [`docs/install.md`](docs/install.md). It assumes Oracle and MongoDB
are running and nothing else is configured, and is copy-pasteable throughout.

Two things that will bite a reproducer, both documented there:

- The APEX export **cannot reproduce the app alone**. It depends on the schema
  migrations in `db/oracle/`, the proxy code, and a workspace-level Web
  Credential that exports don't carry. See
  [`apex/export/README.md`](apex/export/README.md).
- MongoDB `_id` values are regenerated on every reseed, so any hardcoded
  ObjectId in configuration or docs goes stale immediately.

---

## Scope, stated deliberately

Named because choosing scope is part of the design, not an oversight.

**Not built:** user-to-user messaging, image uploads, a city switcher (one city
at a time is a deliberate architecture decision), and any authentication beyond
APEX's built-in accounts.

**Not run:** Swingbench benchmark numbers. A NestWise-specific Swingbench
benchmark requires Java or PL/SQL transaction classes — it is *not* achievable
in XML, contrary to a claim in an earlier version of these notes. The k6 numbers
above are real; there are no Swingbench numbers, and none are implied.
→ [`loadtest/swingbench/README-swingbench.md`](loadtest/swingbench/README-swingbench.md)

**Simplified:** recommendation scoring is an explainable weighted sum
(rating + budget fit + weather match), not a trained model. Every page carrying
a score says so on the page itself.
