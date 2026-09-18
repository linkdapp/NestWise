---
description: "Oracle GoldenGate 19c Classic Architecture with Integrated Extract, replicating the NESTWISE schema from a 2-node RAC non-CDB to a PDB, with Extract following the primary through a Data Guard switchover."
---

# Phase 4: GoldenGate Classic, `apexdb` to `ggpdb`

**SOP: Oracle GoldenGate 19c Classic Architecture, Integrated Extract on a hub host, DML and DDL for the `NESTWISE` schema, Oracle Linux**

Source is `apexdb`, the 2-node RAC non-CDB on `usatclust1` built in
[Installation](../installation/README.md) and protected by Active Data Guard in
[Phase 2](README.md). Target is `ggpdb`, the empty PDB created inside `usatcdb` in
[Phase 7d Part 1 §5](../monitoring/phase-7d-part1-pre-deployment.md#5-create-ggpdb).

Status: ⬜ **Planned.**

> ### Three decisions this SOP is built on
>
> | Decision | Reason |
> |---|---|
> | **Classic Architecture**, not Microservices | Phase 8 migrates it. Classic is deprecated at GoldenGate 21c and desupported at 23ai and 26ai, so the migration is real work |
> | **Integrated Extract**, not Classic Capture | Classic Capture is deprecated at 19c and desupported at 21c. Integrated Extract also captures DDL from redo without the trigger-based mechanism |
> | **GoldenGate on `oemserver01`**, not on a RAC node | Approximates the MAA hub: separate from the database servers, co-located with the target. [Appendix A.1](#a1-how-this-relates-to-the-maa-goldengate-hub) |

| # | Task | Status |
|---|---|---|
| 1 | Prerequisites | ⬜ |
| 2 | Prepare the source database | ⬜ |
| 3 | Prepare the target database | ⬜ |
| 4 | Install GoldenGate on the hub | ⬜ |
| 5 | Configure Manager and credentials | ⬜ |
| 6 | Configure Integrated Extract | ⬜ |
| 7 | Configure Replicat | ⬜ |
| 8 | Instantiate the target | ⬜ |
| 9 | Start and verify | ⬜ |
| 10 | Prove it survives a switchover | ⬜ |
| 11 | Rollback | ⬜ |
| | Appendix A: Notes | ⬜ |
| 12 | Screenshot checklist | ⬜ |

---

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Prepare the source database](#2-prepare-the-source-database)
3. [Prepare the target database](#3-prepare-the-target-database)
4. [Install GoldenGate on the hub](#4-install-goldengate-on-the-hub)
5. [Configure Manager and credentials](#5-configure-manager-and-credentials)
6. [Configure Integrated Extract](#6-configure-integrated-extract)
7. [Configure Replicat](#7-configure-replicat)
8. [Instantiate the target](#8-instantiate-the-target)
9. [Start and verify](#9-start-and-verify)
10. [Prove it survives a switchover](#10-prove-it-survives-a-switchover)
11. [Rollback](#11-rollback)
12. [Screenshot checklist](#12-screenshot-checklist)

[Appendix A: Notes](#appendix-a-notes)

---

## The estate this phase depends on

| | |
|---|---|
| Source | `apexdb`, 19.32.0.0.0, **non-CDB**, 2-node RAC on ASM, `usatclust1` (`oradbserv05`, `oradbserv06`) |
| Standby | `apexdb_stby`, 2-node RAC on `usatclust2` (`oradbserv09`, `oradbserv10`), Broker-managed with Fast-Start Failover |
| Role-based services | `apexdb_rw` (`-role PRIMARY`), `apexdb_ro` (`-role PHYSICAL_STANDBY`), [Phase 2 §13](part1-active-data-guard.md#13--confirmed--role-based-services-apexdb_rwapexdb_ro) |
| Target | `ggpdb`, a PDB in `usatcdb` on `oemserver01`, 19.32.0.0.0, filesystem, **no Grid Infrastructure** |
| Hub | `oemserver01`, which also runs the OMS and holds `oempdb` |
| Schema | `NESTWISE`, [`nestwise-app/`](../nestwise-app/README.md) |

---

## 1. Prerequisites

### 1.1 Software

Oracle GoldenGate **19.1.0.0.x for Oracle**, Linux x86-64. The database release on both
sides is 19.32.0.0.0, which every GoldenGate release from 19c to 26ai supports.

> ### 19.1 ships both architectures as two different downloads
>
> | File | Architecture | Used by |
> |---|---|---|
> | `fbo_ggs_Linux_x64_shiphome.zip` | **Classic** | **This phase** |
> | `fbo_ggs_Linux_x64_services_shiphome.zip` | Microservices | Phase 8 |
>
> Same version number, same product page, different zip. The Microservices build
> carries `services` in the filename.
>
> Confirm the download says **for Oracle**. Separate builds exist for MySQL, SQL
> Server and Big Data.

Classic Architecture does not ship after 19c: it is deprecated at 21c and desupported
at 23ai and 26ai. Downloading the Microservices zip at the same time gives Phase 8 its
target without a second trip.

### 1.2 Source database state

Already true from earlier phases. Confirm rather than set:

```sql
-- connect to apexdb as sysdba
SELECT log_mode, force_logging, supplemental_log_data_min FROM v$database;
```

| Check | Expected | Set by |
|---|---|---|
| `LOG_MODE` | `ARCHIVELOG` | Installation |
| `FORCE_LOGGING` | `YES` | [Phase 2 §10](part1-active-data-guard.md#10--confirmed--create-the-standby-database-rman-duplicate) |
| `SUPPLEMENTAL_LOG_DATA_MIN` | `YES` after §2.1 | This phase |

### 1.3 The role-based service resolves from the hub

`apexdb_rw` runs only where the database holds the `PRIMARY` role. It is what makes
Extract follow a switchover.

On `oemserver01`:

```bash
srvctl status service -d apexdb -s apexdb_rw   # run on a cluster node
tnsping APEXDB_RW
sqlplus system@APEXDB_RW
```

Add the alias to `$ORACLE_HOME/network/admin/tnsnames.ora` on `oemserver01`. Both SCANs
must be listed so the descriptor resolves whichever cluster holds the primary:

```
APEXDB_RW =
  (DESCRIPTION =
    (ADDRESS_LIST =
      (ADDRESS = (PROTOCOL = TCP)(HOST = scan-usatclust1.usat.com)(PORT = 1521))
      (ADDRESS = (PROTOCOL = TCP)(HOST = scan-usatclust2.usat.com)(PORT = 1521))
    )
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = apexdb_rw)
    )
  )
```

### 1.4 The target service resolves from the hub

`ggpdb` needs a service of its own, created the same way the repository's was in
[Phase 7d Part 2 §6.4](../monitoring/phase-7d-part2-deployment.md#64-add-a-service-for-the-repository).

```sql
-- connect to usatcdb as sysdba
alter session set container = ggpdb;

begin
  dbms_service.create_service(
    service_name => 'ggpdb_srv',
    network_name => 'ggpdb.usat.com');

  dbms_service.start_service('ggpdb_srv');
end;
/

alter session set container = CDB$ROOT;
alter pluggable database ggpdb save state;
```

Then the trigger, inside the PDB, as the backstop. Same pattern and same reason as
[Phase 7d Part 2 Appendix B.4](../monitoring/phase-7d-part2-deployment.md#b4-lifetime):
a service that does not restart with the PDB took the OMS down once already.

```sql
alter session set container = ggpdb;

create or replace trigger start_gg_service
  after startup on database
declare
  running number;
begin
  select count(*) into running from v$active_services where name = 'ggpdb_srv';
  if running = 0 then
    dbms_service.start_service('ggpdb_srv');
  end if;
end;
/
```

```bash
lsnrctl status | grep -i ggpdb
```

---

## 2. Prepare the source database

**Who:** `oracle` on a `usatclust1` node

### 2.1 Enable GoldenGate replication and supplemental logging

```sql
-- connect to apexdb as sysdba
ALTER SYSTEM SET enable_goldengate_replication = TRUE SCOPE = BOTH SID = '*';

ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER SYSTEM SWITCH LOGFILE;

SELECT supplemental_log_data_min FROM v$database;
```

Expected: `YES`.

### 2.2 Size the streams pool

Integrated Extract runs a logmining server inside the database and draws from
`STREAMS_POOL_SIZE`. A value of zero stops Extract from starting.

```sql
SHOW PARAMETER streams_pool_size
SHOW PARAMETER sga_target

ALTER SYSTEM SET streams_pool_size = 1G SCOPE = BOTH SID = '*';
```

Record the pre-change values. Under Automatic Shared Memory Management a non-zero value
is a **minimum, not a maximum**, the same behaviour that cost Phase 7d a rebuild in
[Part 1 Appendix A](../monitoring/phase-7d-part1-pre-deployment.md#8-appendix-a-the-template-does-not-carry-automatic-shared-memory-management).

### 2.3 Create the GoldenGate user

`apexdb` is a **non-CDB**, so this is a normal user. No `c##` prefix is involved.

```sql
CREATE USER ggadmin IDENTIFIED BY <password>
  DEFAULT TABLESPACE users
  TEMPORARY TABLESPACE temp
  QUOTA UNLIMITED ON users;

GRANT CREATE SESSION, CONNECT, RESOURCE, ALTER SYSTEM TO ggadmin;
GRANT SELECT ANY DICTIONARY TO ggadmin;
GRANT FLASHBACK ANY TABLE TO ggadmin;

EXEC dbms_goldengate_auth.grant_admin_privilege('GGADMIN');
```

### 2.4 Add schema-level supplemental logging

Run from GGSCI after §5, not here. Listed at this point because it belongs to the
source preparation and is easy to forget:

```
DBLOGIN USERIDALIAS apexdb_rw
ADD SCHEMATRANDATA NESTWISE ALLCOLS
INFO SCHEMATRANDATA NESTWISE
```

`ADD SCHEMATRANDATA` covers tables added later. `ADD TRANDATA` does not, which matters
because DDL is in scope.

---

## 3. Prepare the target database

**Who:** `oracle` on `oemserver01`

### 3.1 Enable GoldenGate replication

`enable_goldengate_replication` is a CDB-level parameter. Set it in the root, not in
the PDB.

```sql
-- connect to usatcdb as sysdba
ALTER SYSTEM SET enable_goldengate_replication = TRUE SCOPE = BOTH;
```

### 3.2 Create the GoldenGate user inside the PDB

Replicat connects to the PDB and never to the root, so this is a **local** user in
`ggpdb`.

```sql
alter session set container = ggpdb;

CREATE USER ggadmin IDENTIFIED BY <password>
  DEFAULT TABLESPACE users
  TEMPORARY TABLESPACE temp
  QUOTA UNLIMITED ON users;

GRANT CREATE SESSION, CONNECT, RESOURCE TO ggadmin;
GRANT SELECT ANY DICTIONARY TO ggadmin;

EXEC dbms_goldengate_auth.grant_admin_privilege('GGADMIN');
```

### 3.3 Create the target schema

```sql
alter session set container = ggpdb;

CREATE USER nestwise IDENTIFIED BY <password>
  DEFAULT TABLESPACE users
  TEMPORARY TABLESPACE temp
  QUOTA UNLIMITED ON users;

GRANT CREATE SESSION, RESOURCE TO nestwise;
```

`ggadmin` needs the privileges to create objects in it, because DDL is in scope:

```sql
GRANT CREATE ANY TABLE, ALTER ANY TABLE, DROP ANY TABLE,
      CREATE ANY INDEX, ALTER ANY INDEX, DROP ANY INDEX,
      INSERT ANY TABLE, UPDATE ANY TABLE, DELETE ANY TABLE,
      SELECT ANY TABLE TO ggadmin;
```

---

## 4. Install GoldenGate on the hub

**Who:** `oracle` on `oemserver01`

```bash
mkdir -p /u01/app/oracle/staging/gg
cd /u01/app/oracle/staging/gg
unzip -q <goldengate 19c for oracle 19c, linux x86-64>.zip
```

Run the installer, selecting **Oracle GoldenGate for Oracle Database 19c**:

```bash
cd fbo_ggs_Linux_x64_shiphome/Disk1
./runInstaller
```

| Prompt | Value |
|---|---|
| Software Location | `/u01/app/oracle/product/ogg19c` |
| Start Manager | No. Section 5 configures it first |
| Database Location | `/u01/app/oracle/product/19.3.0/db_1` |

The database home on `oemserver01` supplies the Oracle libraries Extract and Replicat
link against. It is already there from
[Phase 7a](../monitoring/phase-7a-repository-db-ru32.md).

```bash
export OGG_HOME=/u01/app/oracle/product/ogg19c
export ORACLE_HOME=/u01/app/oracle/product/19.3.0/db_1
export LD_LIBRARY_PATH=$ORACLE_HOME/lib:$OGG_HOME/lib:$LD_LIBRARY_PATH
export PATH=$OGG_HOME:$ORACLE_HOME/bin:$PATH

cd $OGG_HOME
./ggsci
```

```
GGSCI> CREATE SUBDIRS
GGSCI> EXIT
```

---

## 5. Configure Manager and credentials

### 5.1 Manager

```
GGSCI> EDIT PARAMS MGR
```

```
PORT 7809
DYNAMICPORTLIST 7810-7860
PURGEOLDEXTRACTS ./dirdat/*, USECHECKPOINTS, MINKEEPDAYS 3
AUTORESTART ER *, RETRIES 5, WAITMINUTES 2, RESETMINUTES 60
```

```
GGSCI> START MGR
GGSCI> INFO MGR
```

### 5.2 Credential store

Passwords go in the credential store, not in parameter files.

```
GGSCI> ADD CREDENTIALSTORE

GGSCI> ALTER CREDENTIALSTORE ADD USER ggadmin@APEXDB_RW ALIAS apexdb_rw
GGSCI> ALTER CREDENTIALSTORE ADD USER ggadmin@ggpdb.usat.com ALIAS ggpdb

GGSCI> INFO CREDENTIALSTORE
```

Two aliases, two different databases. `apexdb_rw` is the role-based service; `ggpdb` is
the service created in §1.4.

### 5.3 Add schema-level supplemental logging

```
GGSCI> DBLOGIN USERIDALIAS apexdb_rw
GGSCI> ADD SCHEMATRANDATA NESTWISE ALLCOLS
GGSCI> INFO SCHEMATRANDATA NESTWISE
```

---

## 6. Configure Integrated Extract

### 6.1 Register the Extract with the source database

Registration creates the logmining server. It runs **in** `apexdb`, while Extract runs
on the hub.

```
GGSCI> DBLOGIN USERIDALIAS apexdb_rw
GGSCI> REGISTER EXTRACT ENW SCN
```

Record the SCN returned. [§8](#8-instantiate-the-target) uses it.

### 6.2 Extract parameters

```
GGSCI> EDIT PARAMS ENW
```

```
EXTRACT ENW
USERIDALIAS apexdb_rw
TRANLOGOPTIONS INTEGRATEDPARAMS (MAX_SGA_SIZE 1024)
EXTTRAIL ./dirdat/nw
DDL INCLUDE MAPPED
DDLOPTIONS REPORT
LOGALLSUPCOLS
UPDATERECORDFORMAT COMPACT
TABLE NESTWISE.*;
```

```
GGSCI> ADD EXTRACT ENW, INTEGRATED TRANLOG, BEGIN NOW
GGSCI> ADD EXTTRAIL ./dirdat/nw, EXTRACT ENW, MEGABYTES 100
```

`INTEGRATED TRANLOG` is what makes this Integrated Extract. `TRANLOG` alone would be
Classic Capture, which is deprecated at 19c and desupported at 21c.

### 6.3 No pump is required

Extract and Replicat share a host, so the trail Extract writes is the trail Replicat
reads. A pump exists to move trails between hosts.

Phase 8 changes this. [Appendix A.3](#a3-what-phase-8-has-to-change) lists what.

---

## 7. Configure Replicat

### 7.1 Checkpoint table

```
GGSCI> DBLOGIN USERIDALIAS ggpdb
GGSCI> ADD CHECKPOINTTABLE ggadmin.ggs_checkpoint
```

### 7.2 Replicat parameters

```
GGSCI> EDIT PARAMS RNW
```

```
REPLICAT RNW
USERIDALIAS ggpdb
DDL INCLUDE MAPPED
DDLOPTIONS REPORT
ASSUMETARGETDEFS
DISCARDFILE ./dirrpt/rnw.dsc, APPEND, MEGABYTES 100
MAP NESTWISE.*, TARGET NESTWISE.*;
```

```
GGSCI> ADD REPLICAT RNW, EXTTRAIL ./dirdat/nw, CHECKPOINTTABLE ggadmin.ggs_checkpoint
```

> ### Replicat connects to the PDB, never to the root
>
> Oracle's rule for multitenant targets: *"Replicat can only connect and apply to one
> pluggable database."* `USERIDALIAS ggpdb` resolves to `ggpdb.usat.com`, which is a
> PDB service.
>
> The asymmetry is the point. Extract against a CDB source must connect to `CDB$ROOT`
> as a `c##` common user; Replicat must not. Here the source is a non-CDB, so only the
> Replicat half of that rule applies.

---

## 8. Instantiate the target

The target schema has to match the source as of the SCN from §6.1.

### 8.1 Export from the source

```bash
expdp system@APEXDB_RW \
  schemas=NESTWISE \
  directory=DATA_PUMP_DIR \
  dumpfile=nestwise_%U.dmp \
  logfile=nestwise_exp.log \
  flashback_scn=<the SCN from 6.1>
```

`FLASHBACK_SCN` is what ties the export to the Extract registration. Without it the
target is consistent with no particular point and Replicat will apply changes that are
already in the data.

### 8.2 Import into the PDB

Copy the dump to `oemserver01`, then:

```bash
impdp system@ggpdb.usat.com \
  schemas=NESTWISE \
  directory=DATA_PUMP_DIR \
  dumpfile=nestwise_%U.dmp \
  logfile=nestwise_imp.log
```

### 8.3 Position Replicat after the SCN

```
GGSCI> START EXTRACT ENW
GGSCI> START REPLICAT RNW, AFTERCSN <the SCN from 6.1>
```

`AFTERCSN` makes Replicat discard everything already contained in the export.

---

## 9. Start and verify

```
GGSCI> INFO ALL
GGSCI> STATS EXTRACT ENW, TOTAL
GGSCI> STATS REPLICAT RNW, TOTAL
GGSCI> LAG EXTRACT ENW
GGSCI> LAG REPLICAT RNW
```

Both `RUNNING`, lag reducing to seconds.

Prove it end to end with a DML change and a DDL change:

```sql
-- on apexdb
INSERT INTO nestwise.<a table> VALUES (...);
COMMIT;

ALTER TABLE nestwise.<a table> ADD (gg_probe VARCHAR2(10));
COMMIT;
```

```sql
-- on ggpdb
SELECT COUNT(*) FROM nestwise.<the same table>;
SELECT column_name FROM dba_tab_columns
WHERE owner = 'NESTWISE' AND column_name = 'GG_PROBE';
```

| # | Check | Expected |
|---|---|---|
| 1 | `INFO ALL` | Manager, `ENW` and `RNW` all `RUNNING` |
| 2 | Row counts per table | Source and target match |
| 3 | The DML probe | Present in `ggpdb` |
| 4 | The DDL probe | `GG_PROBE` column present in `ggpdb` |
| 5 | `./dirrpt/RNW.dsc` | Empty |
| 6 | `STATS` | Inserts, updates and deletes counted on both sides |

---

## 10. Prove it survives a switchover

This is what the hub placement and the role-based service were for. Without this step
the design is asserted rather than demonstrated.

### 10.1 Baseline under load

Start a Swingbench run against `apexdb`, per
[`tools/swingbench/`](../tools/swingbench/README.md), so there is traffic to replicate
during the role change.

```
GGSCI> LAG EXTRACT ENW
```

### 10.2 Switch over

```bash
dgmgrl sys@apexdb
DGMGRL> SWITCHOVER TO apexdb_stby;
```

Full procedure in
[Phase 2 Part 2](part2-broker-fsfo-observer.md).

### 10.3 Confirm the service and Extract followed

```bash
srvctl status service -d apexdb -s apexdb_rw
```

`apexdb_rw` should now be running on `usatclust2`.

```
GGSCI> INFO EXTRACT ENW, DETAIL
GGSCI> LAG EXTRACT ENW
GGSCI> STATS EXTRACT ENW, TOTAL
```

| # | Check | Expected |
|---|---|---|
| 1 | `apexdb_rw` | Running on the new primary |
| 2 | `ENW` | `RUNNING`, having reconnected through the same alias |
| 3 | Lag | Recovers to its pre-switchover level |
| 4 | Target row counts | Catch up to the source with no gap |

Record how long Extract took to reconnect. That number is the phase's headline result.

### 10.4 Switch back

Re-run §10.2 in the other direction and repeat §10.3.

---

## 11. Rollback

Nothing in this phase changes the source data. Removal is:

```
GGSCI> STOP REPLICAT RNW
GGSCI> STOP EXTRACT ENW
GGSCI> DBLOGIN USERIDALIAS apexdb_rw
GGSCI> UNREGISTER EXTRACT ENW DATABASE
GGSCI> DELETE EXTRACT ENW
GGSCI> DBLOGIN USERIDALIAS ggpdb
GGSCI> DELETE REPLICAT RNW
GGSCI> STOP MGR
```

```sql
-- on apexdb
ALTER DATABASE DROP SUPPLEMENTAL LOG DATA;
ALTER SYSTEM SET enable_goldengate_replication = FALSE SCOPE = BOTH SID = '*';
```

`UNREGISTER EXTRACT ... DATABASE` removes the logmining server. Deleting the Extract
without unregistering leaves it behind, holding redo.

The `NESTWISE` schema in `ggpdb` can be dropped; `ggpdb` itself stays, since it was
created for this phase and Phase 8 reuses it.

---

## 12. Screenshot checklist

All files go in [`screenshots/4/`](screenshots/4/), named `4-NN-slug.png`.

| File | Section | Shows | Status |
|---|---|---|---|
| `4-01-source-prereqs.png` | 2 | `enable_goldengate_replication`, supplemental logging, streams pool | ⬜ |
| `4-02-schematrandata.png` | 5.3 | `INFO SCHEMATRANDATA NESTWISE` | ⬜ |
| `4-03-register-extract.png` | 6.1 | `REGISTER EXTRACT ENW SCN` and the SCN returned | ⬜ |
| `4-04-info-all-running.png` | 9 | `INFO ALL` with Manager, `ENW` and `RNW` running | ⬜ |
| `4-05-dml-ddl-probe.png` | 9 | The probe row and the `GG_PROBE` column in `ggpdb` | ⬜ |
| `4-06-lag-baseline.png` | 10.1 | Lag under Swingbench load before the switchover | ⬜ |
| `4-07-service-relocated.png` | 10.3 | `apexdb_rw` running on `usatclust2` | ⬜ |
| `4-08-extract-reconnected.png` | 10.3 | `ENW` running after the switchover | ⬜ |

---

## Appendix A: Notes

### A.1 How this relates to the MAA GoldenGate Hub

Oracle's Maximum Availability Architecture recommendation for GoldenGate is the
**GoldenGate Hub**: a separate two-node cluster, the deployment and trails on ACFS,
processes managed by Oracle Clusterware through the Standalone Agents behind a VIP, and
ACFS replication between a primary and a standby hub. The hub sits with the **target**
for latency.

**MAA's hub is Microservices.** Classic Architecture is not the MAA answer, which is
why Phase 8 exists.

What this build takes from it and what it does not:

| MAA element | Here |
|---|---|
| Hub separate from the database servers | 🟩 `oemserver01`, on neither cluster |
| Hub co-located with the target | 🟩 `ggpdb` is on `oemserver01` |
| Role-based service so Extract follows the primary | 🟩 `apexdb_rw`, from Phase 2 |
| ACFS for deployment, trails and checkpoints | ⬜ `oemserver01` runs no Grid Infrastructure |
| XAG, Clusterware and a VIP | ⬜ Same reason |
| Standby hub with ACFS replication | ⬜ Out of scope |

The three that are present are the ones that change behaviour during a switchover. The
three that are absent all address hub node failure, which this lab does not protect
against.

### A.2 Why Integrated Extract rather than Classic Capture

| | Classic Capture | Integrated Extract |
|---|---|---|
| Status at 19c | Deprecated | Current |
| Status at 21c | **Desupported** | Current |
| Reads redo | Directly from the log files | Through a logmining server inside the database |
| RAC | Needs access to every thread's redo | Handled by the database |
| DDL capture | Trigger and marker tables, `ddl_setup.sql` | Native, from redo |
| Multitenant | Not supported | Required |

DDL is in scope for this phase, which alone decides it. Classic Capture would also
have to be replaced before Phase 9 takes anything past 19c.

**Classic Capture and Classic Architecture are different things.** This phase uses
Classic **Architecture**, the GGSCI and Manager deployment model, with Integrated
Extract inside it. Phase 8 replaces the architecture and keeps Integrated Extract.

### A.3 What Phase 8 has to change

Recorded now so the migration has a starting list:

**Which release.** 19.1 ships Microservices as its own zip, so Phase 8 can be a pure
architecture migration on one version, changing a single variable. Jumping to 26ai
instead changes the architecture and the release together. The Classic to Microservices
**migration utility** is documented under the 26ai set; 19.1's documentation covers
connecting the two architectures, which is interoperability rather than migration. If
the utility is the point of Phase 8, the release has to be one that ships it.

> ### The 26ai download is labelled 23.4
>
> | Where | What it reads |
> |---|---|
> | Marketing name and documentation set | Oracle GoldenGate **26ai**, docs under `/core/26/` |
> | Download page | **23.4** |
> | The release it supersedes | 23ai, which reached **23.9** in September 2025 |
>
> A product named 26ai therefore carries a lower-looking number than the release before
> it. There is no separate 26-numbered download. Confirmed on the download page,
> 2026-09-18.
>
> Verify what actually landed rather than trusting the label:
>
> ```bash
> $OGG_HOME/ggsci
> GGSCI> VERSIONS
> ```

| Classic here | Microservices equivalent |
|---|---|
| GGSCI | Admin Client and the REST API |
| Manager process, `MGR` parameter file | Service Manager, Administration Service, Distribution Service, Receiver Service |
| `./dirdat`, `./dirprm`, `./dirrpt` under one home | A deployment, with its own directory layout |
| Credential store via `ADD CREDENTIALSTORE` | Credential store inside the deployment |
| No pump, single host | Distribution Service and Receiver Service, even on one host |
| Parameter files edited with `EDIT PARAMS` | The same parameter files, reachable through the web UI and the API |

Oracle ships a migration utility for Classic to Microservices. The Extract and Replicat
parameter files largely survive; the surrounding deployment does not.

### A.4 Why no pump

A pump, or data pump Extract, is a secondary Extract that reads a local trail and
writes to a remote one. Its job is moving trail files between hosts.

Extract and Replicat are on the same host here, reading and writing the same trail, so
there is nothing to move. Adding a pump would add a process and a failure mode for no
benefit.

If GoldenGate later moves onto a RAC node, or a second target is added, a pump comes
back.

---

**Sources:**
[Oracle GoldenGate 19c, Using Integrated Extract, Classic Architecture](https://docs.oracle.com/en/middleware/goldengate/core/19.1/ggcab/integrated-extract.html) ·
[Configuring Oracle GoldenGate in a Multitenant Container Database](https://docs.oracle.com/en/middleware/goldengate/core/21.3/oracle-db/configuring-oracle-goldengate-multitenant-container-database-1.html),
the rule that Replicat connects only to a PDB and never to the root ·
[`REGISTER EXTRACT`, Command Line Interface Reference 19c](https://docs.oracle.com/en/middleware/goldengate/core/19.1/gclir/register-extract.html) ·
[Planning GGHub Placement in the Platinum MAA Architecture, 19c](https://docs.oracle.com/en/database/oracle/oracle-database/19/haovw/gghub-cloud-one-region-planning-hub-placement-platinum-maa-architecture.html),
the hub design this phase approximates ·
[Migrate from Classic to Microservices Architecture Using the Migration Utility](https://docs.oracle.com/en/database/goldengate/core/26/coredoc/migration-utility-migrate-classic-ma.html),
the Phase 8 route

---

Back to the **[High Availability index](README.md)**.
