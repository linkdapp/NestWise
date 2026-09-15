# Phase 7d Part 3: Post-deployment

**The repository runs from a PDB. Now make everything that points at it agree**

Part 3 of three. [Part 1](phase-7d-part1-pre-deployment.md) built the container.
[Part 2](phase-7d-part2-deployment.md) ran the window. The index is
[`phase-7d-noncdb-to-pdb.md`](phase-7d-noncdb-to-pdb.md).
Also indexed by skill area under
[Multitenant](../multitenant/README.md).

Status: 🟨 **In progress.** `dbsnmp` is unlocked and `usatcdb`, `oempdb` and `ggpdb`
are promoted. The old `oemcdb` target and datafiles are still in place.

[Part 2](phase-7d-part2-deployment.md) ends with the console served from `oempdb`.
Everything here follows that.

| # | Task | Status |
|---|---|---|
| 1 | Repoint the repository target | 🟨 1.1 and 1.2 done; 1.3 and 1.4 open |
| 2 | Clear the blackout | Not needed, none was created |
| 3 | Remove old targets `oemcdb` | ⬜ |
| 4 | Close the dormant Ansible branch | ⬜ |
| 5 | Update the estate's connection details | ⬜ |
| 6 | Retire the old non-CDB | ⬜ |
| 7 | Close out | ⬜ |
| 8 | Appendix A: Reference notes | 🟩 |
| 9 | Screenshot checklist | 🟨 6 of 12 |

```bash
source ~/.env/oms_env
```

---

## Contents

1. [Repoint the repository target](#1-repoint-the-repository-target)
2. [Clear the blackout](#2-clear-the-blackout)
3. [Remove old targets `oemcdb`](#3-remove-old-targets-oemcdb)
4. [Close the dormant Ansible branch](#4-close-the-dormant-ansible-branch)
5. [Update the estate's connection details](#5-update-the-estates-connection-details)
6. [Retire the old non-CDB](#6-retire-the-old-non-cdb)
7. [Close out](#7-close-out)
8. [Appendix A: Reference notes](#8-appendix-a-reference-notes)
9. [Screenshot checklist](#9-screenshot-checklist)

---

## 1. Repoint the repository target

Status: 🟩 the OMS connection itself was repointed in
[Part 2 §7](phase-7d-part2-deployment.md#7-repoint-the-oms). What remains here is the
two monitored targets that describe the same database and did not move with it.

`usatcdb`, `oempdb` and `ggpdb` were confirmed open at the end of Part 2. That check is
not repeated here.

### 1.1 Unlock `dbsnmp` in the container

A container created by `dbca` has `dbsnmp` as a **common user in `LOCKED` status**.
Monitoring credentials fail against the new targets until it is unlocked.

```sql
-- connect to usatcdb as sysdba
select username, account_status, common from cdb_users where username = 'DBSNMP';

alter user dbsnmp identified by <password> account unlock;
```

```
SQL> col username for a12
SQL> select con_id, username, account_status, common from cdb_users where username = 'DBSNMP';

    CON_ID USERNAME     ACCOUNT_STATUS                   COM
---------- ------------ -------------------------------- ---
         1 DBSNMP       LOCKED                           YES
         4 DBSNMP       OPEN                             YES
         3 DBSNMP       LOCKED                           YES

SQL>
SQL> alter user dbsnmp identified by <password> account unlock;

User altered.

SQL>
SQL> select con_id, username, account_status, common from cdb_users where username = 'DBSNMP';

    CON_ID USERNAME     ACCOUNT_STATUS                   COM
---------- ------------ -------------------------------- ---
         1 DBSNMP       OPEN                             YES
         3 DBSNMP       OPEN                             YES
         4 DBSNMP       OPEN                             YES

SQL>
```

Then set the monitoring credentials on the new targets in the console and test them.

### 1.2 The monitored database target changed shape

Enterprise Manager monitored `oemcdb` as a single non-CDB `oracle_database` target. It
is now a PDB inside a container: a different target type with a different parent. The
container, `oempdb` and `ggpdb` are promoted together in one pass.

**Setup → Add Target → Add Targets Manually**

![Setup, Add Target, Add Targets Manually](screenshots/7d/7d3-02-targets-promote_launch.png)

**Add Using Guided Process**

![Add Using Guided Process selected](screenshots/7d/7d3-03-targets-promote_launch_guided.png)

**Oracle Database, Listener and Automatic Storage Management**, then **Add**

![The guided process list with the database target type chosen](screenshots/7d/7d3-04-targets_launch_guided_proc.png)

Select `oemserver01.usat.com`, then **Next**

![Target discovery against oemserver01](screenshots/7d/7d3-05-target_discovery.png)

Run **Test Connection**, then set **Global Target Properties** and **Specify Group for
Target**, then **Next**

![Discovery results listing usatcdb, oempdb and ggpdb](screenshots/7d/7d3-06-target_discovery_results.png)

**Save**, then **Close**

![The review page before saving](screenshots/7d/7d3-07-target_discovery_review.png)

The old `oemcdb` target stops reporting, because the SID no longer starts. It is
removed in [§3](#3-remove-old-targets-oemcdb).


### 1.3 Verify Console Shows container Database and two Pluggable databases

**Targets → Databases**

Expected: `usatcdb` listed as a container database, with `oempdb` and `ggpdb` beneath
it.

![The console listing usatcdb with oempdb and ggpdb](screenshots/7d/7d3-07-target_discovery_show_con.png)

### 1.4 Check the targets that keep the old SID anyway

`emctl config oms -list_repos_details` reporting a service name does not guarantee
every target agrees. Two monitoring configurations have been observed still holding the
SID after the change:

| Target | Where |
|---|---|
| Management Service | Its monitoring configuration page |
| Management Services and Repository | Its monitoring configuration page |

Open each target's **Monitoring Configuration** and read the connect descriptor. Where
it still names a SID, edit it to the service name form and save. Change only the
connect descriptor; leave the username and password fields alone.

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

## 3. Remove old targets oemcdb.

### 3.1 Remove the target

**Setup → Add Target → Auto Discovery Results**, or remove the `oemcdb` target
directly.

The database itself stays on disk until [§6](#6-retire-the-old-non-cdb). Removing the
target ends the availability alerts; it does not end the rollback.

### 3.2 Agents are uploading

**Setup → Manage Cloud Control → Agents**

All agents Up, Secure Upload Yes, recent Last Successful Load.

### 3.3 Checklist

| # | Check | Expected |
|---|---|---|
| 1 | `v$pdbs` | `OEMPDB` read write, `RESTRICTED` = `NO` |
| 2 | `dba_registry` in `oempdb` | Every component `VALID` |
| 3 | `pdb_plug_in_violations` | Nothing `PENDING` |
| 4 | `emctl status oms -details` | Up, console and agent upload still locked |
| 5 | `emctl config oms -list_repos_details` | Names `oempdb.usat.com` |
| 6 | Repository target in the console | Up, monitored through the new descriptor |
| 7 | Management Service and Management Services and Repository | Monitoring configuration naming a service name, not a SID. §1.4 |
| 8 | `dbsnmp` in `usatcdb` | `OPEN`, with monitoring credentials tested. §1.1 |
| 9 | Agents | All Up and uploading. §3.2 |
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
| `tnsnames.ora` on `oemserver01` | Add or repoint the repository alias. The OMS does not use it: [Part 2 Appendix B.5](phase-7d-part2-deployment.md#b5-tnsnamesora) has the form and why |
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

### 6.2 Confirm the target is gone

Removed in [§3.1](#3-remove-old-targets-oemcdb). Confirm it before deleting datafiles,
so that a target still polling a dead SID does not raise incidents against a database
that no longer exists.

### 6.3 Reclaim the datafiles

[Part 2 §5](phase-7d-part2-deployment.md#5-create-oempdb-with-copy-option) used `COPY`, so the
original datafiles are still on disk and still consuming the space
[Part 1 §3](phase-7d-part1-pre-deployment.md#3-size-the-target) reserved.

```bash
df -h /u01
```

Delete the old `OEMCDB` datafile directory only after §3 has passed and §6.1 and §6.2
are done.

### 6.4 Decide on `oemcdbXDB`

`dba_services` inside `oempdb` lists `oemcdbXDB`, the XML DB service that came across
with the plug-in, because a non-CDB's service definitions travel into the PDB. It is
named for a database that no longer exists.

```sql
alter session set container = oempdb;
select name, network_name from dba_services order by name;
select name from v$active_services order by name;
```

Confirm nothing connects through it before removing it. Checked over a period that
covers a full monitoring cycle, not a single sample:

```sql
select service_name, count(*) from v$session group by service_name;
```

Leaving it costs nothing. It is listed here so that the name is a recorded decision
rather than an unexplained leftover.

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

### A.2 Why the three descriptor commands are not interchangeable

The three in §1's table change three different settings. Running only
`store_repos_details` leaves Enterprise Manager working while two of its own targets
report down. Running either of the others alone does nothing useful, because the OMS
cannot start until the first has run.

The ordering for `store_repos_details` is in
[Part 2 §2](phase-7d-part2-deployment.md#2-stop-the-stack). Step 1 is `emctl stop oms`,
not `emctl stop oms -all`, because the Administration Server has to be up while the
command runs. That is the same requirement `emctl secure lock` has in
[Phase 7c Part 2c §3.3](phase-7c-part2c-post-deployment.md#33-lock-it).

### A.3 A PDB has no SID

The old connect descriptor named `oemcdb` as a SID, which worked because a non-CDB has
one. A PDB does not, so every connection to `oempdb` goes through a service name.
[Part 2 Appendix B](phase-7d-part2-deployment.md#appendix-b-service-names-and-tnsnamesora)
covers the service itself.

That decides the form of the `store_repos_details` command. `emctl config oms -help`
offers `-repos_host`, `-repos_port` and `-repos_sid` as one shape and `-repos_conndesc`
as another. The first cannot name a PDB, so the second is the only option here. The
help text recommends `-repos_conndesc` for repositories in TCPS mode; that
recommendation is about TLS and does not restrict the parameter to TCPS, and the
Administrator's Guide uses the same parameter over TCP for a RAC failover descriptor.

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
| `7d3-02-targets-promote_launch.png` | 1.2 | Setup, Add Target, Add Targets Manually | 🟩 |
| `7d3-03-targets-promote_launch_guided.png` | 1.2 | Add Using Guided Process | 🟩 |
| `7d3-04-targets_launch_guided_proc.png` | 1.2 | The database target type chosen | 🟩 |
| `7d3-05-target_discovery.png` | 1.2 | Discovery against `oemserver01` | 🟩 |
| `7d3-06-target_discovery_results.png` | 1.2 | `usatcdb`, `oempdb` and `ggpdb` found | 🟩 |
| `7d3-07-target_discovery_review.png` | 1.2 | The review page before saving | 🟩 |
| `7d3-07-target_discovery_show_con.png` | 1.3 | The console listing the container and both PDBs | 🟩 |
| `7d3-08-monitoring-config-service-name.png` | 1.4 | A monitoring configuration page after the SID was replaced | ⬜ |
| `7d3-09-oemcdb-target-removed.png` | 3.1 | The old `oemcdb` target gone | ⬜ |
| `7d3-10-ansible-cdb-branch.png` | 4.1 | The CDB branch taken and `datapatch` across the PDBs | ⬜ |
| `7d3-11-df-reclaimed.png` | 6.3 | `/u01` after the old datafiles are removed | ⬜ |
| `7d3-12-services-after-cleanup.png` | 6.4 | `dba_services` in `oempdb` after the `oemcdbXDB` decision | ⬜ |

Two files share the `7d3-07-` prefix. Both are referenced as they are on disk.

---

## What this feeds into

- **Any repository release past 19c.** Non-CDB is desupported from Oracle Database
  21c onward, and that gate is now cleared.
- **Phase 4, GoldenGate Classic.** `ggpdb` exists and is empty.

---

Back to **[Part 2](phase-7d-part2-deployment.md)**,
**[Part 1](phase-7d-part1-pre-deployment.md)**, or the
**[index](phase-7d-noncdb-to-pdb.md)**.
