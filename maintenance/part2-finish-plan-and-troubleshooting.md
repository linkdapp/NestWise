---
layout: post
title: "Upgrading a Live RAC + Data Guard Pair Without Taking It Down: DBMS_ROLLING, Part 2"
date: 2026-08-22
categories: [oracle, ocm, dba]
tags: [dbms_rolling, dataguard, rac, upgrade, troubleshooting, srvctl, oracle-linux]
---

# Maintenance — Part 2: FINISH_PLAN, Troubleshooting, and the Pre-Flight Checklist

**SOP: 12.2.0.1 → 19c rolling upgrade of `apexdb`/`apexdb_stby` (2-node RAC + Data Guard, both clusters), on Oracle Linux 7**

Part 2 of 2. [Part 1](part1-dbms-rolling-plan-to-switchover.md) covers `INIT_PLAN` through `SWITCHOVER` — read that first if you're starting fresh; this page assumes `apexdb_stby` is already confirmed primary and `apexdb` is a logical standby, still on 12.2.0.1. This page covers the last step, `FINISH_PLAN`, and the real troubleshooting behind getting there — most of which a 60-second pre-flight check (§7 below) would have avoided.

Status: 🟩 Confirmed — `FINISH_PLAN` completed successfully; `apexdb` is now a physical standby of `apexdb_stby`, both on 19c.

| # | Section | Status |
|---|---|---|
| 6 | The FINISH_PLAN prerequisite: remounting the former primary | 🟩 Confirmed (3 real failures fixed) |
| 7 | **Pre-flight checklist — run this before FINISH_PLAN** | reference — do this every time |
| 8 | FINISH_PLAN itself, and the ORA-45414 root cause | 🟩 Confirmed (2-part root cause) |
| 9 | Final confirmation and cleanup | 🟩 Confirmed |
| 10 | **Post-upgrade procedure — restoring normal operations** | 🟩 Confirmed (researched, real state shown) |
| 11 | Why this matters for an OCM-level DBA | reference |

---

## 6. 🟩 Confirmed — The FINISH_PLAN prerequisite: remounting the former primary

Oracle's own documentation (*Using DBMS_ROLLING to Perform a Rolling Upgrade*, 19c Data Guard Concepts and Administration, Table 14-2) is explicit that this is two separate steps, in order:

| Step | Description | PHASE |
|---|---|---|
| Step 4 | Manually restart the former primary and remaining standby databases on the higher version of Oracle Database. | FINISH PENDING |
| Step 5 | Call `DBMS_ROLLING.FINISH_PLAN` to convert the former primary to a physical standby. | FINISH |

> "You must manually restart and mount the former primary and remaining standby databases on the higher version of Oracle Database. Mounting the standby databases is especially important because the `DBMS_ROLLING` package needs to communicate with the standby database to continue the rolling upgrade."

In plain terms: `apexdb`'s 19.3.0 software was already installed on disk (a separate, earlier groundwork phase), but its CRS registration still pointed at the 12.2.0.1 home. Step 4 is stop → move the CRS registration → restart mounted on 19c. `FINISH_PLAN` itself can't do this remotely; it needs `apexdb` already reachable on the higher version first.

**Failure 1 — PRCT-1402 / PRKC-1137.** First attempt ran the CRS-home move with the *old* (12.2.0.1) `srvctl` binary:

```bash
srvctl modify database -db apexdb -oraclehome /u01/app/oracle/product/19.3.0/db_1
# PRCT-1402 : Attempt to retrieve version of SRVCTL from Oracle Home .../19.3.0/db_1/bin failed.
# PRKC-1137 : Unable to find Version object with string value 19.0.0.0.0
```
The old binary can't parse the new home's version-reporting format.

**Failure 2 — PRCD-1229.** Second attempt switched to the *new* home's `srvctl`, by analogy with an earlier, working CRS-home move done for `apexdb_stby`:

```bash
/u01/app/oracle/product/19.3.0/db_1/bin/srvctl modify database -db apexdb -oraclehome /u01/app/oracle/product/19.3.0/db_1
# PRCD-1229 : An attempt to access configuration of database apexdb was rejected because its
# version 12.2.0.1.0 differs from the program version 19.0.0.0.0. Instead run the program
# from /u01/app/oracle/product/12.2.0/db_1.
```
Root cause: `srvctl modify database -oraclehome` enforces that the *calling* program's version match the database's *currently registered* version — a check that can never pass when the entire point of the call is to change that registered version. No choice of binary fixes it; `modify` is the wrong subcommand for a cross-major-version move. The correct one, confirmed against Oracle's own SRVCTL reference and a real, independently-documented case of this exact error:

```bash
/u01/app/oracle/product/19.3.0/db_1/bin/srvctl upgrade database -db apexdb -oraclehome /u01/app/oracle/product/19.3.0/db_1
```
`srvctl upgrade database` exists specifically to move a database's CRS registration across a major version, and is invoked from the *target* home — this succeeded.

**Failure 3 — the same PRCD-1229 recurred, on a different task, on a resumed run.** After a later, unrelated failure (§8 below) forced a retry, the "stop apexdb" step — which still hardcoded the *old* home — hit PRCD-1229 again, in the opposite direction, because `apexdb`'s registration had *already* moved to 19c on the prior attempt:

```
PRCD-1229 : ... its version 19.0.0.0.0 differs from the program version 12.2.0.1.0.
Instead run the program from /u01/app/oracle/product/19.3.0/db_1.
```
The fix for Failure 2 had only been applied at one call site, not generalized. A first attempt at fixing this properly — discovering the currently-registered home by grepping `/etc/oratab` — was also wrong: RAC oratab entries aren't reliably keyed by per-instance SID, and CRS-managed databases don't depend on oratab for startup at all, so the grep found nothing. The actual fix: ask CRS directly instead of trusting a file that can silently drift out of sync. Probe with `srvctl config database` from the new home — a clean return means the database is already on 19c; a PRCD-1229 response means it's still on the old home, and the error text itself names the correct one:

```bash
/u01/app/oracle/product/19.3.0/db_1/bin/srvctl config database -d apexdb
# Success -> already on 19c. PRCD-1229 -> still on the old home (message names it).
```
This is now the standing pattern anywhere this project needs to know which Oracle Home a database is really registered under — authoritative, OCR-backed, and immune to a hand-edited file disagreeing with reality (which is exactly what happened here: a manual oratab "fix" was tried mid-troubleshooting and was later proven wrong by this same probe).

---

## 7. Pre-flight checklist — run this before FINISH_PLAN

**This is the part worth bookmarking.** Both real failures in §8 below trace back to configuration that's easy to check up front and easy to miss until `FINISH_PLAN` fails on it. Run all three, on the current primary (`apexdb_stby`) and on the former primary's new Oracle Home, *before* calling `FINISH_PLAN` — not after it fails.

**1. Is the standby-facing archive destination deferred?** On the current primary, after any switchover, whichever `LOG_ARCHIVE_DEST_n` targets the former primary can be left `DEFERRED`. `FINISH_PLAN` needs a live two-way connection between the two databases, not just one-way reachability — a deferred destination blocks its own return leg.

```sql
SELECT dest_id, destination, status, target FROM v$archive_dest WHERE target = 'STANDBY';
-- STATUS should be VALID/ENABLE, not DEFERRED
```
If it's deferred:
```sql
ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_<n>=ENABLE SCOPE=BOTH;
```

**2. Does `LOG_ARCHIVE_DEST_n` actually point at the right place?**

```sql
SHOW PARAMETER log_archive_dest_2
SHOW PARAMETER log_archive_config
-- log_archive_config should list BOTH db_unique_names, e.g. dg_config=(apexdb,apexdb_stby)
```

**3. Does the target Oracle Home's `network/admin` actually have the TNS entries it needs?** If the former primary is starting under a freshly-installed Oracle Home for the first time (true here — the 19c home was installed well before this upgrade, but `apexdb`'s instance never actually ran under it until this step), its `network/admin` may simply be empty. A fresh software install does not carry over another home's `tnsnames.ora`/`listener.ora`.

```bash
cat $NEW_ORACLE_HOME/network/admin/tnsnames.ora
```

**A trap worth knowing about while checking #3:** manually exporting `ORACLE_HOME` in an existing shell does **not** move `TNS_ADMIN` with it. Every interactive connectivity test run during this troubleshooting (`tnsping`, `sqlplus sys@alias`) kept resolving through the *old* home's `sqlnet.ora` regardless of which `ORACLE_HOME` had been exported, because `TNS_ADMIN` was inherited from the login shell and never independently reset — every one of those tests looked reassuring and was actually validating the wrong file. The only reliable check is reading the target home's `network/admin` directly, as above — not a connection test run from an ordinary shell.

---

## 8. 🟩 Confirmed — FINISH_PLAN itself, and the ORA-45414 root cause

```bash
ansible-playbook dbms-rolling-execute.yml --tags rolling_finish
```

First real attempt, after `apexdb` was confirmed mounted on 19c:

```sql
EXECUTE DBMS_ROLLING.FINISH_PLAN();
-- ERROR at line 1:
-- ORA-45414: could not connect to a remote database
-- ORA-06512: at "SYS.DBMS_ROLLING", line 36
```

`DBA_ROLLING_EVENTS` on `apexdb_stby` (queryable there, not on `apexdb`, which is intentionally mounted-only at this point) told the real story in order:

```
opened outbound connection to apexdb          -- 0, success
initialized outbound agent for apexdb         -- 0, success
failed to open inbound connection from apexdb -- 45414, the actual failure
DBMS_ROLLING.FINISH_PLAN halted due to error  -- 45414
```

`apexdb_stby`'s outbound leg to `apexdb` worked. `apexdb`'s own return leg back failed — exactly the two-part root cause the checklist above exists to catch:

1. `v$archive_dest` on `apexdb_stby` showed the standby-facing destination (`apexdb_dgmgrl`, `TARGET=STANDBY`) as `STATUS=DEFERRED`.
2. `apexdb`'s new Oracle Home had no `tnsnames.ora` at all:

```
$ cat /u01/app/oracle/product/19.3.0/db_1/network/admin/tnsnames.ora
cat: /u01/app/oracle/product/19.3.0/db_1/network/admin/tnsnames.ora: No such file or directory
```
(confirmed on both `oradbserv05` and `oradbserv06` — not a one-node fluke)

**Fixes:**
- Enabling the deferred destination was automated: a task that self-discovers any `STANDBY`-target destination left `DEFERRED` (not hardcoded to a specific `dest_id`, since that number isn't guaranteed stable) and re-enables it via dynamic PL/SQL, followed by a verification query that fails loudly if anything's still deferred.
- The missing `tnsnames.ora` was copied over from the old home's `network/admin` into the new home's, on both `apexdb` nodes.

**Retry — succeeded:**

```sql
EXECUTE DBMS_ROLLING.FINISH_PLAN();
-- PL/SQL procedure successfully completed.
-- Elapsed: 00:02:19.66
```

## 9. 🟩 Confirmed — Final confirmation and cleanup

Not trusting the "successfully completed" message alone — the actual roles, checked directly:

```sql
-- apexdb, post-FINISH_PLAN
SELECT instance_name, status, database_role, open_mode FROM gv$instance JOIN gv$database ...;
--  apexdb1  MOUNTED  PHYSICAL STANDBY  MOUNTED
--  apexdb2  MOUNTED  PHYSICAL STANDBY  MOUNTED

-- apexdb_stby, post-FINISH_PLAN (sanity check — should be unchanged)
--  inst 1   READ WRITE   PRIMARY
--  inst 2   READ WRITE   PRIMARY
```

The 12.2.0.1 → 19c rolling upgrade is complete: `apexdb_stby` is primary, `apexdb` is a physical standby, both on 19.32.0.0.0 — confirmed with zero required downtime for anything reading/writing against the pair throughout (the only unavailability was `apexdb` itself while it was down for its own CRS-home move, and it was never serving as primary during that window).

`oracle`'s `.bash_profile` `DB_HOME` was then updated to the 19c home on all four nodes (`oradbserv05/06/09/10`), with a backup of each original file kept alongside it. Already-open shells need `. ~/.bash_profile` or a fresh login to pick it up.

**Deliberately left undone, not forgotten:** `DBMS_ROLLING.DESTROY_PLAN` (purges this plan's tracked state, run manually once nothing further needs it — same treatment as `ROLLBACK_PLAN` throughout this project, a human decision, not something automated blindly) and the AutoUpgrade-created guaranteed restore point on `apexdb_stby` (`DROP RESTORE POINT ...`, once confident that standalone upgrade step will never need to be flashed back).

## 10. Post-upgrade procedure — restoring normal operations

`FINISH_PLAN` finishes the *rolling upgrade*; it doesn't restore this pair to how this project normally runs it. Confirmed live, right after `FINISH_PLAN` completed:

```
SQL> select name,open_mode,database_role from v$database;
NAME      OPEN_MODE            DATABASE_ROLE
--------- -------------------- ----------------
APEXDB    MOUNTED              PHYSICAL STANDBY

SQL> srvctl config database -d apexdb -verbose
...
Start options: mount
Management policy: MANUAL
...
```

`apexdb` sitting `MOUNTED` with `Management policy: MANUAL` is expected, not a problem — that's exactly the state the `rolling_finish` remount work (§6) deliberately put it in, and it matches Oracle's own whitepaper on this procedure (*Automated Database Upgrades using Oracle Active Data Guard and DBMS_ROLLING*, Dec 2017), whose own walkthrough ends its last numbered step the same way:

```
11. Primary is mounted with apply running
SQL> select database_role,open_mode from v$database;
DATABASE_ROLE OPEN_MODE
---------------- --------------------
PHYSICAL STANDBY MOUNTED
SQL> select status from v$managed_standby where process='MRP0';
STATUS
------------
APPLYING_LOG
```

**Worth being precise about:** Oracle's own DBMS_ROLLING documentation and whitepaper stop exactly there — `MOUNTED` with apply running is a complete, correct end state as far as `DBMS_ROLLING` itself is concerned. Everything below this point is *this project's own* operational standard (this pair has always run Active Data Guard, role-based services, and Fast-Start Failover — see [high-availability](../high-availability/README.md)), not something `FINISH_PLAN` or Oracle's docs require. Six real steps, verified against Oracle's own documentation and this project's established conventions rather than assumed:

**1. Disable supplemental logging.** The one genuinely required cleanup step Oracle's own whitepaper documents by name — `DBMS_ROLLING` enables supplemental logging for the logical-standby phase and leaves it on; it doesn't turn itself off:

```sql
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (UNIQUE) COLUMNS;
ALTER DATABASE DROP SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS;
ALTER DATABASE DROP SUPPLEMENTAL LOG DATA (UNIQUE) COLUMNS;
ALTER DATABASE DROP SUPPLEMENTAL LOG DATA;
```
(The ADD-then-DROP pairing is the whitepaper's own idiom — it guarantees something is actually enabled to drop, rather than risking an error dropping a logging level that was never on.)

**2. Reset the CRS management policy back to AUTOMATIC**, on `apexdb` (undoing `rolling_finish`'s own deliberate `MOUNT`/`MANUAL` override — needed during `FINISH_PLAN`'s multi-hour wait, not needed anymore) and confirmed on `apexdb_stby` too:

```bash
srvctl modify database -db apexdb -policy automatic
srvctl modify database -db apexdb_stby -policy automatic
```

**3. Open `apexdb` read-only with Redo Apply running** — Active Data Guard, matching how `apexdb_stby` has run since [high-availability Part 1](../high-availability/part1-active-data-guard.md), not a `DBMS_ROLLING` requirement:

```sql
ALTER DATABASE OPEN READ ONLY;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT;
```

**4. Test it — a few log switches, confirm applied**, exactly as asked:

```sql
-- On apexdb_stby (primary)
ALTER SYSTEM SWITCH LOGFILE;

-- On apexdb (standby), repeat a couple of times, confirm sequence# advancing and APPLIED=YES
SELECT sequence#, applied FROM v$archived_log ORDER BY sequence# DESC FETCH FIRST 5 ROWS ONLY;
```

**5. Check role-based services.** `apexdb_rw` belongs on the current primary (`apexdb_stby`), `apexdb_ro` on the current standby (`apexdb`) — same convention as [high-availability Part 1 §13](../high-availability/part1-active-data-guard.md):

```bash
srvctl status service -d apexdb_stby
srvctl status service -d apexdb
```

**6. Re-enable Fast-Start Failover.** This project's own convention (`group_vars/all.yml`) states plainly that FSFO had to be fully disabled before `DBMS_ROLLING.BUILD_PLAN` — "the broker rejects any attempt to even ENABLE fast-start failover while a rolling upgrade is in progress." Now that the upgrade is done, re-enable it the same way [high-availability Part 2](../high-availability/part2-broker-fsfo-observer.md) originally did:

```
DGMGRL> enable fast_start failover;
DGMGRL> show fast_start failover;
DGMGRL> show observers;
```

**Automated as of this writing.** The six steps above are now real Ansible — `roles/rolling_postupgrade`, run via a new top-level playbook:

```bash
ansible-playbook rolling-postupgrade.yml --tags rolling_postupgrade
```

It covers steps 1-5 against `rac_node1` (delegate_to per database, same pattern as `dbms_rolling_upgrade` itself), reuses `dataguard_switchover_test` unmodified for the actual role flip back to `apexdb`=PRIMARY, re-normalizes `apexdb_stby` the same way once it's standby again, then re-enables FSFO against `oemserver01` in a second play by re-running `dataguard_fsfo` wholesale (every task in it already checks "already enabled/running, skip" — safe to just run again). It also adds one step Oracle's whitepaper and this project's earlier post-upgrade notes didn't cover: an RMAN Level 0 backup of `apexdb_stby`, taken from the standby to keep the I/O off the primary, to `/media/sf_hrman/rman_backups/apexdb1` — compressed backupset, controlfile autobackup on, backup optimization on, redundancy-2 retention, `PLUS ARCHIVELOG` without deleting input (a physical standby's archivelogs aren't this job's call to purge), and a `CROSSCHECK` + `RESTORE DATABASE VALIDATE` pass so the backup is verified, not just taken. Narrower tags (`rolling_postupgrade_normalize`, `rolling_postupgrade_switchback`, `rolling_postupgrade_renormalize`, `rolling_postupgrade_backup`, `rolling_postupgrade_fsfo`) are available if only part of this needs to run.

This hasn't been run for real against the lab yet — per this page's own standard, the actual command/output evidence gets added here once it has, not before.

**On AutoUpgrade `-mode postfixups`:** checked against Oracle's own AutoUpgrade documentation before recommending it either way — `postfixups` mode exists to run post-upgrade fixups *separately*, specifically when AutoUpgrade was **not** run in `deploy` mode, or when Replay Upgrade was used. Neither applies here: `rolling_autoupgrade` (Part 1 §5) already ran a full `-mode deploy`, confirmed `rc: 0` in the real captured output. Fixups are part of what `deploy` mode already does. Running `postfixups` again isn't expected to be necessary — worth confirming against the AutoUpgrade job's own summary/log before spending time on it, rather than running it defensively on the assumption it's required.

Already covered in §9 above and still the right call: `DBMS_ROLLING.DESTROY_PLAN` and dropping the AutoUpgrade guaranteed restore point are separate, deliberate, human-triggered decisions — not part of this list.

## 11. Why this matters for an OCM-level DBA

Anyone can follow a checklist when nothing goes wrong. What actually separates OCM-level troubleshooting from guesswork here: every fix in this page traces to a *specific, checked* piece of evidence — a real error code looked up against Oracle's own reference, a dictionary view queried before concluding what state something was actually in, a file read directly instead of trusting an indirect test. The `TNS_ADMIN`-doesn't-follow-`ORACLE_HOME` trap in particular is the kind of thing that costs hours precisely because every individual test *looks* like it passed. Rolling upgrades, resumability, and CRS-registration mechanics are squarely on the OCM practical blueprint's database/network configuration and high-availability areas — and a hiring manager reading this gets to see the actual debugging trail, not just the final green checkmark.

---

Back to **[Part 1 — INIT_PLAN through SWITCHOVER](part1-dbms-rolling-plan-to-switchover.md)**.
