# Phase 7d Part 3: Post-deployment

**The repository runs from a PDB. Now make everything that points at it agree**

Part 3 of three. [Part 1](phase-7d-part1-pre-deployment.md) built the container.
[Part 2](phase-7d-part2-deployment.md) ran the window. The index is
[`phase-7d-noncdb-to-pdb.md`](phase-7d-noncdb-to-pdb.md).
Also indexed by skill area under
[Multitenant](../multitenant/README.md).

Status: ⬜ Planned.

[Part 2](phase-7d-part2-deployment.md) ends with the console served from `oempdb`.
Everything here follows that.

| # | Task | Status |
|---|---|---|
| 1 | Repoint the repository target | ⬜ |
| 2 | Clear the blackout | ⬜ |
| 3 | Verify | ⬜ |
| 4 | Close the dormant Ansible branch | ⬜ |
| 5 | Update the estate's connection details | ⬜ |
| 6 | Retire the old non-CDB | ⬜ |
| 7 | Close out | ⬜ |
| 8 | Appendix A: Reference notes | ⬜ |
| 9 | Screenshot checklist | ⬜ |

```bash
source ~/.env/oms_env
```

---

## Contents

1. [Repoint the repository target](#1-repoint-the-repository-target)
2. [Clear the blackout](#2-clear-the-blackout)
3. [Verify](#3-verify)
4. [Close the dormant Ansible branch](#4-close-the-dormant-ansible-branch)
5. [Update the estate's connection details](#5-update-the-estates-connection-details)
6. [Retire the old non-CDB](#6-retire-the-old-non-cdb)
7. [Close out](#7-close-out)
8. [Appendix A: Reference notes](#8-appendix-a-reference-notes)
9. [Screenshot checklist](#9-screenshot-checklist)

---

## 1. Repoint the repository target

[Part 2 §7](phase-7d-part2-deployment.md#7-repoint-the-oms) changed where the OMS
**connects**. Two further targets describe the same database and neither moved with
it. All three are separate settings.

| Command | Updates | Needs the OMS |
|---|---|---|
| `emctl config oms -store_repos_details` | Where the OMS connects to reach its repository | Stopped, Administration Server up |
| `emctl config emrep -conn_desc` | The **Management Services and Repository** target | Running |
| `emctl config repos -conn_desc` | The **repository database** target | Running |

**Who:** `oracle`
**Where:** `oemserver01`, with the OMS running

```bash
emctl config emrep \
  -conn_desc '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=oemserver01.usat.com)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=oempdb.usat.com)))'
```

The repository database target also carries a host and an Oracle home, and the
database it points at is now a PDB inside a container:

```bash
emctl config repos \
  -conn_desc '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=oemserver01.usat.com)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=oempdb.usat.com)))'
```

`emctl config repos` also accepts `-agent`, `-host` and `-oh`. None of those change
here: the database stays on `oemserver01`, in `/u01/app/oracle/product/19.3.0/db_1`,
monitored by the same central agent. Only the connect descriptor moves.

Use the same descriptor in all three places. A mismatch leaves a target reporting
down while the OMS runs perfectly, which is a confusing failure to diagnose later.

Both verbs describe `-conn_desc` as a *"jdbc connect descriptor"*. The documented
example form is the TNS descriptor above, not a full JDBC URL.

### 1.1 The monitored database target changed shape

Before this phase Enterprise Manager monitored `oemcdb` as an `oracle_database`
target: a single non-CDB. It is now a PDB inside a container, which is a different
target type with a different parent.

**Setup → Add Target → Add Targets Manually → Add Using Guided Process → Oracle
Database, Listener and Automatic Storage Management**

Discover `usatcdb` on `oemserver01`. The container, `oempdb` and `ggpdb` are
promoted together.

The old `oemcdb` target stops reporting, because the SID no longer starts. Remove it
only after §6 retires the database itself, so that the removal and the retirement are
one decision rather than two.

### 1.2 Unlock `dbsnmp` in the container

A container created by `dbca` has `dbsnmp` as a **common user in `LOCKED` status**.
Monitoring credentials fail against the new targets until it is unlocked.

```sql
-- connect to usatcdb as sysdba
SELECT username, account_status, common FROM cdb_users WHERE username = 'DBSNMP';

ALTER USER dbsnmp IDENTIFIED BY <password> ACCOUNT UNLOCK;
```

Then set the monitoring credentials on the new targets in the console and test them.

### 1.3 Check the targets that keep the old SID anyway

`emctl config oms -list_repos_details` reporting a service name does **not** guarantee
every target agrees. Two monitoring configurations have been observed still holding
the SID after the change:

| Target | Where |
|---|---|
| Management Service | Its monitoring configuration page |
| Management Services and Repository | Its monitoring configuration page |

Open each target's **Monitoring Configuration** and read the connect descriptor. Where
it still names a SID, edit it to the service name form and save. **Change only the
connect descriptor.** Leave the username and password fields at their existing values.

Running §1's `emctl config emrep` and `emctl config repos` is what should prevent
this. Check anyway, because the symptom is an incident raised hours later against a
target that looks healthy from the OMS side.

---

## 2. Clear the blackout

The blackout created in
[Part 2 §1.1](phase-7d-part2-deployment.md#11-create-the-blackout) suppresses every
alert on the estate while it is active.

Through the console, following
**[Creating a Blackout in Enterprise Manager](oem-create-blackout.md)**.

Check Incident Manager afterwards for availability events raised during the window
and clear the ones that are artefacts of it rather than real.

---

## 3. Verify

### 3.1 The repository is a PDB

```sql
-- connect to usatcdb as sysdba
SELECT name, open_mode, restricted FROM v$pdbs;
```

Expected: `PDB$SEED` read only, `OEMPDB` read write with `RESTRICTED` = `NO`,
`GGPDB` read write.

```sql
ALTER SESSION SET CONTAINER = oempdb;
SELECT sys_context('USERENV','CON_NAME') FROM dual;
SELECT comp_id, version, status FROM dba_registry ORDER BY comp_id;
```

Every component `VALID`.

### 3.2 No unresolved plug-in violations

```sql
SELECT name, cause, type, message, status
FROM   pdb_plug_in_violations
WHERE  name = 'OEMPDB'
AND    status != 'RESOLVED'
ORDER  BY time;
```

The `PDB plugged in is a non-CDB` warning should read `RESOLVED` once
[Part 2 §6](phase-7d-part2-deployment.md#6-run-noncdb_to_pdbsql) has run. Anything
still `PENDING` needs closing before this phase is marked confirmed.

### 3.3 The OMS and its repository

```bash
emctl status oms -details
emctl config oms -list_repos_details
```

The descriptor should name `SERVICE_NAME=oempdb.usat.com`, not the old SID.

### 3.4 Target count

```bash
emcli login -username=sysman
emcli get_targets | wc -l
```

Compare against
[Part 2 §1.2](phase-7d-part2-deployment.md#12-record-the-target-count). The count
rises by the new container and PDB targets from §1.1 and falls by the old `oemcdb`
target once §6 removes it.

### 3.5 Agents are uploading

**Setup → Manage Cloud Control → Agents**

Six agents Up, Secure Upload Yes, recent Last Successful Load.

### 3.6 Checklist

| # | Check | Expected |
|---|---|---|
| 1 | `v$pdbs` | `OEMPDB` read write, `RESTRICTED` = `NO` |
| 2 | `dba_registry` in `oempdb` | Every component `VALID` |
| 3 | `pdb_plug_in_violations` | Nothing `PENDING` |
| 4 | `emctl status oms -details` | Up, console and agent upload still locked |
| 5 | `emctl config oms -list_repos_details` | Names `oempdb.usat.com` |
| 6 | Repository target in the console | Up, monitored through the new descriptor |
| 7 | Management Service and Management Services and Repository | Monitoring configuration naming a service name, not a SID. §1.3 |
| 8 | `dbsnmp` in `usatcdb` | `OPEN`, with monitoring credentials tested. §1.2 |
| 9 | Agents | Six Up and uploading |
| 10 | Rollback still available | The old non-CDB is intact until §6 |

---

## 4. Close the dormant Ansible branch

Two pages in this repository carry a branch written for this day and never executed.

**[`phase-7a-ansible.md`](phase-7a-ansible.md#design-notes-for-anyone-editing-the-role).**
The `oem_repo_patch` role detects CDB against non-CDB and holds an
`ALTER PLUGGABLE DATABASE ALL OPEN` branch that has been dormant because
`SELECT cdb FROM v$database` returned `NO`. It now returns `YES`.

**[`phase-7a-part3-verification.md` §13.1](phase-7a-part3-verification.md#13-datapatch-the-step-people-forget).**
Records why the branch stays in the role permanently: *"Phase 7d converts this
database, and the day it does, the branch has to already be there."*

### 4.1 Exercise the branch

Do not take the branch on trust. Run the role against the new container and confirm
the CDB path is the one taken.

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags oem_repo_patch_datapatch
```

Expected in the run output: the CDB branch, the PDBs opened, and `datapatch` reporting
against `CDB$ROOT` plus every PDB rather than a single database.

### 4.2 Record the result

Update
[`phase-7a-part3-verification.md` §16](phase-7a-part3-verification.md#16-verification-checklist)'s
row 7, currently *"Not applicable, non-CDB"*. It is applicable now.

---

## 5. Update the estate's connection details

Anything that names the repository by SID now points at a database that does not
start.

| Location | Change |
|---|---|
| `group_vars/all.yml` | The repository connection entries move from a SID to `SERVICE_NAME=oempdb.usat.com` |
| `tnsnames.ora` on `oemserver01` | Add or repoint the repository alias |
| `~/.env/*` | Any `ORACLE_SID=oemcdb` export becomes a container or PDB connection |
| Backup scripts | RMAN connects to the container, not to the PDB, for a whole-database backup |
| Monitoring scripts | Scripts querying the repository directly need the service name |

Search before assuming the list is complete:

```bash
grep -rn 'oemcdb' --include='*.yml' --include='*.ora' --include='*.sh' .
```

---

## 6. Retire the old non-CDB

**Not until §3 passes and the estate has run long enough to trust.** The old non-CDB
is the rollback in
[Part 2 §8](phase-7d-part2-deployment.md#8-rollback). Removing it ends that.

### 6.1 Confirm it is down and stays down

```bash
ps -ef | grep [o]ra_pmon_oemcdb
```

No output. Remove any `/etc/oratab` entry that would restart it.

### 6.2 Remove the target from Enterprise Manager

**Setup → Add Target → Auto Discovery Results**, or remove the `oemcdb` target
directly. This is the removal deferred from §1.1.

### 6.3 Reclaim the datafiles

[Part 2 §5](phase-7d-part2-deployment.md#5-create-oempdb) used `COPY`, so the
original datafiles are still on disk and still consuming the space
[Part 1 §3](phase-7d-part1-pre-deployment.md#3-size-the-target) reserved.

```bash
df -h /u01
```

Delete the old `OEMCDB` datafile directory only after §3 has passed and §6.1 and §6.2
are done.

---

## 7. Close out

### 7.1 Back up the new shape

An RMAN level 0 of `usatcdb`, which now covers `CDB$ROOT`, `oempdb` and `ggpdb` in
one backup. The previous backup strategy targeted a single non-CDB and no longer
describes this database.

### 7.2 AHF compliance check

```bash
orachk -a
```

Diffable against the baseline in
[Phase 7a Part 1 §5.6](phase-7a-part1-before-the-window.md#56-ahf-compliance-baseline).

---

## 8. Appendix A: Reference notes

### A.1 Why `emcli migrate_noncdb_to_pdb` is not used

The verb takes `-migrationMethod=PLUG_AS_PDB` and looks like the tool for this job.
It drives a migration job through the OMS against a **monitored** target. The
repository is the database the OMS runs on, so the OMS stops the moment the source is
shut down and the job has nothing left to run in.

It remains the right tool for migrating any **other** non-CDB in this estate into
`usatcdb`, which is worth remembering when Phase 5 or Phase 9 need it.

### A.2 Three connect descriptor commands, none interchangeable

| Command | Changes | Needs the OMS |
|---|---|---|
| `emctl config oms -store_repos_details` | Where the OMS connects to reach its repository | Stopped, with the Administration Server up |
| `emctl config emrep -conn_desc` | The Management Services and Repository target | Running |
| `emctl config repos -conn_desc` | The repository database target | Running |

Running only the first leaves Enterprise Manager working while two of its own targets
report down. Running either of the others alone does nothing useful, because the OMS
cannot start until the first has run.

`emctl config oms -help` documents the order for the first one, and it is not the
obvious one:

```
1) Stop all the OMSs using 'emctl stop oms'
2) Run 'emctl config oms -store_repos_details' on each of the OMSs
3) Stop all the OMSs completely using 'emctl stop oms -all'
4) Start all of the OMSs using 'emctl start oms'
```

Step 1 is `emctl stop oms`, not `emctl stop oms -all`. The Administration Server has
to be up while the command runs, the same requirement `emctl secure lock` has in
[Phase 7c Part 2c §3.3](phase-7c-part2c-post-deployment.md#33-lock-it).

### A.3 A PDB has no SID

The old connect descriptor named `oemcdb` as a SID, which worked because a non-CDB
has one. A PDB does not. Every connection to `oempdb` goes through a service name,
which is why [Part 2 §6.3](phase-7d-part2-deployment.md#63-add-a-service-for-the-repository)
creates one rather than relying on the default.

This is also what decides the form of the `store_repos_details` command.
`emctl config oms -help` offers `-repos_host`, `-repos_port` and `-repos_sid` as one
shape and `-repos_conndesc` as another. The first cannot name a PDB, so the second is
the only option here. The help text recommends `-repos_conndesc` for repositories in
TCPS mode; that recommendation is about TLS and does not restrict the parameter to
TCPS, and the Administrator's Guide uses the same parameter over TCP for a RAC
failover descriptor.

### A.4 `SAVE STATE` is not optional

Without `ALTER PLUGGABLE DATABASE ... SAVE STATE`, a PDB returns to `MOUNTED` after
every container restart. For `oempdb` that means the OMS fails to start after any
reboot of `oemserver01`, which pairs badly with the documented behaviour that the OMS
and central agent do not start automatically after a host reboot on this estate.

---

## 9. Screenshot checklist

All files go in [`screenshots/7d/`](screenshots/7d/), embedded as
`screenshots/7d/<file>`. See the
[index](phase-7d-noncdb-to-pdb.md#screenshots) for why this phase uses a
subdirectory.

| File | Section | Shows | Status |
|---|---|---|---|
| `7d3-01-config-emrep.png` | 1 | `emctl config emrep` and `emctl config repos` completing | ⬜ |
| `7d3-02-targets-promoted.png` | 1.1 | `usatcdb`, `oempdb` and `ggpdb` promoted, old `oemcdb` down | ⬜ |
| `7d3-02b-monitoring-config-service-name.png` | 1.3 | A monitoring configuration page after the SID was replaced | ⬜ |
| `7d3-03-blackout-cleared.png` | 2 | The blackout cleared | ⬜ |
| `7d3-04-pdbs-and-registry.png` | 3.1 | `v$pdbs` and `dba_registry` in `oempdb` | ⬜ |
| `7d3-05-list-repos-details.png` | 3.3 | The descriptor naming `oempdb.usat.com` | ⬜ |
| `7d3-06-ansible-cdb-branch.png` | 4.1 | The CDB branch taken and datapatch across the PDBs | ⬜ |
| `7d3-07-df-reclaimed.png` | 6.3 | `/u01` after the old datafiles are removed | ⬜ |

---

## What this feeds into

- **Any repository release past 19c.** Non-CDB is desupported from Oracle Database
  21c onward, and that gate is now cleared.
- **Phase 4, GoldenGate Classic.** `ggpdb` exists and is empty.

---

Back to **[Part 2](phase-7d-part2-deployment.md)**,
**[Part 1](phase-7d-part1-pre-deployment.md)**, or the
**[index](phase-7d-noncdb-to-pdb.md)**.
