---
layout: post
title: "Upgrading a Live RAC + Data Guard Pair Without Taking It Down: DBMS_ROLLING, Part 1"
date: 2026-08-22
categories: [oracle, ocm, dba]
tags: [dbms_rolling, autoupgrade, dataguard, rac, upgrade, oracle-linux]
---

# Maintenance — Part 1: DBMS_ROLLING, Software Prep Through SWITCHOVER

**SOP: 12.2.0.1 → 19c rolling upgrade of `apexdb`/`apexdb_stby` (2-node RAC + Data Guard, both clusters), on Oracle Linux 7**

Part 1 of 2. **Part 1 (this page)** covers getting the 19c software in place, `INIT_PLAN` through `SWITCHOVER` — the point where `apexdb_stby` becomes the new primary. [Part 2](part2-finish-plan-and-troubleshooting.md) covers `FINISH_PLAN`, the real troubleshooting behind it, and a pre-flight checklist worth running every time.

Status: 🟩 Confirmed through SWITCHOVER — real command/output evidence below for every step that has it.

| # | Section | Status |
|---|---|---|
| 1 | The problem, in plain terms | reference |
| 2 | Environment | reference |
| 3 | Before you start — pre-upgrade decisions and checks | 📋 Recommended — lessons learned, added retroactively |
| 4 | Getting the 19c software in place | 🟨 real commands shown, in the real order run |
| 5 | Stopping the Observer / disabling Fast-Start Failover | 🟩 Confirmed (2 real gaps found and fixed) |
| 6 | Step 1 — INIT_PLAN / BUILD_PLAN / START_PLAN | 🟨 real commands shown. |
| 7 | Step 2 — AutoUpgrade against the transient logical standby | 🟩 Confirmed |
| 8 | Step 3 — SWITCHOVER | 🟩 Confirmed, real output (2 real failures fixed) |

---

## 1. The problem, in plain terms

A normal Oracle version upgrade means downtime: stop the database, run the upgrade, bring it back. For a two-node RAC pair protecting a live application, that's not acceptable. `DBMS_ROLLING` (Oracle's rolling-upgrade package, built on Data Guard) avoids that by upgrading the *standby* first, promoting it to primary, then upgrading the old primary and folding it back in as the new standby — the application never loses a database to talk to, only a role swap. This is the same mechanism this project's Data Guard switchover already proved out ([high-availability Part 2](../high-availability/part2-broker-fsfo-observer.md)); `DBMS_ROLLING` adds the version-upgrade step on top of it.

Oracle's own documentation (*Using DBMS_ROLLING to Perform a Rolling Upgrade*, 19c Data Guard Concepts and Administration, Table 14-2) breaks the whole procedure into 5 steps, tracked live in `DBA_ROLLING_STATUS.PHASE`. Both parts of this write-up are organized around those 5 steps, in order:

| Step | Description | PHASE |
|---|---|---|
| Step 1 | Call `DBMS_ROLLING.START_PLAN` to configure the future primary and physical standbys designated to protect it. | START |
| Step 2 | Manually upgrade the Oracle Database software at the future primary database and standbys that protect it. | SWITCH PENDING |
| Step 3 | Call `DBMS_ROLLING.SWITCHOVER` to switch roles between the current and future primary database. | SWITCH |
| Step 4 | Manually restart the former primary and remaining standby databases on the higher version of Oracle Database. | FINISH PENDING |
| Step 5 | Call `DBMS_ROLLING.FINISH_PLAN` to convert the former primary to a physical standby, and configure remaining standbys for recovery of the upgrade redo. | FINISH |

Step 2's "manually upgrade the Oracle Database software" is where AutoUpgrade does the actual work in this project (§7). Steps 4-5 are [Part 2](part2-finish-plan-and-troubleshooting.md).

## 2. Environment

- **Primary cluster (`usatclust1`):** `oradbserv05`/`oradbserv06`, database `apexdb`
- **Standby cluster (`usatclust2`):** `oradbserv09`/`oradbserv10`, database `apexdb_stby`
- **Start:** Oracle Database 12.2.0.1, both databases
- **End:** Oracle Database 19c (19.3.0 base + RU 19.32.0.0.260721), both databases — `apexdb_stby` now primary, `apexdb` now physical standby
- **Orchestration:** Ansible, `dbms-rolling-execute.yml` → role `dbms_rolling_upgrade`, tag-gated (`rolling_init`, `rolling_build`, `rolling_start`, `rolling_autoupgrade`, `rolling_switchover`, `rolling_finish`, `rolling_status`)

## 3. Before you start — pre-upgrade decisions and checks

**Added retroactively, after the fact.** Nothing below was run as a discrete pre-flight pass in this project's own real history — it's the list I wish I'd had before starting, built from two sources: what Oracle actually documents as pre-upgrade practice, and the real gotchas this project hit later (§8, [Part 2](part2-finish-plan-and-troubleshooting.md) §6/§8) that would have been caught for free, early, instead of mid-`FINISH_PLAN`. Run these once the 19c software (§4) exists — some genuinely need it (AutoUpgrade itself), others don't and can be checked even sooner.

**1. Run `AutoUpgrade -mode analyze` against the CURRENT primary, before touching `DBMS_ROLLING` at all.** This is the single highest-value early check: Analyze mode is read-only — it "does not change your source database, it just reads from it" and is safe to run "during normal database operations" ([Oracle: Performing Preupgrade Checks Using AutoUpgrade](https://docs.oracle.com/en/database/oracle/oracle-database/21/upgrd/using-autoupgrade-utility-perform-checks.html)). It doesn't need `START_PLAN`, a transient logical standby, or anything `DBMS_ROLLING`-specific — just the 19c software and an AutoUpgrade config file pointed at `apexdb`, both already true once §4 is done. This project's actual `-mode analyze` run (§7) happened against `apexdb_stby` mid-procedure, as part of `rolling_autoupgrade` — running the same check against `apexdb` directly, early, costs nothing and surfaces the same class of blockers before any plan even exists.

**2. Query `DBA_ROLLING_UNSUPPORTED` — the `DBMS_ROLLING`-specific version of "do I have unsupported data."** This is the exact decision point worth making ahead of time, not during: it "displays the schemas, tables, and columns... that contain unsupported data types for a rolling upgrade operation for a logical standby database" ([Oracle: DBA_ROLLING_UNSUPPORTED](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_ROLLING_UNSUPPORTED.html)) — queue tables and certain other object types are the classic hits. Worth knowing: `DBMS_ROLLING.SET_PARAMETER`'s `BLOCK_UNSUPPORTED` option, which can auto-block writes to unsupported tables once a plan is active, is a 20c+ addition — not available on this project's 19c target, so on 19c this check is a manual, before-you-start decision, not something the database will enforce for you.

**3. Confirm zero `INVALID` objects before starting** — `select count(1) from dba_objects where status='INVALID';` against both databases, run `utlrp.sql` if it's not zero. Standard Oracle upgrade prerequisite, not `DBMS_ROLLING`-specific, but worth checking here since the transient logical standby phase (§7) adds SQL Apply as another consumer of the dictionary.

**4. Check the timezone (DST) file version on both sides — `SELECT version FROM v$timezone_file;`.** 19c ships timezone file version 32; if either database's current version is higher, the target `db19c_home` needs to be patched with a matching-version timezone data file *before* the upgrade, not after ([Oracle Support: Upgrade Failing on Timezone Upgrade](https://support.oracle.com/knowledge/Oracle%20Database%20Products/2916618_1.html), [dincosman.com: Oracle Database Time Zone (DST) Version](https://dincosman.com/2024/11/16/database-time-zone-upgrade/)). Worth a deliberate decision either way: AutoUpgrade applies the TZ file upgrade *after* the actual database upgrade, as a separate restart, and that pass can take real time if there's meaningful `TIMESTAMP WITH TIME ZONE` data — better to know that's coming than discover it as an unexplained extra restart.

**5. Decide the `COMPATIBLE` parameter strategy now, not mid-upgrade.** `COMPATIBLE` moves to `19.0.0` post-upgrade, but bumping it is a one-way door — once raised, a downgrade back to 12.2.0.1 is no longer possible. Worth deciding up front how long to run at the old `COMPATIBLE` value (keeping a downgrade path open) versus bumping immediately, rather than making that call in the moment.

**6. Confirm a real, tested backup exists before starting** — separate from AutoUpgrade's own automatic guaranteed restore point, and separate from [`roles/rolling_postupgrade`](../phase-01-foundation-2node-rac-12cR2/ansible/roles/rolling_postupgrade/tasks/main.yml)'s RMAN Level 0 backup (§10, [Part 2](part2-finish-plan-and-troubleshooting.md)) — that one runs *after* the whole upgrade completes, from the new standby. A pre-upgrade backup is a distinct, deliberate decision this project hasn't automated at all yet; make it by hand before starting until it is.

**7-8. Two checks that would have directly prevented this project's own real `FINISH_PLAN` failures** ([Part 2](part2-finish-plan-and-troubleshooting.md) §8) — genuinely worth promoting to a pre-upgrade check rather than a mid-upgrade surprise:

- **`LOG_ARCHIVE_DEST_STATE_n` for the standby-facing destination must not be `DEFERRED`, on both databases**, before starting. `SELECT dest_id, status, target FROM v$archive_dest WHERE target = 'STANDBY';` — this exact condition caused the first real ORA-45414 on `FINISH_PLAN`.
- **`tnsnames.ora` must actually exist and be populated under the *target* Oracle home's `network/admin`, on every node, before starting.** A freshly-installed Oracle home's `network/admin` is empty by default — this project's own `db19c_home` had no `tnsnames.ora` at all on `apexdb`'s nodes until it was caught the hard way. Check with a plain `cat {{ db19c_home }}/network/admin/tnsnames.ora` on every node, not just the ones already in active use.
- **Related trap worth knowing in advance, not discovering live:** manually `export ORACLE_HOME=...` does **not** move `TNS_ADMIN` with it. A connectivity test run this way can silently validate the *old* home's `tnsnames.ora`/`sqlnet.ora` while looking completely successful — confirm which files a test actually used via `tnsping`'s own "Used parameter files:" output line, not just its "OK" result.

## 4. Getting the 19c software in place

**Evidence note:** these are the real commands run, in the real order run — `upgrade-19c-rolling.yml`, not `dbms-rolling-execute.yml` (that playbook is `DBMS_ROLLING` itself, §6 onward; this is the safe groundwork ahead of it). What's still missing is a captured terminal transcript of these two tasks actually running; that isn't in the available session record. If you have it, it belongs here — paste it and this section gets upgraded from "commands" to "commands + proof," matching the rest of this page.

The actual staged plan, as run, step by step:

```bash
# 1. Optional — speeds up step 2's cross-cluster copy, safe to skip
ansible-playbook upgrade-19c-rolling.yml --tags cross_cluster_ssh_trust

# 2. Software-only install of patched 19c DB software on BOTH clusters — HA/FSFO untouched
ansible-playbook upgrade-19c-rolling.yml --tags db19c_stage,db19c_install_software

# 3. Disable FSFO — do this last, right before moving into the DBMS_ROLLING
#    steps below. This is the only step that drops automatic-failover
#    protection, so it sits as close as possible to when it's actually needed (§5).
ansible-playbook upgrade-19c-rolling.yml --tags rolling_fsfo_disable

# 4. INIT_PLAN
ansible-playbook dbms-rolling-execute.yml --tags rolling_init

# 5. BUILD_PLAN
ansible-playbook dbms-rolling-execute.yml --tags rolling_build

# safe anytime:
ansible-playbook dbms-rolling-execute.yml --tags rolling_status
```

Step 1 (`cross_cluster_ssh_trust`) sets up passwordless SSH from `oracle@oradbserv05` to `oracle@oradbserv09` — purely a speed optimization for step 2's cross-cluster software copy (direct `rsync` push instead of routing multi-GB files through the Ansible controller as a fallback). Entirely optional; `db19c_stage` works either way, just slower without it.

Steps 4 and 5 (`rolling_init`, `rolling_build`) are covered in full in §6 below — listed here too because this is genuinely where they sit in the real, as-run sequence: software staged, FSFO disabled, *then* `DBMS_ROLLING` starts.

Before any `DBMS_ROLLING` call, the 19c Oracle Database software has to exist on all four nodes, patched, separate from the still-in-use 12.2.0.1 home. `db19c_stage` confirms (and cross-cluster-copies if missing) three files onto each cluster's staging host: the 19c DB software zip, the 19.32 RU combo patch (`39467003` — the same combo already used for Grid Infrastructure), and the OPatch update zip — then extracts the software directly into `db19c_home` (`/u01/app/oracle/product/19.3.0/db_1`) and the RU into the shared patches directory. 19c's installer packaging changed from 12.2.0.1's: the zip's contents *are* the Oracle Home, no `database/` staging subfolder, so extraction target and install source are the same directory.

`db19c_install_software` checks the central inventory (`grep -q 'LOC="{{ db19c_home }}"' inventory.xml`) to skip a redundant install, updates OPatch in `db19c_home` before patching (the base 19.3.0 media ships OPatch 12.2.0.1.17; the RU's own sub-patches need up to 12.2.0.1.52), then runs the real install with the RU applied in the same pass — 18c+ installers support `-applyRU` directly, unlike 12.2.0.1's:

```bash

/u01/app/oracle/product/19.3.0/db_1/OPatch/opatch version

/u01/app/oracle/product/19.3.0/db_1/runInstaller -silent -waitforcompletion \
  -responseFile <staging>/response-files/db19c_install.rsp \
  -applyRU <staging>/patches/39467003

/u01/app/oracle/product/19.3.0/db_1/root.sh   # both nodes, each cluster


```

This runs twice — once against `rac_nodes` (`oradbserv05`/`06`), once against `standby_nodes` (`oradbserv09`/`10`) — two independent clusters, not one combined node list.

## 5. 🟩 Confirmed — Stopping the Observer / disabling Fast-Start Failover

Skipped in this write-up's first pass — worth its own stage, because it's a real prerequisite `DBMS_ROLLING` enforces, not busywork: Oracle's own `DBMS_ROLLING` documentation confirms the broker rejects any attempt to even *enable* Fast-Start Failover while a rolling upgrade is in progress. So FSFO has to come down first, and — per the real staged plan in §4 — as the *last* step before `INIT_PLAN`, not any earlier than it has to, since it's the only step in this whole sequence that drops automatic-failover protection.

```bash
ansible-playbook upgrade-19c-rolling.yml --tags rolling_fsfo_disable
```

`roles/rolling_upgrade_fsfo` wraps the existing `manage_observer.sh` script (predates this project's Ansible, already in place before this phase started) rather than reimplementing observer control, then handles the Broker-level `FastStartFailover` property directly via DGMGRL — same wallet-based, no-embedded-password `/@apexdb_DGMGRL` connect `roles/dataguard_fsfo` already set up.

**Two real gaps found on the first live run of this role, both fixed, not just noted:**

**Gap 1 — stopping the Observer process isn't the same as disabling FSFO.** `manage_observer.sh stop` only stops the Observer's background process. That's a genuinely different lever from the Broker's own `FastStartFailover` configuration property, which stays `Enabled` until something explicitly runs `DGMGRL> disable fast_start failover;`. The first real run of this role stopped the Observer correctly (`SHOW OBSERVER` went to "No observers.") — but a follow-up `show fast_start failover` still reported `Fast-Start Failover: Enabled in Zero Data Loss Mode`. Caught directly, fixed by hand with the DGMGRL disable, confirmed by a second `show fast_start failover` reporting `Disabled` — then folded into this role permanently, so it now reaches the real `DBMS_ROLLING` prerequisite on its own instead of stopping at an observer-stopped-but-FSFO-still-enabled state that *looks* done from `manage_observer.sh status` alone.

**Gap 2 — found immediately after fixing gap 1.** The first attempt at that fix matched the literal string `'Fast-Start Failover: Disabled'` (one space). Real DGMGRL output right-pads its label column, so the line reads `'Fast-Start Failover:  Disabled'` (two spaces) when the value is short, versus `'Fast-Start Failover: Enabled in Zero Data Loss Mode'` (one space) when it's long. A plain substring match on fixed spacing is fragile against DGMGRL's own column alignment — every check in this role now uses a whitespace-tolerant regex (`is search('Fast-Start Failover:\s+...')`) instead.

Confirmed disabled at the end of this role — `Fast-Start Failover: Disabled`, `SHOW OBSERVERS` reporting none — before `INIT_PLAN` (§6) runs. Re-enabling FSFO and restarting the Observer is a separate, later step, covered in [Part 2](part2-finish-plan-and-troubleshooting.md) §10.

## 6. Step 1 — INIT_PLAN / BUILD_PLAN / START_PLAN

**Same evidence note as §4:** the commands below are real (from the role and this project's own established conventions); no captured output for this specific step exists in the available session record.

```bash
ansible-playbook dbms-rolling-execute.yml --tags rolling_init
ansible-playbook dbms-rolling-execute.yml --tags rolling_build
ansible-playbook dbms-rolling-execute.yml --tags rolling_start
```

```sql
-- INIT_PLAN: designates apexdb_stby as the future primary
EXECUTE DBMS_ROLLING.INIT_PLAN(future_primary => 'apexdb_stby');

-- BUILD_PLAN: compiles and validates the plan against both databases

-- START_PLAN: converts apexdb_stby into a transient logical standby,
-- reduced to a single RAC instance
EXECUTE DBMS_ROLLING.START_PLAN();
```

`DBA_ROLLING_STATUS.PHASE` moves to `SWITCH PENDING` once `START_PLAN` completes — confirmed via `--tags rolling_status`, which is where the real evidence trail below picks back up.

## 7. 🟩 Confirmed — Step 2: AutoUpgrade against the transient logical standby

Oracle's Step 2 ("manually upgrade the Oracle Database software at the future primary") is done here via Oracle's AutoUpgrade utility, run against `apexdb_stby` only — the transient logical standby `START_PLAN` just created. `apexdb` itself is never touched at this step.

> **IMPORTANT — this specific step is NOT Oracle-documented for the exact
> DBMS_ROLLING/transient-logical-standby scenario.** Oracle's own 19c Data
> Guard docs say the transient logical standby's software upgrade is done
> "either manually or using the Database Upgrade Assistant (DBUA)" —
> AutoUpgrade is never named in that chapter. I chose AutoUpgrade
> anyway, knowingly, after a direct DBUA-vs-AutoUpgrade tradeoff discussion
> earlier in this project. What follows was cross-checked against Oracle's
> own official MAA deck ("Rolling Upgrades — Upgrade your DB with Zero
> Downtime", Francisco Munoz Alvarez, oraclemaa.com) and my own
> real-world reference notes, both incorporated below — not just the
> general AutoUpgrade command reference this was originally built from.

```bash
ansible-playbook dbms-rolling-execute.yml --tags rolling_autoupgrade
```

Real task sequence from the actual run (`PLAY RECAP: ok=75 changed=11 unreachable=0 failed=0 skipped=8`):

```
TASK [dbms_rolling_upgrade : Write SQL script: PREFLIGHT — check apexdb_stby's open_mode/role before AutoUpgrade (gv$database, all instances — observational only, does not require single-instance)] ***
TASK [dbms_rolling_upgrade : Run: PREFLIGHT open_mode/role check (gv$database, all instances)] *********************************************
ok: [oradbserv05 -> oradbserv09(192.168.56.184)]
TASK [dbms_rolling_upgrade : Show PREFLIGHT open_mode/role check output] *******************************************************************
ok: [oradbserv05] =>
  rolling_autoupg_preflight_check.stdout_lines:
  - ''
  - '   INST_ID OPEN_MODE                 DATABASE_ROLE'

TASK [dbms_rolling_upgrade : Run: AutoUpgrade -mode analyze (read-only readiness check) against apexdb_stby] *******************************
ok: [oradbserv05 -> oradbserv09(192.168.56.184)]
TASK [dbms_rolling_upgrade : Show AutoUpgrade analyze output (full — this is what the readiness report is built from)] *********************
ok: [oradbserv05] =>
  msg:
  - 'rc: 0'
  - - AutoUpgrade 25.6.251016 [...]

TASK [dbms_rolling_upgrade : Run: AutoUpgrade -mode deploy (the actual upgrade) against apexdb_stby — this is expected to take real time] ***
changed: [oradbserv05 -> oradbserv09(192.168.56.184)]
TASK [dbms_rolling_upgrade : Show AutoUpgrade deploy output (full)] ************************************************************************
ok: [oradbserv05] =>
  msg:
  - 'rc: 0'
  - - AutoUpgrade 25.6.[...]

TASK [dbms_rolling_upgrade : Show apexdb_stby's version/role/open_mode after AutoUpgrade] **************************************************
ok: [oradbserv05] =>
  rolling_stby_post_autoupgrade_check.stdout_lines:
  - ''
  - BANNER
  - '--------------------------------------------------------------------------------'
  - Oracle Database 19c Enterprise Edition Release 19.0.0.0.0 - Production

TASK [dbms_rolling_upgrade : Move apexdb_stby's CRS registration to the new 19c Oracle home] ***********************************************
changed: [oradbserv05 -> oradbserv09(192.168.56.184)]
TASK [dbms_rolling_upgrade : Show srvctl modify (new Oracle home) output] ******************************************************************
ok: [oradbserv05] =>
  msg: 'rc: 0'

PLAY RECAP *********************************************************************************************************************************
oradbserv05                : ok=75   changed=11   unreachable=0    failed=0    skipped=8    rescued=0    ignored=0
```

(The AutoUpgrade tool's own multi-page ANALYZE/DEPLOY console output sits between the task headers above — real, `rc: 0` both times, but too long to reproduce in full here.)

### What went wrong: ORA-45427, "Redo Apply process was not running"

This surfaced later, in `rolling_switchover`'s preflight (§8) — root cause traces back to this step, so it's documented here. `GV$LOGSTDBY_PROGRESS` (the view the health check read at the time) can show a stale progress/SCN-watermark row even after the apply engine has actually stopped — and AutoUpgrade's DEPLOY step bounces the instance, which stops Redo Apply. The stale row made the check conclude "already running" and skip restarting it; apply stayed silently stopped.

Diagnosed against a real, documented MOS note for this exact package/error:

```
DBMS Rolling Upgrade Switchover Fails with ORA-45427: Logical Standby Redo Apply Process Was Not Running
KB127726

Summary
DBMS rolling exec dbms_rolling.switchover fails with

LOGSTDBY id: XID 0x000x.0xx.000xxxx, hSCN 0x00000000xxxx, lSCN 0x00000000xxxxx, Thread 1, RBA 0x000xxx.00000xxxx.00xxx, txnHscn 0x00000000xxxxxx, LXID 0x000x.0xx.000xxxx, PID xxxx (AS01)

LOGSTDBY Apply process AS01 server id=<> pid=xxx OS id=xx stopped

ORA-26808: Apply process AS01 died unexpectedly.
ORA-24950: unregister failed, registration not found
ORA-06512: at "SYS.DBMS_AQ", line 1817
ORA-06512: at "SYS.DBMS_AQ", line 1906
Solution
1. Verify if there is a failed transaction on the logical standby:
ALTER SESSION SET NLS_DATE_FORMAT = 'DD-MON-YY HH24:MI:SS';
COLUMN STATUS FORMAT A60
SELECT EVENT_TIME, STATUS, EVENT FROM DBA_LOGSTDBY_EVENTS ORDER BY EVENT_TIMESTAMP, COMMIT_SCN, CURRENT_SCN;
SELECT EVENT,XIDUSN, XIDSLT, XIDSQN FROM DBA_LOGSTDBY_EVENTS WHERE EVENT_TIME = (SELECT MAX(EVENT_TIME) FROM DBA_LOGSTDBY_EVENTS);

2.If there are failed transactions, please skip the transactions
SQL>alter database start logical standby apply immediate skip failed transaction;
3. Retry the switchover.
```

The real `DBA_LOGSTDBY_EVENTS` query (320 rows) found no crash — the last real event was a clean "User initiated stop apply successfully completed", not an `ORA-26808` death. So the MOS note's `SKIP FAILED TRANSACTION` branch wasn't needed; a plain restart was correct:

```sql
ALTER DATABASE START LOGICAL STANDBY APPLY IMMEDIATE;
-- Database altered.
```

Confirmed via the alert log, tailed live:

```
oradbserv09-oracle-apexdb1$ tailalert
Tailing /u01/app/oracle/diag/rdbms/apexdb_stby/apexdb1/trace/alert_apexdb1.log
2026-08-22T20:39:52.515143-04:00
LOGMINER: Begin mining logfile for session 1 thread 1 sequence 120, +RECO01/APEXDB_STBY/foreign_archivelog/apexdb/2026_08_22/thread_1_seq_120.455.1241987143
2026-08-22T20:39:52.517531-04:00
LOGMINER: End   mining logfile for session 1 thread 1 sequence 120, +RECO01/APEXDB_STBY/foreign_archivelog/apexdb/2026_08_22/thread_1_seq_120.455.1241987143
2026-08-22T20:39:52.520556-04:00
LOGMINER: Begin mining logfile for session 1 thread 1 sequence 121, ...
```

LogMiner activity resuming, plus a follow-up `gv$database` check (`OPEN_MODE=READ WRITE`, `DATABASE_ROLE=LOGICAL STANDBY` on both instances) confirmed apply was genuinely back before retrying. Fixed at the source for future runs too: both the AutoUpgrade post-deploy check and `rolling_switchover`'s own preflight now read `GV$LOGSTDBY_STATE` instead of `GV$LOGSTDBY_PROGRESS` — only populated while SQL Apply is genuinely active, no stale-row risk.

## 8. 🟩 Confirmed — Step 3: SWITCHOVER (2 real failures, both fixed)

```bash
ansible-playbook dbms-rolling-execute.yml --tags rolling_switchover --syntax-check
```
```
sysadmin@usat_05:/mnt/d/github/Oracle-DBA-POC/phase-01-foundation-2node-rac-12cR2/ansible$ ansible-playbook dbms-rolling-execute.yml --tags rolling_switchover --syntax-check
playbook: dbms-rolling-execute.yml
sysadmin@usat_05:/mnt/d/github/Oracle-DBA-POC/phase-01-foundation-2node-rac-12cR2/ansible$
```

```bash
ansible-playbook dbms-rolling-execute.yml --tags rolling_switchover
```

**Failure 1 — the ORA-45427 above, hit again here** (this task's own preflight, before the `GV$LOGSTDBY_STATE` fix landed):

```
TASK [dbms_rolling_upgrade : PAUSE — about to call DBMS_ROLLING.SWITCHOVER(). This is the actual point of no return.] **********************
DBA_ROLLING_STATUS is READY/SWITCH PENDING and Redo Apply is running on apexdb_stby (checks above). About to run EXECUTE DBMS_ROLLING.SWITCHOVER(); against...
TASK [dbms_rolling_upgrade : Write SQL script: DBMS_ROLLING.SWITCHOVER] ********************************************************************
changed: [oradbserv05]
TASK [dbms_rolling_upgrade : Run: DBMS_ROLLING.SWITCHOVER — point of no return, apexdb_stby becomes the new primary] ***********************
ASYNC OK on oradbserv05: jid=j906650983463.20964
ok: [oradbserv05]
...
BEGIN DBMS_ROLLING.SWITCHOVER(); END;
  - ''
  - '*'
  - 'ERROR at line 1:'
  - 'ORA-45427: logical standby Redo Apply process was not running'
  - 'ORA-06512: at "SYS.DBMS_ROLLING", line 89'
  - 'ORA-06512: at line 1'
  - ''
  - ''
  - 'Elapsed: 00:00:00.79'
  - SQL> exit;
  - Disconnected from Oracle Database 12c Enterprise Edition Release 12.2.0.1.0 - 64bit Production
TASK [dbms_rolling_upgrade : Fail loudly if DBMS_ROLLING.SWITCHOVER looks like it failed (rc != 0 or ORA- in output) — verify against the real output above regardless] ***
fatal: [oradbserv05]: FAILED! => changed=false
  msg: DBMS_ROLLING.SWITCHOVER returned rc=0 and/or reported an ORA- error — read the full output above before doing anything else. Check DBA_ROLLING_STATUS/EVENTS (--tags rolling_status)...
PLAY RECAP *********************************************************************************************************************************
oradbserv05                : ok=15   changed=3    unreachable=0    failed=1    skipped=4    rescued=0    ignored=0
```

**Failure 2 — preflight rejected a legitimate retry.** After the apply restart above, `DBA_ROLLING_STATUS` correctly showed `STATUS=ERROR`, `PHASE=SWITCH` — a normal, documented resumable state. The original preflight, written for an exact `STATUS=READY`/`PHASE=SWITCH PENDING` match, rejected it outright:

```
TASK [dbms_rolling_upgrade : Fail loudly if the plan isn't STATUS=READY / PHASE=SWITCH PENDING — SWITCHOVER isn't the right next step yet] ***
fatal: [oradbserv05]: FAILED! => changed=false
  msg: DBA_ROLLING_STATUS shows STATUS='ERROR', PHASE='SWITCH' — expected STATUS='READY' and PHASE='SWITCH PENDING' before calling DBMS_ROLLING.SWITCHOVER. Run --tags rolling_status for the full DBA_ROLLING_STATUS/...
PLAY RECAP *********************************************************************************************************************************
oradbserv05                : ok=3    changed=0    unreachable=0    failed=1    skipped=1    rescued=0    ignored=0
```

`--tags rolling_status` confirmed the real, documented-resumable state directly against `DBA_ROLLING_EVENTS`:

```
Look at this:  --tags rolling_status

EVENTID EVENT_TIME                                                                  TYPE     MESSAGE                                                                    STATUS     INSTID   REVISION
---------- --------------------------------------------------------------------------- -------- ---------------------------------------------------------------------- ---------- ---------- ----------
        77 22-AUG-26 13:43:58                                                          INFO     initialized metadata                                                            0          0          0
        78                                                                             INFO     initialized new plan
        ...
       117 22-AUG-26 20:25   ...  ERROR    DBMS_ROLLING.SWITCHOVER halted due to error                                 45427          0          1
41 rows selected.
```

Fixed by loosening the preflight to accept the real, documented range of legitimate values — `PHASE` matched by prefix (`is match('SWITCH')`, covering both `SWITCH PENDING` and a resumable bare `SWITCH`) and `STATUS` in `['READY', 'ERROR']`.

**Retry — succeeded, full real output:**

```
TASK [dbms_rolling_upgrade : Notify — Redo Apply confirmed running on apexdb_stby, ready for SWITCHOVER] ***********************************
ok: [oradbserv05] =>
  msg: GV$LOGSTDBY_STATE confirms an active Redo Apply process on apexdb_stby (apexdb1 on oradbserv09).
TASK [dbms_rolling_upgrade : PAUSE — about to call DBMS_ROLLING.SWITCHOVER(). This is the actual point of no return.] ***********************
TASK [dbms_rolling_upgrade : Run: DBMS_ROLLING.SWITCHOVER — point of no return, apexdb_stby becomes the new primary] ***********************
ASYNC POLL on oradbserv05: jid=j982246252907.9321 started=1 finished=0
ASYNC POLL on oradbserv05: jid=j982246252907.9321 started=1 finished=0
ASYNC OK on oradbserv05: jid=j982246252907.9321
changed: [oradbserv05]
TASK [dbms_rolling_upgrade : Show DBMS_ROLLING.SWITCHOVER output] **************************************************************************
ok: [oradbserv05] =>
  rolling_switchover_result.stdout_lines:
  - ''
  - 'SQL*Plus: Release 12.2.0.1.0 Production on Sat Aug 22 20:49:48 2026'
  - ''
  - Copyright (c) 1982, 2016, Oracle.  All rights reserved.
  - ''
  - ''
  - 'Connected to:'
  - Oracle ...
TASK [dbms_rolling_upgrade : Fail loudly if DBMS_ROLLING.SWITCHOVER looks like it failed (rc != 0 or ORA- in output) — verify against the real output above regardless] ***
skipping: [oradbserv05]
TASK [dbms_rolling_upgrade : Show apexdb_stby's role after SWITCHOVER (expect PRIMARY)] ****************************************************
ok: [oradbserv05] =>
  rolling_switchover_post_check_stby.stdout_lines:
  - ''
  - '   INST_ID INSTANCE_NAME   HOST_NAME            STATUS       DATABASE_ROLE      OPEN_MODE'
  - '---------- --------------- -------------------- ------------ ------------------ ------------------'
  - '         1 apexdb1         oradbserv09.usat.com OPEN         PRIMARY            READ WRITE'
  - '         2 apexdb2         oradbserv10.usat.com OPEN         PRIMARY            READ WRITE'
TASK [dbms_rolling_upgrade : Fail loudly if apexdb_stby is not reporting PRIMARY after SWITCHOVER] *****************************************
skipping: [oradbserv05]
TASK [dbms_rolling_upgrade : Show apexdb's (former primary) state after SWITCHOVER] ********************************************************
ok: [oradbserv05] =>
  rolling_switchover_post_check_primary.stdout_lines:
  - ''
  - '   INST_ID OPEN_MODE          DATABASE_ROLE'
  - '---------- ------------------ ------------------'
  - '         1 READ WRITE         LOGICAL STANDBY'
  - '         2 READ WRITE         LOGICAL STANDBY'
TASK [dbms_rolling_upgrade : Notify — SWITCHOVER complete. apexdb_stby is now PRIMARY. Next step is --tags rolling_finish (DBMS_ROLLING.FINISH_PLAN), not yet built] ***
ok: [oradbserv05] =>
  msg: 'apexdb_stby is confirmed PRIMARY (see above). DBMS_ROLLING.ROLLBACK_PLAN is no longer available from this point forward. Next...'
PLAY RECAP *********************************************************************************************************************************
oradbserv05                : ok=30   changed=6    unreachable=0    failed=0    skipped=15   rescued=0    ignored=0
```

`apexdb_stby` is confirmed **PRIMARY** on both instances (`OPEN`/`READ WRITE`). `apexdb` is confirmed **LOGICAL STANDBY** on both instances, still on 12.2.0.1 — `DBMS_ROLLING.ROLLBACK_PLAN` is no longer available from this point forward; the only way through is [Part 2](part2-finish-plan-and-troubleshooting.md), `FINISH_PLAN`.

---

Continue to **[Part 2 — FINISH_PLAN, Troubleshooting, and the Pre-Flight Checklist](part2-finish-plan-and-troubleshooting.md)**.
