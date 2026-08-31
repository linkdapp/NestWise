# k6 load generation against NestWise's ORDS layer

## Why k6, and why ORDS rather than the APEX UI

`loadtest/swingbench/README-swingbench.md` explains why a NestWise-specific
Swingbench benchmark needs Java or PL/SQL transaction classes. k6 sidesteps that
entirely: NestWise already exposes its Oracle data through ORDS
(`ords/rest_modules.sql`), and those handlers call **the same PL/SQL packages
the APEX pages call** — `nbhd_pkg`, `restaurant_pkg`, `theater_pkg`,
`prefs_pkg`. Driving them with plain HTTP produces NestWise's real database
workload with no custom code.

**The honest limitation, stated up front:** this drives the *database* workload,
not APEX's page-rendering overhead. A user clicking through Neighborhood Detail
also costs APEX session state, region rendering, and template processing that
this never touches. If you want the full stack under load, that needs JMeter
plus the correlation work described in `README-swingbench.md`'s comparison — the
Pretius open-source APEX template solves most of it, at roughly half a day.
Don't present k6 numbers as end-to-end application response times; present them
as database-tier throughput and latency.

## Step 0 — install k6

k6 is a single static Go binary. The tarball route works on any Linux without
adding a repo, which is why it's preferred here over the RPM repo.

**Who:** `root` (or any account that can write to `/usr/local/bin`)
**Where:** Any host that can reach the ORDS listener — an app server, a DB node,
or your workstation. It does **not** need to run on the database host, and
running it elsewhere keeps the load generator's own CPU off the system under
test.

```bash
# Fetch the latest linux-amd64 tarball from the releases page:
#   https://github.com/grafana/k6/releases
# (asset is named k6-vX.Y.Z-linux-amd64.tar.gz)
cd /tmp
curl -LO https://github.com/grafana/k6/releases/download/v<VERSION>/k6-v<VERSION>-linux-amd64.tar.gz
tar -xzf k6-v<VERSION>-linux-amd64.tar.gz
sudo install -m 0755 k6-v<VERSION>-linux-amd64/k6 /usr/local/bin/k6

k6 version    # confirm before going further
```

If `curl` to GitHub is blocked from the lab, download the tarball on your
workstation and move it across via the shared folder you already use for
`/media/sf_doracle/`.

## Step 1 — smoke test first

Never start with the full run. One minute at low concurrency catches a wrong
base URL, an unpublished ORDS module, or a 401 before you've spent half an hour.

```bash
k6 run -e BASE_URL=http://192.168.56.186:8080/ords/nestwise \
       --vus 5 --duration 1m \
       nestwise_ords.js
```

Expect `http_req_failed` at or near **0.00%**. Anything else means fix the
endpoints before continuing — the thresholds in the script will fail the run
loudly rather than let you collect meaningless numbers.

## How long should a run be?

Different questions need different durations. Three profiles, and they are not
interchangeable:

| Purpose | Concurrency | Duration | Why |
|---|---|---|---|
| **Smoke** | 5 VUs | 1 min | Prove the endpoints answer. Throw the numbers away. |
| **Find the knee** | Stepped 10 → 25 → 50 → 100 | 5 min per step, ~27 min total with ramps | You're looking for where p95 turns upward, not for a single number. Each step needs long enough to reach steady state; under 3 minutes you're mostly measuring ramp-up. |
| **RAT capture** | Steady 25 VUs | **15 min** | Database Replay reproduces *what you captured*. A steady, representative workload replays cleanly; a stepped one replays as a stepped one. |

**15 minutes is the number for a RAT capture run**, and the reasoning matters:

- Long enough to be representative and to sit comfortably inside a pair of
  manual AWR snapshots taken either side of it.
- Short enough that the capture directory stays small — capture files grow with
  workload volume, and a home lab doesn't need gigabytes of them.
- Long enough that connection setup and cache warming are a small fraction of
  the run rather than the bulk of it.

Anything beyond ~20 minutes buys very little for a demo-scale schema (28
neighborhoods, 87 restaurants) and costs disk. Anything under 10 and the capture
is dominated by warm-up.

**Run a 1-minute warm-up first and let it finish before starting the RAT
capture**, so the buffer cache and shared pool are already populated and the
capture reflects steady-state behaviour rather than cold-cache I/O.

## Step 2 — the stepped run (find the knee)

```bash
k6 run -e BASE_URL=http://192.168.56.186:8080/ords/nestwise \
       -e PROFILE=stepped \
       --summary-export=results-stepped.json \
       nestwise_ords.js
```

While it runs, in a separate SQL session:

```sql
SELECT inst_id, COUNT(*) FROM gv$session
WHERE username = 'NESTWISE' GROUP BY inst_id ORDER BY inst_id;
```

This is the same check as `docs/install.md` §9 — but now with sustained,
repeatable load behind it instead of a hand-rolled shell script.

## Step 3 — the RAT capture run

```bash
# 1. On the database, start the capture (see loadtest/rat/ if that gets written)
# 2. Then, from the load host:
k6 run -e BASE_URL=http://192.168.56.186:8080/ords/nestwise \
       -e PROFILE=capture \
       --summary-export=results-capture.json \
       nestwise_ords.js
# 3. Finish the capture on the database once k6 exits.
```

Remember RAT is a **separately licensed Enterprise Edition option**, and usage is
recorded in `DBA_FEATURE_USAGE_STATISTICS`. Say so plainly in any write-up.

## Pushing to saturation

The `stepped` run against this lab produced a completely flat curve — p95 held
at 5-14ms from 10 VUs to 100, 53,422 requests at 39.6/s, zero errors, and
`gv$session` never showed more than about six NESTWISE sessions. **The database
was never the constraint.** Two things capped it:

- **ORDS connection pooling.** ORDS multiplexes HTTP requests over a JDBC pool.
  At ~6ms per query, 40 requests/sec needs roughly a quarter of one session's
  worth of work. The database saw the pool, not the concurrency.
- **Think time.** At 0.5-2s per iteration each VU is idle ~99% of the time, so
  100 VUs generate about 40 requests/sec, not 100.

The `saturate` profile exists to find an actual limit: think time drops to 50ms
and concurrency climbs 100 → 250 → 500 → 1000. **It will fail immediately
without the four prerequisites below.**

### Prerequisite 1 — run k6 somewhere else

The `stepped` run was executed on `oradbserv04`, which is also the ORDS and APEX
host. At 40 requests/sec that barely mattered. At several thousand it very much
does: the load generator competes for CPU with the thing being measured, and the
resulting latencies are contaminated.

Move k6 to another VM, or to your workstation, and point `BASE_URL` at
`oradbserv04`. If that genuinely isn't possible, say so explicitly in the
write-up rather than presenting the numbers as clean.

### Prerequisite 2 — raise the file descriptor limit

1000 VUs will exhaust the default 1024 open files immediately.

```bash
ulimit -n              # check current, typically 1024
ulimit -n 65536        # raise for this shell
```

For a persistent change, add limits to `/etc/security/limits.conf`. For a
one-off test run, the shell-level change is enough.

### Prerequisite 3 — raise the ORDS connection pool

This is the actual DBA lever, and the reason this run is worth doing: it shows
how pool sizing gates database concurrency regardless of how many users are
knocking.

```bash
# Inspect current settings first
ords --config /u01/app/ords/config config list

# The relevant keys are jdbc.MaxLimit (default 10) and jdbc.InitialLimit
# (default 3). Set via the CLI:
ords --config /u01/app/ords/config config set jdbc.MaxLimit 100
ords --config /u01/app/ords/config config set jdbc.InitialLimit 10

sudo systemctl restart ords
```

Verify the CLI syntax against `ords config --help` before running — the exact
form varies by ORDS release, and the pool settings can also be edited directly
in the pool configuration file under `/u01/app/ords/config/databases/`.

### Prerequisite 4 — confirm Oracle has headroom for the bigger pool

**Do this before restarting ORDS with a larger pool.** Raising `jdbc.MaxLimit`
to 100 means up to 100 additional sessions per ORDS instance. If `processes` is
too low, you get `ORA-00020: maximum number of processes exceeded` — and on a
RAC cluster that can affect more than just your test.

```sql
SHOW PARAMETER processes
SHOW PARAMETER sessions

SELECT resource_name, current_utilization, max_utilization, limit_value
FROM   v$resource_limit
WHERE  resource_name IN ('processes', 'sessions');
```

Compare `limit_value` against `max_utilization` plus your new pool ceiling. If
the margin is thin, raise `processes` (an `ALTER SYSTEM ... SCOPE=SPFILE` plus a
rolling restart on RAC) *before* the test rather than discovering it mid-run.

### Running it

```bash
k6 run -e BASE_URL=http://192.168.56.186:8080/ords/nestwise \
       -e PROFILE=saturate \
       --summary-export=results-saturate.json \
       nestwise_ords.js
```

~11 minutes. Watch three things concurrently:

```sql
-- Session count per instance: should now actually climb with the pool
SELECT inst_id, COUNT(*) FROM gv$session
WHERE username = 'NESTWISE' GROUP BY inst_id ORDER BY inst_id;

-- What the sessions are waiting on: the interesting part
SELECT inst_id, event, COUNT(*) FROM gv$session
WHERE username = 'NESTWISE' AND wait_class != 'Idle'
GROUP BY inst_id, event ORDER BY 3 DESC;
```

### How to read the result honestly

Two very different outcomes, and they mean different things:

- **Latency climbs while `gv$session` stays flat at the pool ceiling** → you
  found the *connection pool* limit, not a database limit. Requests are queuing
  for a connection. That's a real and useful finding, and the fix is pool
  sizing, not SQL tuning.
- **Latency climbs and sessions climb, with non-idle waits appearing** → now
  you're actually stressing the database, and the wait events tell you where.

Label whichever you get accordingly. "1000 users, p95 held at X" is a very
different claim from "1000 users queued behind a 100-connection pool", and only
one of them is about the cluster.

## What to record

Per `loadtest/swingbench/workload_notes.md`, keep results in one combined table
rather than two disconnected reports. For each concurrency step record: requests
per second, p95 and p99 latency per transaction group, error rate, and the
`gv$session` distribution across both RAC instances.

The k6 summary gives you the first three directly; `--summary-export` writes them
as JSON so you can paste real numbers into `loadtest/swingbench/results.md`
rather than transcribing from a terminal.
