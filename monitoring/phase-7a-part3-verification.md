# Phase 7a — Part 3: Datapatch, Verification and Aftermath

**SOP: `oemcdb` on `oemserver01` — Combo 39618649 (Database RU 39472050 + OJVM 39222882), 19.19.0.0.0 → 19.32.0.0.0, Oracle Linux**

Part 3 of 3. [Part 1](phase-7a-part1-before-the-window.md) covers the
prerequisites and staging; [Part 2](phase-7a-part2-the-patch-window.md) is the
destructive run through the apply. **Part 3 (this page)** covers datapatch,
`extjob`, bringing Enterprise Manager back, the verification checklist against
the real run, the rollback procedure, what is still outstanding, and the
screenshot checklist. The index is
[`phase-7a-repository-db-ru32.md`](phase-7a-repository-db-ru32.md).

Status: 🟩 Confirmed — `19.32.0.0.0`, invalid objects 2 → 0, targets 43 → 43,
`failed=0`.

| # | Section | Status |
|---|---|---|
| 13 | Datapatch, the step people forget | 🟩 Confirmed |
| 14 | `extjob`, and two things left manual | 🟩 Confirmed |
| 15 | Bring Enterprise Manager back | 🟩 Confirmed |
| 16 | Verification checklist | 🟩 Confirmed (13 of 15 rows; 2 outstanding, §18) |
| 17 | Rollback, if verification fails | ⬜ Not needed |
| 18 | Aftermath — what is still outstanding | 🟨 Two items open |
| 19 | Screenshot checklist and naming convention | 🟩 Confirmed |

Screenshots referenced below are in [`screenshots/`](screenshots/) — same naming
convention as `installation/`'s Section 15, numbered to match this page's own
section numbers (13, 15, 16).

---

## Contents

13. [Datapatch, the step people forget](#13-datapatch-the-step-people-forget)
14. [`extjob`, and two things left manual](#14-extjob-and-two-things-left-manual)
15. [Bring Enterprise Manager back](#15-bring-enterprise-manager-back)
16. [Verification checklist](#16-verification-checklist)
17. [Rollback, if verification fails](#17-rollback-if-verification-fails)
18. [Aftermath — what is still outstanding](#18-aftermath--what-is-still-outstanding)
19. [Screenshot checklist and naming convention](#19-screenshot-checklist-and-naming-convention)

Back to **[Part 2 — The patch window](phase-7a-part2-the-patch-window.md)**.

---

## 13. Datapatch, the step people forget

`opatch apply` patches the binaries. It does **not** modify the database
dictionary. `datapatch` does, and skipping it leaves a database running patched
binaries against an unpatched dictionary.

**Who:** `oracle`
**Where:** `oemserver01`

### 13.1 Start the database — and open the PDBs if this is a CDB

Oracle's README §3.3.2 gives **two** procedures in its Table 2, and the difference
is one line. The multitenant column has a step the non-CDB column does not:

```sql
SQL> ALTER PLUGGABLE DATABASE ALL OPEN;
```

Miss it on a CDB and `datapatch` patches `CDB$ROOT` plus whichever PDBs happened
to be open, leaving any closed PDB on an unpatched dictionary. Nothing warns you.
It surfaces later, when that PDB is opened or unplugged.

**This repository database is a non-CDB**, confirmed rather than inferred:

```sql
SQL> SELECT cdb FROM v$database;

CDB
---
NO
```

So the non-CDB column applies and a plain `STARTUP` is correct.

```bash
sqlplus / as sysdba <<'SQL'
SET TAB OFF TRIMSPOOL ON LINESIZE 200 PAGESIZE 200
STARTUP
-- CDB only:
-- ALTER PLUGGABLE DATABASE ALL OPEN;
-- SELECT name, open_mode FROM v$pdbs ORDER BY name;
SELECT status FROM v$instance;
EXIT
SQL
```

> **The database is called `OEMCDB` and is not a CDB.** A name that will mislead
> the next person who reads it, including you in six months. That naming is
> exactly why this was checked rather than inferred, and why the branch stays in
> the role permanently instead of being replaced by a variable now that the answer
> is known: Phase 7d converts this database, and the day it does, the branch has
> to already be there.

### 13.2 Sanity checks, then datapatch

```bash
cd $ORACLE_HOME/OPatch
./datapatch -sanity_checks
./datapatch -verbose
```

![Ansible task "Show datapatch sanity check output": SQL Patching sanity checks version 19.32.0.0.0, a long list of Check results all OK — Database component status, PDB Violations, Invalid System Objects, Tablespace Status, Backup jobs, Data Pump running, Oracle Database Keystore, Dictionary statistics gathering, GoldenGate triggers, Logminer DDL triggers, Statistics gathering, Symlinks on oracle home path, Central Inventory, Java Virtual Machine Enable, Oracle Database Vault Enabled, Queryable Inventory checks, Imperva, Guardium, Locale — with a single "Check: Scheduled Jobs - WARNING" listing four scheduled SYS and SYSMAN jobs](screenshots/13a-datapatch-sanity-checks.png)

`-sanity_checks` reports **graded findings** — whether conditions are right for
patching — rather than a pass/fail. Oracle's README calls it optional in one
sentence and says *"Oracle highly recommends that you perform this step"* in the
next. Run it, run it **before** `-verbose` where its findings are still
actionable, and read the output.

**Everything came back OK except one WARNING**, and that one is benign here:

| Finding | Verdict |
|---|---|
| `Scheduled Jobs - WARNING` — four jobs scheduled to run within the hour (`SYS.CLEANUP_NON_EXIST_OBJ`, `SYS.CLEANUP_TRANSIENT_TYPE`, `SYSMAN.EM_EVENT_PROC_FAILURE_HANDLING`, `SYSMAN.EM_GATHER_SYSMAN_STATS`) | Accepted. These are scheduled, not running, and the window completed well inside the hour. Oracle's own advice is to patch when jobs are not running or to lock them out — worth doing on a longer window. |
| Everything else | `OK` |

`datapatch -verbose` then reported both patches `apply: SUCCESS` with `(no
errors)`.

> **Do not grep the sqlpatch logs for `ORA-`.** The obvious-looking check
> `grep -R "ORA-" $ORACLE_BASE/cfgtoollogs/sqlpatch/` returned roughly **three
> hundred** matches on this completely successful run, and not one indicated a
> problem: Oracle ships the RU scripts with literal `IGNORABLE ERRORS: ORA-00955`
> declarations, quotes `ORA-` codes in comments, and raises-and-swallows
> `ORA-00955 name is already used` by design for every object that already exists.
> Datapatch validates its own logfiles and prints `(no errors)` per patch — that
> is the authoritative signal. Full write-up: `known-risks.md` #155.

> **`ORA-04068: existing state of packages has been discarded` in the ALERT LOG
> during datapatch is benign.** OJVM README Known Issue 1. This is about the alert
> log — an `ORA-04068` reported *by datapatch* as a failure is a different matter.

### 13.3 Recompile with catcon.pl, not bare utlrp

Oracle's README specifies the `catcon.pl` form:

```bash
export PATH=$PATH:$ORACLE_HOME/bin
cd $ORACLE_HOME/rdbms/admin
$ORACLE_HOME/perl/bin/perl $ORACLE_HOME/rdbms/admin/catcon.pl \
  -n 1 -e -b utlrp -d $ORACLE_HOME/rdbms/admin utlrp.sql
```

![Ansible task "Show utlrp output": catcon.pl invoked with -n 1 -e -b utlrp -d $ORACLE_HOME/rdbms/admin utlrp.sql, log paths reported under rdbms/admin, ending with "catcon.pl: completed successfully", followed by the "Restore extjob ownership and permissions" task reporting changed](screenshots/13b-catcon-utlrp-completed.png)

The flags, since this line gets copied more often than it gets read: `-n 1` one
worker, serial; `-e` echo output; `-b utlrp` base name for the generated logs;
`-d` the directory holding the script.

> **Why not `@?/rdbms/admin/utlrp.sql`.** This runbook and the role both used the
> bare form. On a non-CDB the two are equivalent, so it would have worked — and
> would have quietly stopped being equivalent the moment Phase 7d converts this
> database to a CDB, because the bare form only recompiles the container it is
> connected to. Using Oracle's documented form now means 7d does not silently
> invalidate this step.

**Check what is left**, compared to the pre-patch baseline rather than to zero:

```sql
SELECT owner, object_type, COUNT(*)
FROM   dba_invalid_objects
GROUP  BY owner, object_type ORDER BY 3 DESC;
```

The run went **2 → 0**. A count that returned to its pre-patch level is clean
whatever that level is; a count that rose and stayed risen after `utlrp` is the
MDSYS seed-template signature described in `patching-strategy.md` Mechanism 3.

---

## 14. `extjob`, and two things left manual

### 14.1 Restore extjob's ownership and permissions

Easy to skim past, and it has a delayed failure mode. Applying an RU relinks
libraries and executables, and relinking can reset the ownership and setuid bit
on `$ORACLE_HOME/bin/extjob` — the binary `DBMS_SCHEDULER` uses to run external
OS jobs. Left owned by `oracle` without the setuid bit, external jobs fail at
runtime, a long way from the change that caused it.

**Who:** `root`
**Where:** `oemserver01`

```bash
chown root /u01/app/oracle/product/19.3.0/db_1/bin/extjob
chmod 4750 /u01/app/oracle/product/19.3.0/db_1/bin/extjob
```

`4750` is setuid, `rwx` for the owner (`root`), `r-x` for the group, nothing for
others. The role reasserts it unconditionally rather than checking first — it is
cheap, and the check and the fix are the same command.

### 14.2 RMAN recovery catalog upgrade — left manual

Oracle's §3.3.3. If a recovery catalog is in use, it must be upgraded after the
patch, and `UPGRADE CATALOG` is entered **twice** to confirm:

```bash
rman catalog <user>/<password>@<alias>
RMAN> UPGRADE CATALOG;
RMAN> UPGRADE CATALOG;
RMAN> EXIT;
```

Not automated: it needs catalog credentials, which do not belong in this
repository. And this project has not established that a catalog exists at all —
[Part 2 §9.1](phase-7a-part2-the-patch-window.md#91-full-rman-backup)'s backup
ran `rman target /` and reported *"using target database control file instead of
recovery catalog"*. Confirm which is true rather than assuming this is a no-op.

### 14.3 Optimizer-affecting bug fixes — left manual

Oracle's §3.3.4. An RU ships bug fixes that can change an existing execution plan
in a **disabled** state by default. Fixes already enabled before the patch stay
enabled; new ones do not switch themselves on. Enabling them is a deliberate act
via `DBMS_OPTIM_BUNDLE` (Oracle points at KB148297 for the commands).

Left manual on purpose. Silently changing optimizer behaviour on the repository
database as a side effect of a patch run is the opposite of what this window is
for, and the default state is the safe one. If a plan regression shows up later,
this is the knob — and knowing it was never touched here is part of being able to
diagnose that.

---

## 15. Bring Enterprise Manager back

Reverse of [Part 2 §8](phase-7a-part2-the-patch-window.md#8-stop-the-stack-in-order):
database first, OMS last.

**Who:** `oracle`
**Where:** `oemserver01`

```bash
lsnrctl start oemserver01_listener

. ~/.env/oms_env
emctl start oms
emctl status oms -details

. ~/.env/agent_env
emctl start agent
emctl status agent
emctl upload agent
```

![Ansible restart output: emctl start oms reporting WebTier Successfully Started and Oracle Management Server Successfully Started, then emctl status oms -details showing Console Server Host oemserver01.usat.com, HTTPS Console Port 7803, HTTPS Upload Port 4903, Agent Upload is unlocked, Console URL https://oemserver01.usat.com:7803/em, Admin Server is RUNNING, WebTier is Up, Oracle Management Server is Up, JVMD Engine is Up, followed by the agent environment being sourced](screenshots/15-oms-restarted-console-url.png)

`emctl upload agent` forces an immediate upload rather than waiting for the next
scheduled one, which shortens the gap between "it works" and "I can see that it
works." The run reported `EMD upload completed successfully`.

**Then stop the blackout** — see §18, and
[the blackout page §6](oem-create-blackout.md#6-clearing-it-afterwards). Not
before §16's checklist passes.

---

## 16. Verification checklist

Not one check. A patched database that OMS cannot use is not a successful patch.

![Ansible task "Show verification output": SQL*Plus Release 19.0.0.0.0 Version 19.32.0.0.0, banner_full showing Version 19.32.0.0.0, dba_registry with all components VALID except RAC OPTION OFF, dba_registry_sqlpatch showing 35042068 RU APPLY SUCCESS, 29213893 INTERIM APPLY SUCCESS, 29213893 INTERIM ROLLBACK SUCCESS, 39222882 INTERIM APPLY SUCCESS flags NJ at 07.10.04, 39472050 RU APPLY SUCCESS at 07.14.28, then PATCH_STATUS=SUCCESS, OJVM_STATUS=SUCCESS, POST_INVALID_COUNT=0, POST_REGISTRY_NOT_VALID=1](screenshots/16a-verification-19.32-registry.png)

| # | Check | Command | Expected | Result |
|---|---|---|---|---|
| 0 | AHF compliance, post-patch | `ahf analysis create --type compliance` | diffable against the Part 1 §5.6 baseline | ⬜ outstanding |
| 1 | Binary patches present | `opatch lspatches` | **both** `39472050` and `39222882` | 🟩 both, plus OCW |
| 2 | Dictionary patched | `SELECT * FROM dba_registry_sqlpatch` | **both** IDs, `APPLY`, `SUCCESS` | 🟩 07:14:28 and 07:10:04 |
| 3 | Version | `SELECT banner_full FROM v$version` | `19.32.0.0.0` | 🟩 |
| 4 | Datapatch verdict | datapatch's own `... apply: SUCCESS ... (no errors)` | `(no errors)` both patches — **do not grep for `ORA-`**, §13.2 | 🟩 |
| 5 | Invalid objects | `dba_invalid_objects`, §13.3 | back to the pre-patch count, not necessarily zero | 🟩 2 → 0 |
| 6 | Registry components | `SELECT comp_name, status FROM dba_registry` | no component worse than pre-patch | 🟩 1 → 1, `RAC OPTION OFF` |
| 7 | All PDBs patched (CDB only) | `SELECT name, open_mode FROM v$pdbs` | every PDB open and patched | n/a — non-CDB |
| 8 | `extjob` permissions | `ls -l $ORACLE_HOME/bin/extjob` | `-rwsr-x---`, owner `root` | 🟩 reasserted `root:4750` |
| 9 | Listener up | `lsnrctl status` | service registered | 🟩 `oemserver01_listener` |
| 10 | OMS up | `emctl status oms -details` | WebTier and OMS up | 🟩 |
| 11 | Agent uploading | `emctl status agent` | `Heartbeat Status : Ok`, 0 pending | 🟩 `EMD upload completed successfully` |
| 12 | Target count intact | `emctl status agent` | **43 targets**, matching pre-patch | 🟩 43 → 43 |
| 13 | Blackout cleared | `emctl status blackout` | none active | ⬜ outstanding, §18 |
| 14 | Console loads | browser | `https://oemserver01.usat.com:7803/em` | ⬜ confirm |

### 16.1 Four of these deserve singling out

**Check 12** is the one most likely to be skipped and most likely to matter. A
target count that dropped after a patch is a real problem wearing the disguise of
a successful maintenance window.

**Check 5** is a comparison, not an absolute. A count that returned to its
pre-patch level is clean whatever that level is; insisting on zero invites
someone to "fix" pre-existing invalid objects during a patch window, which is a
second change wearing the first one's clothes. This run happened to reach zero.

**Check 8** looks like trivia and is not. Relinking during an RU can reset
`extjob`'s owner and setuid bit, and the resulting failure — `DBMS_SCHEDULER`
external jobs not running — surfaces days later with nothing obviously connecting
it to the patch.

**Check 4** was originally written as `grep -R "ORA-"` across the sqlpatch log
tree, and that was wrong for the reasons in §13.2. A check that cries wolf three
hundred times does not degrade to a useless check — it degrades to a harmful one,
because the next person scrolls past the block, and the run where one of those
lines is real looks exactly like this one.

### 16.2 The role's own summary

![Ansible task "Report summary": finished 2026-09-04 07:19:58 EDT, patch 39472050, mechanism opatch, invalid objects 2 -> 0, registry !VALID 1 -> 1, targets expected 43, targets now 43, four artefact paths under /u01/app/oracle/logs/oem_repo_patch/ (baseline_pre, baseline_post, lsinventory_pre, lsinventory_post) and the diff -u command to compare them, then PLAY RECAP oemserver01 ok=88 changed=19 unreachable=0 failed=0](screenshots/16b-report-summary-play-recap.png)

The four artefacts are the real deliverable of the run — the before-and-after
pair the summary is derived from:

```bash
diff -u /u01/app/oracle/logs/oem_repo_patch/baseline_pre_20260904T063751.txt \
        /u01/app/oracle/logs/oem_repo_patch/baseline_post_20260904T063751.txt
```

---

## 17. Rollback, if verification fails

Not needed on this run. Recorded because the procedure has to exist before the
window, not after — and in the order Oracle documents, which is **not** the order
an earlier draft of this section gave.

```bash
# 1. Stop the OMS, the agent, the database and the listener (as Part 2 §8/§10),
#    and confirm nothing is still running against the home.

# 2. Roll the BINARIES back first (README §4.1), REVERSE of the apply order:
#    OJVM came second, so it comes off first.
cd $ORACLE_HOME/OPatch
./opatch rollback -id 39222882 -silent    # OJVM
./opatch rollback -id 39472050 -silent    # Database RU

# 3. THEN start the database and roll the dictionary back (README §4.2.1)
sqlplus / as sysdba <<'SQL'
SET TAB OFF
STARTUP
-- CDB only: ALTER PLUGGABLE DATABASE ALL OPEN;
EXIT
SQL

cd $ORACLE_HOME/OPatch
./datapatch -sanity_checks
./datapatch -verbose

# 4. Recompile, same catcon.pl form as §13.3
cd $ORACLE_HOME/rdbms/admin
$ORACLE_HOME/perl/bin/perl $ORACLE_HOME/rdbms/admin/catcon.pl \
  -n 1 -e -b utlrp -d $ORACLE_HOME/rdbms/admin utlrp.sql

# 5. Verify v$version returns to 19.19.0.0.0, and that
#    dba_registry_sqlpatch shows ACTION=ROLLBACK, STATUS=SUCCESS
```

> **Corrected 2026-08-31.** This previously rolled the dictionary back first
> (`datapatch -rollback 39472050 -verbose`) and the binaries second. The 39472050
> README reverses that: §4.1 shuts everything down and runs `opatch rollback`, and
> §4.2.1 — explicitly the *post*-deinstallation step — starts the database and
> runs plain `datapatch` to roll the SQL back. `datapatch` needs no `-rollback`
> flag; with the binaries already removed it works out what to undo on its own.
> [Part 2 §11](phase-7a-part2-the-patch-window.md#11-roll-back-the-superseded-one-offs)
> proved that behaviour on the one-offs.
>
> Check the rollback log at
> `$ORACLE_BASE/cfgtoollogs/sqlpatch/39472050/<unique patch ID>/39472050_rollback_<SID>_<CDB>_<timestamp>.log`
> — same place and naming as the apply log, with `rollback` in place of `apply`.
> The `<unique patch ID>` level is not derivable from the patch number, which is
> why both the command and the role glob rather than construct the path.

**The guaranteed restore point is not a fallback on this database.** `PRE_RU32`
exists and is guaranteed, but `FLASHBACK_ON` was `NO` when it was created
([Part 2 §9.2](phase-7a-part2-the-patch-window.md#92-guaranteed-restore-point)),
so `FLASHBACK DATABASE TO RESTORE POINT` is not available. **The RMAN backup at
`/u03/backups/rman/oemcdb/20260904T063751` is the real fallback.**

---

## 18. Aftermath — what is still outstanding

Both deliberately not automated, and both time-sensitive.

### 18.1 Clear the blackout

`Blackout-Sep 4 2026 6:40:20 AM` is still active. The role creates nothing and
clears nothing here — a blackout needs `emcli` and `sysman` credentials, which do
not belong in this repository.

```bash
. /home/oracle/.env/agent_env
emctl stop blackout "Blackout-Sep 4 2026 6:40:20 AM"
emctl status blackout
```

Full procedure, including the console and `emcli` routes:
[Creating a Blackout §6](oem-create-blackout.md#6-clearing-it-afterwards).

Clear it once §16's checklist is fully green, **not before** — the verification is
what tells you whether monitoring should be trusted again.

### 18.2 Drop the guaranteed restore point

```sql
DROP RESTORE POINT PRE_RU32;
```

It holds flashback logs indefinitely and will fill the fast recovery area, which
on a host already at 15% free is a real risk rather than a theoretical one. It
**must** be dropped — but only once a human agrees the patch is good.

### 18.3 Smaller follow-ups

- **Post-patch AHF compliance check**, to diff against the Part 1 §5.6 baseline
  (§16 check 0).
- **Confirm the console loads** in a browser (§16 check 14).
- **Fix the `group_vars/all.yml` description** of
  `/u01/app/oracle/product/19.3.0/db_1`, which calls it an Oracle *Client* home.
  The preflight proved an instance runs from it. See the
  [index's open questions](phase-7a-repository-db-ru32.md#open-questions-for-the-write-up).
- **Establish whether a recovery catalog exists** (§14.2).

---

## 19. Screenshot checklist and naming convention

```
screenshots/
├── 03a-preflight-registry-components.png
├── 03b-preflight-summary-19.19.png
├── 04-stage-combo-components-present.png
├── 06-opatch-update-12.2.0.1.52.png
├── 07a-pause-blackout-checkpoint.png
├── 07b-blackout-verified-expired-false.png
├── 08-oms-stopped.png
├── 09a-rman-backup-pre-ru32.png
├── 09b-restore-point-pre-ru32.png
├── 10-database-listeners-down-residual-0.png
├── 11a-rollback-verify-sqlpatch.png
├── 11b-post-rollback-conflict-recheck-passed.png
├── 12-post-apply-lspatches.png
├── 13a-datapatch-sanity-checks.png
├── 13b-catcon-utlrp-completed.png
├── 15-oms-restarted-console-url.png
├── 16a-verification-19.32-registry.png
└── 16b-report-summary-play-recap.png
```

Numbered to match the section they illustrate, across all three parts — the same
convention as `installation/`'s Section 15 and `high-availability/`'s `16a`/`16b`.
The nine `blackout-*` files belong to
[`oem-create-blackout.md`](oem-create-blackout.md) and are listed there.

**Renaming.** These came off the terminal as `oms_patch_step3a_The_full_run_opatch.png`
and similar, which did not match the convention, used `step3a` twice, and left
gaps at `3b` and `3j`. [`rename-screenshots.sh`](rename-screenshots.sh) does the
`git mv` in one pass and can be deleted once run and committed.

**One step has no screenshot: the apply itself.** The two `opatch apply -silent`
runs took several minutes each and scrolled past. `12-post-apply-lspatches.png`
and `16a-verification-19.32-registry.png` are the evidence they succeeded, and
both are stronger evidence than the apply's own console output would have been.
Noted rather than left as an unexplained gap — same handling as
`installation/README.md` Section 15 gives its own uncaptured steps.

**Timestamps differ between screenshots, and that is expected.** The preflight and
stage shots are from 2026-08-31, the pause/blackout/backup shots from the
2026-09-03 evening dry run, and everything from `11a` onward from the confirmed
2026-09-04 run. The rollback, apply, datapatch and verification evidence — the
part that proves the patch — is all from the single successful run.

**Minimum checklist before calling this phase showcase-ready:** the preflight
baseline (`03b`), the blackout gate (`07b`), the rollback verification (`11a`),
the post-rollback conflict re-check (`11b`), the post-apply inventory (`12`), the
verification registry at 19.32 (`16a`), and the summary (`16b`). All seven are
captured.

---

Back to **[Part 2 — The patch window](phase-7a-part2-the-patch-window.md)**.
Back to the **[index](phase-7a-repository-db-ru32.md)**.
