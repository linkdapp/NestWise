# Swingbench — concrete setup and run instructions

`workload_notes.md` covers *what to measure and why*. This file covers *how to
actually run it*, step by step.

## Correction to `workload_notes.md`

That file says the custom path is "a custom Swingbench XML (`sample_config.xml`)
with `Transaction` elements wrapping NestWise's actual queries." **That is not
how Swingbench works and would not run.** Verified against Dominic Giles'
own FAQ and the shipped distribution:

- The XML configures **connections, user counts, think time, and which
  transaction classes to run** — it cannot contain SQL statements.
- Custom transactions are **Java classes** extending `JdbcTaskImpl`, whose
  `execute()` method runs the JDBC calls and reports timing back to the
  framework via `processTransactionEvent()`. Source for all shipped
  transactions lives in `$SWINGHOME/source`, with an `ant` script to compile.
- The lighter-weight alternative Giles documents: Swingbench ships a "blank"
  benchmark that calls a **PL/SQL stored procedure** you can rewrite to contain
  your own transactions — no Java compilation, but you're writing PL/SQL
  instead of XML.

So the real choice is: write Java, write PL/SQL, or use a bundled benchmark.
Pick based on what question you're answering (below).

## Which path for which question

| Question you're answering | Use | Effort |
|---|---|---|
| "Are both RAC nodes taking load?" (`install.md` §9) | `loadtest/rac_session_check.sh` | ~1 min |
| "What's this cluster's general OLTP ceiling?" | Bundled **SOE** benchmark | ~30 min |
| "How fast are *NestWise's own* queries under load?" | Custom PL/SQL or Java benchmark | Hours |

Do them in that order. Most of the value for a showcase comes from the first
two; the third is worth doing only if you want NestWise-specific numbers in a
write-up, and it's genuinely a project, not a step.

---

## Path 1 — Install Swingbench

**Who:** The `oracle` account (or any account with a JDK and network access to
the SCAN listener)
**Where:** An app server or DB node — Swingbench is a client, it doesn't need
to run on the database host

```bash
# Swingbench needs a JDK (not just a JRE) if you'll compile custom transactions.
java -version    # confirm 11+ ; Swingbench 2.6/2.7 need Java 11 or later

cd /u01/app
# Download from dominicgiles.com/swingbench (the site gates direct wget with a
# click-through, so fetch the zip in a browser and scp it over if wget fails)
unzip swingbench*.zip
export SWINGHOME=/u01/app/swingbench
export PATH=$SWINGHOME/bin:$PATH
```

Confirm it runs at all before configuring anything:

```bash
$SWINGHOME/bin/charbench -h     # CLI runner, prints usage
```

Note there are three runners, and the docs mix them up freely:
- `charbench` — character/CLI mode, what you want for scripted runs
- `swingbench` — the Java Swing GUI (needs X forwarding)
- `oewizard` / `shwizard` — the schema **data generators** for SOE / SH

---

## Path 2 — SOE benchmark (the fast, real, zero-custom-code option)

This is the fastest way to get genuine Swingbench numbers and real RAC load. It
does **not** touch the NestWise schema — it builds its own `SOE` schema. Treat
the result as a *cluster ceiling reference*, not a NestWise result.

### Generate the SOE schema

**Who:** `oracle` (needs a DBA connection to create the schema)

```bash
$SWINGHOME/bin/oewizard \
  -cs //scan-usatclust1.usat.com:1521/apexdb_rw \
  -dba sys -dbap <sys_password> \
  -u soe -p <soe_password> \
  -ts SOE_DATA \
  -scale 1 \
  -cl -create
```

- `-scale 1` ≈ 1GB of data. Start here; a home lab does not need `-scale 100`.
- `-cl` = command line (no GUI). `-create` = create, don't just validate.
- Create the `SOE_DATA` tablespace first if it doesn't exist, or point `-ts` at
  an existing one.

### Run it

```bash
$SWINGHOME/bin/charbench \
  -c $SWINGHOME/configs/SOE_Server_Side_V2.xml \
  -cs //scan-usatclust1.usat.com:1521/apexdb_rw \
  -u soe -p <soe_password> \
  -uc 25 \
  -rt 0:05 \
  -min 100 -max 500 \
  -a -v users,tpm,tps,resp
```

- `-uc 25` — 25 concurrent users. Step this: 10 → 25 → 50 → 100, per
  `workload_notes.md`.
- `-rt 0:05` — run time 5 minutes.
- `-min`/`-max` — think time in ms.
- `-v users,tpm,tps,resp` — live output columns.
- `-a` — auto-start without waiting for a keypress.

**While it runs**, in a separate SQL session, this is where §9's question gets
answered properly:

```sql
SELECT inst_id, COUNT(*) FROM gv$session
WHERE username = 'SOE' GROUP BY inst_id ORDER BY inst_id;
```

Two rows with meaningful counts on both = RAC is genuinely load-balancing.
One row = check that you connected via the SCAN listener and that the service
is defined on both instances (`srvctl status service -d <db>`).

---

## Path 3 — NestWise-specific custom benchmark

Only worth doing for real NestWise numbers in a write-up. Two sub-options:

### 3a. PL/SQL route (lighter — no Java compilation)

Swingbench's shipped "blank"/simple benchmark calls a stored procedure. Rewrite
that procedure's body to call NestWise's real hot paths — the six transactions
already mapped in `workload_notes.md`'s table (`BrowseNeighborhoods`,
`FilterRestaurants`, `ToggleFavorite`, etc.), weighted by picking randomly
inside the procedure.

Caveat specific to this project: the `nbhd_pkg` / `restaurant_pkg` functions
return `SYS_REFCURSOR`, so the procedure must **fetch through** the cursor
(`FETCH ... BULK COLLECT INTO`), not just open it — otherwise you're
benchmarking cursor allocation, not the actual query. This is the same
`SYS_REFCURSOR` constraint every APEX region on this project has had to work
around, showing up in a third context.

### 3b. Java route (what Swingbench is actually designed for)

```bash
cd $SWINGHOME/source
# Copy an existing transaction as a template, e.g. one of the SOE ones
cp com/dom/benchmarking/swingbench/kernel/... MyNestWiseTx.java
# Edit: implement init() and execute(), call processTransactionEvent() on
# success and processTransactionEvent(failed) in the catch block
ant                      # compiles into $SWINGHOME/lib
```

Then reference the compiled class in a config XML copied from
`$SWINGHOME/configs/`, replacing the `<TransactionList>` entries with your own
class names and weights.

Budget real time for this — it's a Java project, not a config change.

---

## What to do with the numbers

Record results in `loadtest/swingbench/results.md` per `workload_notes.md`'s
format (transaction × avg × p95 × throughput, at each concurrency step), plus
the `gv$session` distribution at each step. One sentence on where the knee
appeared matters more than the absolute numbers — a 28-neighborhood demo schema
will plateau early, and that's expected, not a finding.
