# NestWise load-test results

Real runs against the live lab. Every number here was measured, not estimated.

Two load generators are in play, and they answer different questions:

- **k6 against the ORDS REST layer** produces NestWise's own database workload,
  because those handlers call the same PL/SQL packages the APEX pages call.
  All numbers below come from k6.
- **Swingbench** drove the Data Guard switchover test in
  [`../../high-availability/part3-post-checks.md`](../../high-availability/part3-post-checks.md).
  That exercised the cluster, not NestWise's schema. No NestWise-specific
  Swingbench benchmark exists, and none of the figures below come from it.

Environment for all runs: Oracle 19.32.0.0.0, 2-node RAC (`oradbserv05`,
`oradbserv06`), ORDS 26.2 and APEX 26.1 on `oradbserv04`, MongoDB and the
Node proxy also on `oradbserv04`.

---

## Run 1: smoke

**Purpose:** prove the endpoints answer. Numbers deliberately discarded.

5 VUs, 1 minute, 268 requests, 4.3 req/s, 0.00% failures.

Worth one observation. Average latency exceeded p95 on several transaction
groups (browse: avg 32 ms, p95 15 ms). With only ~70 samples per group, a single
cold-start outlier paying connection setup, hard parse and cold buffer cache
drags the mean above the 95th percentile. That is an artifact of a cold, small
sample, and the reason smoke figures are not recorded as results.

---

## Run 2: stepped, human think time

**Purpose:** find the knee, where p95 stops scaling linearly.

Profile `stepped`: 10 → 25 → 50 → 100 VUs, 5 minutes per step, think time
0.5–2 s uniform random.

| Metric | Result |
|---|---|
| Duration | 22 min 30 s |
| Requests | 53,422 |
| Throughput | 39.6 req/s |
| Failure rate | 0.00% |
| p95, all transactions | 5–14 ms, **flat across every step** |
| Peak NESTWISE sessions | ~6 total (3 + 3 across instances) |

**There was no knee.** Latency did not move between 10 VUs and 100 VUs.

Two things capped this run, and neither was the database:

**ORDS connection pooling.** ORDS multiplexes HTTP requests over a JDBC pool. At
roughly 6 ms per query, 40 requests/second needs about a quarter of one
session's worth of work. The database saw the pool, not the concurrency. The
pool's default `jdbc.MaxLimit` was 10 at this point.

**Think time.** At 0.5–2 s per iteration each VU is idle roughly 99% of the
time, so 100 VUs generate about 40 requests/second rather than 100. The
arithmetic checks out: 48,592 iterations over 22.5 minutes is ~36/s, which
matches ~45 effective VUs averaged across a ramped run at 1.25 s per iteration.

---

## Run 3: saturation

**Purpose:** deliberately find a limit.

Configuration changed first: `jdbc.MaxLimit` raised from 10 to 100 and
`jdbc.InitialLimit` from 3 to 10, then ORDS restarted. Oracle headroom verified
beforehand: `processes` limit 300 against a max utilisation of 124 per instance,
leaving room for the larger pool.

Profile `saturate`: 100 → 250 → 500 → 1000 VUs, think time 50 ms.

| Metric | Result |
|---|---|
| Duration | 11 min 30 s |
| Requests | 640,496 |
| Throughput | **928.2 req/s** |
| Failure rate | 0.02% |
| Peak NESTWISE sessions | ~100 total, at the pool ceiling |

Per-transaction p95, and the important part is how similar they are:

| Transaction | avg | p95 | min | max |
|---|---|---|---|---|
| BrowseNeighborhoods | 363 ms | 1003 ms | 3 ms | 4273 ms |
| FilterRestaurants | 364 ms | 1004 ms | 3 ms | 3955 ms |
| ToggleFavorite | 381 ms | 1016 ms | 6 ms | 3336 ms |
| RecommendRestaurants | 367 ms | 1009 ms | 4 ms | 3953 ms |
| NeighborhoodStats | 333 ms | 985 ms | 2 ms | 3485 ms |
| ListTheaters | 357 ms | 995 ms | 2 ms | 3170 ms |

### Reading this honestly

**The uniformity is the finding.** All six transaction types converged within
30 ms of each other at p95. Under light load `RecommendRestaurants` was roughly
five times slower than the cheap browse calls, because it is a full scored sort
with a different plan. Here it costs the same as everything else. Identical
latency for unequal work is queuing, not query execution.

**It was not the connection pool either.** Minimum latency stayed at 2–6 ms, so
100 connections could in principle serve around 20,000 req/s. Actual database
work was roughly `928 × 0.005 = 4.6` seconds per second, about five busy
sessions' worth. The pool grew to 100 because ORDS opens connections under
concurrency pressure, not because those connections were saturated. They were
open and largely idle.

**This run cannot cleanly attribute the ~928 req/s ceiling.** k6 was running on
`oradbserv04`, the same host as ORDS and APEX, so the load generator competed
for CPU with the system under test. At 40 req/s that was immaterial. At 928 it
is not. The ceiling is somewhere in the ORDS JVM, the HTTP layer, or that CPU
contention, and this run cannot separate them.

**What it does establish**, and this part is solid: **the database tier was
never the constraint.** The 2–6 ms floor and the idle-connection arithmetic
settle that independently of the confound.

### RAC session distribution

Sampled during the run:

```
   INST_ID   COUNT(*)
---------- ----------
         1         48
         2         51
---------- ----------
         1         44
         2         54
```

Both instances took work, roughly evenly, with the split shifting over the run.
That is correct SCAN behaviour: it balances on connection count and instance
load rather than enforcing a strict split, and it re-balances continuously.

---

## Open items

**Re-run the saturation profile from a host that is not `oradbserv04`.** This is
the single change that would let the ~928 req/s ceiling be attributed rather
than described. `oemserver01` was the intended target and the run only failed
there because the script had not been copied across.

**No AWR or ADDM analysis yet.** Everything above is application-tier. The
database-side wait-event story, which is what a DBA audience would actually want,
is still missing. Taking manual AWR snapshots either side of a steady run is the
obvious next step, and it is the prerequisite already noted against Phase 5 in
[`../../02-roadmap-skeleton.md`](../../02-roadmap-skeleton.md).

**No index changes tested.** `workload_notes.md` lists the indexes each
transaction targets. Nothing here has yet measured a run with one of them
dropped, which would be the honest way to show they matter.
