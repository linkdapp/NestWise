# Phase 7d Part 2: Deployment

**The window. Enterprise Manager is down from section 2 until section 7 completes**

Part 2 of three. [Part 1](phase-7d-part1-pre-deployment.md) built `usatcdb` and
`ggpdb` beside the running repository. The index is
[`phase-7d-noncdb-to-pdb.md`](phase-7d-noncdb-to-pdb.md).
[Part 3](phase-7d-part3-post-deployment.md) follows.

Status: ⬜ Planned.

| # | Task | Status |
|---|---|---|
| 1 | Before you stop anything | ⬜ |
| 2 | Stop the stack | ⬜ |
| 3 | Shut the source down | ⬜ |
| 4 | Check plug compatibility | ⬜ |
| 5 | Create `oempdb` | ⬜ |
| 6 | Run `noncdb_to_pdb.sql` | ⬜ |
| 7 | Repoint the OMS | ⬜ |
| 8 | Rollback | ⬜ |
| 9 | Screenshot checklist | ⬜ |

```bash
export ORACLE_HOME=/u01/app/oracle/product/19.3.0/db_1
export PATH=$ORACLE_HOME/bin:$PATH
```

---

## Contents

1. [Before you stop anything](#1-before-you-stop-anything)
2. [Stop the stack](#2-stop-the-stack)
3. [Shut the source down](#3-shut-the-source-down)
4. [Check plug compatibility](#4-check-plug-compatibility)
5. [Create `oempdb`](#5-create-oempdb)
6. [Run `noncdb_to_pdb.sql`](#6-run-noncdb_to_pdbsql)
7. [Repoint the OMS](#7-repoint-the-oms)
8. [Rollback](#8-rollback)
9. [Screenshot checklist](#9-screenshot-checklist)

---

## 1. Before you stop anything

### 1.1 Create the blackout

Every target in the estate is about to go unreachable, because the OMS that monitors
them is going down with its repository. Create the blackout **before** stopping the
OMS, so the suppression is already recorded when it comes back.

Through the console, following
**[Creating a Blackout in Enterprise Manager](oem-create-blackout.md)**, with
**Enable Full blackout on all hosts** selected.

### 1.2 Record the target count

```bash
source ~/.env/oms_env
emcli login -username=sysman
emcli get_targets | wc -l
```

[Part 3](phase-7d-part3-post-deployment.md) compares against this number. Phase 7c
recorded 203 before its window.

### 1.3 Confirm Part 1 is complete

| Check | Expected |
|---|---|
| `usatcdb` exists and is open | [Part 1 §4.5](phase-7d-part1-pre-deployment.md#45-confirm-it-matches-the-source) |
| Character set matches the source | [Part 1 §4.5](phase-7d-part1-pre-deployment.md#45-confirm-it-matches-the-source) |
| `ggpdb` open and `SAVE STATE` set | [Part 1 §5](phase-7d-part1-pre-deployment.md#5-create-ggpdb) |
| OMS configuration exported | [Part 1 §6](phase-7d-part1-pre-deployment.md#6-capture-the-oms-configuration) |
| Free space for the second copy | [Part 1 §3](phase-7d-part1-pre-deployment.md#3-size-the-target) |
| Service name descriptor proven against the source | [Part 1 §7](phase-7d-part1-pre-deployment.md#7-prove-a-service-name-descriptor-reaches-the-repository) |

---

## 2. Stop the stack

**Who:** `oracle`
**Where:** `oemserver01`

```bash
source ~/.env/oms_env
emctl stop oms
emctl status oms
```

**`emctl stop oms`, without `-all`.** The Administration Server stays up on purpose.
§7 runs `emctl config oms -store_repos_details`, and `emctl config oms -help` on this
build documents the sequence as stop, configure, then stop `-all`, then start:

```
Note: Steps in changing repository details are:
         1) Stop all the OMSs using 'emctl stop oms'
         2) Run 'emctl config oms -store_repos_details' on each of the OMSs
         3) Stop all the OMSs completely using 'emctl stop oms -all'
         4) Start all of the OMSs using 'emctl start oms'
```

This is the same shape as `emctl secure lock` in
[Phase 7c Part 2c §3.3](phase-7c-part2c-post-deployment.md#33-lock-it), which needs
the Administration Server running while the managed server is down. If the
Administration Server has stopped by the time §7 runs, start it on its own with
`emctl start oms -admin_only`.

Then the central agent, from the agent instance home rather than the Oracle home:

```bash
source ~/.env/agent_env
emctl stop agent
emctl status agent
```

---

## 3. Shut the source down

The manifest has to be written from a read only mount, and the datafiles have to be
closed before they can be adopted.

```sql
-- connect to oemcdb as sysdba
SHUTDOWN IMMEDIATE;
STARTUP OPEN READ ONLY;
SELECT name, open_mode FROM v$database;
```

Expected `OPEN_MODE`: `READ ONLY`.

### 3.1 Describe the non-CDB

```sql
BEGIN
  DBMS_PDB.DESCRIBE(pdb_descr_file => '/u01/app/oracle/staging/7d/oemcdb.xml');
END;
/
```

```bash
ls -l /u01/app/oracle/staging/7d/oemcdb.xml
```

The file lists every datafile by path. It is the input to §4 and §5 and it is only
valid for this exact set of files; regenerate it if anything changes.

### 3.2 Shut it down

```sql
SHUTDOWN IMMEDIATE;
```

The source stays down for the rest of the window. Section 8's rollback starts by
bringing it back up.

---

## 4. Check plug compatibility

This is gate 5 from the [index](phase-7d-noncdb-to-pdb.md#gates), and it is the one
that could not be answered before the manifest existed.

```sql
-- connect to usatcdb as sysdba
SET SERVEROUTPUT ON
DECLARE
  compatible BOOLEAN;
BEGIN
  compatible := DBMS_PDB.CHECK_PLUG_COMPATIBILITY(
                  pdb_descr_file => '/u01/app/oracle/staging/7d/oemcdb.xml',
                  pdb_name       => 'OEMPDB');
  IF compatible THEN
    DBMS_OUTPUT.PUT_LINE('YES');
  ELSE
    DBMS_OUTPUT.PUT_LINE('NO');
  END IF;
END;
/
```

`NO` means stop. The reasons are in `PDB_PLUG_IN_VIOLATIONS`:

```sql
SELECT name, cause, type, message, status
FROM   pdb_plug_in_violations
WHERE  name = 'OEMPDB'
ORDER  BY time;
```

| `TYPE` | Meaning |
|---|---|
| `ERROR` | Blocks the plug-in. Resolve before continuing |
| `WARNING` | Does not block, and is expected: a non-CDB carries objects that `noncdb_to_pdb.sql` cleans up in §6 |

Do not proceed past an `ERROR`. Character set, component and patch level mismatches
all report here, which is why Part 1 checked them in advance rather than discovering
them inside the window.

---

## 5. Create `oempdb`

```sql
-- connect to usatcdb as sysdba
CREATE PLUGGABLE DATABASE oempdb USING '/u01/app/oracle/staging/7d/oemcdb.xml'
  COPY
  FILE_NAME_CONVERT = ('/u01/app/oracle/oradata/OEMCDB/',
                       '/u01/app/oracle/oradata/USATCDB/oempdb/');
```

**`COPY` leaves the source datafiles untouched**, which is why §8's rollback is a
`STARTUP` rather than a restore, and why
[Part 1 §3](phase-7d-part1-pre-deployment.md#3-size-the-target) sized for a second
copy. The `NOCOPY` and `MOVE` alternatives are in
[Part 1 Appendix B](phase-7d-part1-pre-deployment.md#9-appendix-b-copy-nocopy-and-move);
neither is used here, and §8's table below assumes `COPY`.

`FILE_NAME_CONVERT` maps every path in the manifest. Confirm the source prefix
against [Part 1 §1.5](phase-7d-part1-pre-deployment.md#15-datafiles-tempfiles-and-sizes)
rather than assuming the directory case.

The PDB is created `MOUNTED` and must stay that way until §6 has run.

```sql
SELECT name, open_mode FROM v$pdbs WHERE name = 'OEMPDB';
```

Expected: `MOUNTED`.

---

## 6. Run `noncdb_to_pdb.sql`

A database plugged in from a non-CDB is not yet a working PDB. This script converts
the dictionary: it removes the objects a non-CDB carries that a PDB inherits from
`CDB$ROOT`, and it is the step that makes the PDB openable.

```sql
ALTER SESSION SET CONTAINER = oempdb;
@?/rdbms/admin/noncdb_to_pdb.sql
```

It runs for several minutes and restarts the PDB itself. Do not interrupt it.

**Skipping it is the classic failure.** The PDB opens `RESTRICTED` with a
`PDB plugged in is a non-CDB` violation and cannot serve the repository.

### 6.1 Open it and save the state

```sql
ALTER SESSION SET CONTAINER = CDB$ROOT;
ALTER PLUGGABLE DATABASE oempdb OPEN;
ALTER PLUGGABLE DATABASE oempdb SAVE STATE;

SELECT name, open_mode, restricted FROM v$pdbs;
```

Expected: `OEMPDB` read write with `RESTRICTED` = `NO`. `RESTRICTED` = `YES` means
§6 did not complete; check `PDB_PLUG_IN_VIOLATIONS` again.

`SAVE STATE` is what reopens the PDB after a container restart. Without it the
repository comes back `MOUNTED` and the OMS cannot start.

### 6.2 Confirm the repository schema arrived

```sql
ALTER SESSION SET CONTAINER = oempdb;
SELECT username, account_status FROM dba_users WHERE username = 'SYSMAN';
SELECT comp_id, version, status FROM dba_registry ORDER BY comp_id;
```

`SYSMAN` present and the component list matching
[Part 1 §1.4](phase-7d-part1-pre-deployment.md#14-components-and-invalid-objects).

### 6.3 Add a service for the repository

```sql
ALTER SESSION SET CONTAINER = CDB$ROOT;
EXEC DBMS_SERVICE.CREATE_SERVICE('oempdb.usat.com','oempdb.usat.com');
```

The connect descriptor in §7 uses a service name rather than a SID, because a PDB has
no SID of its own. Confirm it is registered:

```bash
lsnrctl status
```

---

## 7. Repoint the OMS

Enterprise Manager still holds the connect descriptor recorded in
[Part 1 §1.7](phase-7d-part1-pre-deployment.md#17-the-current-repository-connect-descriptor),
which names a SID that no longer starts.

**Who:** `oracle`
**Where:** `oemserver01`, from the 24ai home

**This is the only descriptor change in the phase.** The old value names `oemcdb` as a
SID; the new one names `oempdb.usat.com` as a service.
[Part 1 §7](phase-7d-part1-pre-deployment.md#7-prove-a-service-name-descriptor-reaches-the-repository)
already proved that a `SERVICE_NAME` descriptor resolves on this host and that
`SYSMAN` authenticates through it, so what is untested here is the new service name
and the `store_repos_details` command itself.

**The `-repos_conndesc` form is required here.** `emctl config oms -help` offers two
shapes:

```
emctl config oms -store_repos_details -repos_host <host> -repos_port <port> -repos_sid <sid> -repos_user <username> [-repos_pwd <pwd>]
emctl config oms -store_repos_details -repos_conndesc <connect descriptor> -repos_user <username> [-repos_pwd <pwd>]
```

The first cannot express this target. A PDB has no SID, which is
[Appendix A.3 in Part 3](phase-7d-part3-post-deployment.md#8-appendix-a-reference-notes).

```bash
source ~/.env/oms_env

emctl config oms -store_repos_details \
  -repos_conndesc '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=oemserver01.usat.com)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=oempdb.usat.com)))' \
  -repos_user sysman
```

Omit `-repos_pwd`. The command prompts for the SYSMAN password interactively, so it
appears in no file and on no command line.

Then steps 3 and 4 of the documented sequence:

```bash
emctl stop oms -all
emctl start oms
emctl status oms -details
```

Then the central agent:

```bash
source ~/.env/agent_env
emctl start agent
emctl status agent
```

Expected: the OMS up, the console reachable at
`https://oemserver01.usat.com:7803/em`, and the agent uploading.

`emctl config emrep -conn_desc` updates the monitoring side and belongs in
[Part 3 §1](phase-7d-part3-post-deployment.md#1-repoint-the-repository-target). It
needs a running OMS, which is why it is not here.

---

## 8. Rollback

**The fallback is the original non-CDB.** `COPY` leaves `oemcdb`'s datafiles intact
and the source is shut down while the plug-in runs, so at every point in this window
the way back is to start the old database, fix whatever failed, and run the window
again. There is no restore and no flashback in this phase.

| Failed at | Route |
|---|---|
| §4, compatibility check | Nothing has been created. `STARTUP` the source and restart the OMS |
| §5, create pluggable database | `DROP PLUGGABLE DATABASE oempdb KEEP DATAFILES;` then §8.1 |
| §6, `noncdb_to_pdb.sql` | Same as §5 |
| §7, after the OMS was repointed | §8.2, then §8.1 |

**Use `KEEP DATAFILES`, not `INCLUDING DATAFILES`.** `INCLUDING DATAFILES` deletes
whatever the PDB's file entries point at, and a `FILE_NAME_CONVERT` that mapped a
target back onto a source path would make that command delete the source datafiles
this fallback depends on. `KEEP DATAFILES` leaves the copies on disk; confirm they are
the copies and not the originals, then remove them by hand:

```sql
SELECT name FROM v$datafile WHERE con_id =
  (SELECT con_id FROM v$pdbs WHERE name = 'OEMPDB');
```

Every path returned must sit under `/u02/oradata/USATCDB/oempdb/`. If any names the
source directory, stop and correct `FILE_NAME_CONVERT` before deleting anything.

### 8.1 Bring the source back

```sql
-- connect to oemcdb as sysdba
STARTUP;
SELECT name, cdb, open_mode FROM v$database;
```

A plain startup, because `COPY` left the source intact.

**Opening the source read write invalidates the manifest.** `/u01/app/oracle/staging/7d/oemcdb.xml`
describes `oemcdb` as it stood at §3.1. This `STARTUP` changes that, so a second
attempt at the plug-in re-runs §3 from the beginning rather than reusing the existing
file. Delete it to stop it being picked up by mistake:

```bash
rm -f /u01/app/oracle/staging/7d/oemcdb.xml
```

### 8.2 Restore the connect descriptor

```bash
source ~/.env/oms_env

emctl config oms -store_repos_details \
  -repos_conndesc '<the descriptor recorded in Part 1 §1.7>' \
  -repos_user sysman

emctl stop oms -all
emctl start oms
```

### 8.3 Clear the blackout

Per [the blackout page §6](oem-create-blackout.md#6-clearing-it-afterwards).

---

## 9. Screenshot checklist

All files go in [`screenshots/7d/`](screenshots/7d/), embedded as
`screenshots/7d/<file>`. See the
[index](phase-7d-noncdb-to-pdb.md#screenshots) for why this phase uses a
subdirectory.

| File | Section | Shows | Status |
|---|---|---|---|
| `7d2-01-blackout-set.png` | 1.1 | The blackout active | ⬜ |
| `7d2-02-describe.png` | 3.1 | `DBMS_PDB.DESCRIBE` and the manifest on disk | ⬜ |
| `7d2-03-plug-compatibility.png` | 4 | `CHECK_PLUG_COMPATIBILITY` returning `YES` | ⬜ |
| `7d2-04-create-pdb.png` | 5 | `CREATE PLUGGABLE DATABASE` completing | ⬜ |
| `7d2-05-noncdb-to-pdb.png` | 6 | The tail of `noncdb_to_pdb.sql` | ⬜ |
| `7d2-06-pdbs-open.png` | 6.1 | `v$pdbs` with `OEMPDB` read write, `RESTRICTED` = `NO` | ⬜ |
| `7d2-07-store-repos-details.png` | 7 | The connect descriptor change and the OMS restart | ⬜ |
| `7d2-08-console-reachable.png` | 7 | The console served from the repository in its new home | ⬜ |

---

Continue to **[Part 3: Post-deployment](phase-7d-part3-post-deployment.md)**.
Back to **[Part 1](phase-7d-part1-pre-deployment.md)** or the
**[index](phase-7d-noncdb-to-pdb.md)**.
