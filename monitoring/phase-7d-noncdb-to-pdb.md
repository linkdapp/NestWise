# Phase 7d: Moving the Enterprise Manager repository into a container database

**SOP: `oemcdb` on `oemserver01`, a 19.32.0.0.0 non-CDB, plugged into a new container database as `oempdb`, Oracle Linux**

The phase index for Enterprise Manager is
[`README.md`](README.md). [Phase 7c](phase-7c-oms-upgrade.md) took the OMS and every
agent to 24ai Release 1 Update 12 and left the repository a non-CDB, which 24ai
supports. This phase changes that.

> ### Also filed under Multitenant
>
> This is the only CDB and PDB work in the repository. It is indexed by skill area
> from **[Multitenant: CDB and PDB administration across this estate](../multitenant/README.md)**.
>
> The pages live here rather than there because the database being converted is the
> Enterprise Manager repository, and half the procedure is Enterprise Manager
> configuration.

Status: 🟨 **In progress.** The window is closed. The repository runs as `oempdb`
inside `usatcdb` and the console is served from it. Part 3 is outstanding.

| Part | Covers | Downtime | Status |
|---|---|---|---|
| [Part 1: Pre-deployment](phase-7d-part1-pre-deployment.md) | Record the source state, clear the eight compatibility gates, size the target, build `usatcdb` and `ggpdb`, prove the service name descriptor | **None** | 🟩 Confirmed 2026-09-15 |
| [Part 2: Deployment](phase-7d-part2-deployment.md) | Stop the stack, describe the non-CDB, plug it in as `oempdb`, run `noncdb_to_pdb.sql`, add the repository service, repoint the OMS | **The window** | 🟩 Confirmed 2026-09-15 |
| [Part 3: Post-deployment](phase-7d-part3-post-deployment.md) | Repoint the repository target, close the dormant Ansible branch, verify, retire the old non-CDB | None | ⬜ |

Start with Part 1.

---

## A non-CDB is not converted into a container

There is no in-place conversion. A new container database is created, and the
existing non-CDB is plugged into it as a pluggable database. `oemcdb` does not become
a container; its contents become `oempdb` inside a container that does not exist yet.

| Object | Before | After |
|---|---|---|
| Container database | none | `usatcdb` |
| Repository | `oemcdb`, a non-CDB | `oempdb`, a PDB in `usatcdb` |
| GoldenGate database | none | `ggpdb`, an empty PDB in `usatcdb` |


---

## Why plug as PDB

Oracle offers three routes. This estate meets the conditions for the cheapest one.

| Method | What it does | Used here |
|---|---|---|
| **Plug as PDB** | `DBMS_PDB.DESCRIBE` writes an XML manifest of the non-CDB's datafiles, and `CREATE PLUGGABLE DATABASE ... USING` adopts them. No data is unloaded or reloaded | 🟩 Yes |
| Data Pump full transportable | Exports from the non-CDB and imports into an empty PDB. Crosses platforms and versions | ⬜ No |
| AutoUpgrade with `target_cdb` | Upgrades and converts in one pass | ⬜ No |

Plug as PDB requires the source and target to share endianness, release and patch
level. Both sides are the same host and the same Oracle home, so all three hold by
construction. Data Pump's strengths are cross-platform and cross-version moves and
neither applies. AutoUpgrade's upgrade half would do nothing at a fixed 19.32, and
Phase 9 already gives AutoUpgrade its own window against
19c to 26ai.

---

## Why this phase exists

**Non-CDB is desupported from Oracle Database 21c onward.** `oemcdb` cannot go past
19c while it remains one, so this is the gate in front of any future repository
upgrade.

It was **not** a prerequisite for Phase 7c. 24ai supports pluggable database, lone
pluggable database and non-container database repositories, which is why the 24ai
upgrade ran against a non-CDB unchanged.

`ggpdb` is created in the same window because the container is being built anyway.
GoldenGate itself is Phase 4.

---

## Enterprise Manager cannot migrate its own repository

`emcli migrate_noncdb_to_pdb` exists and takes a `-migrationMethod=PLUG_AS_PDB`
argument, which makes it look like the tool for this job. It is not.

That verb drives a migration job through the OMS against a **monitored** target. The
repository is the database the OMS runs on, so the OMS stops the moment the source
database is shut down and the job has nothing left to run in. The repository move is
performed by hand at the SQL level, and Enterprise Manager is told about the result
afterwards.

Two commands do the telling, both in Part 2 and Part 3:

| Command | Changes |
|---|---|
| `emctl config oms -store_repos_details` | Where the OMS connects to reach its repository |
| `emctl config emrep -conn_desc` | How the Management Services and Repository target is monitored |

---

## Gates

Each is verified in [Part 1](phase-7d-part1-pre-deployment.md) before the container is
built. A failure on any of them stops the phase rather than the window. Gates 1 to 5
and 7 are enforced by `DBMS_PDB.CHECK_PLUG_COMPATIBILITY`; gate 8 is enforced later,
by `noncdb_to_pdb.sql`.

| # | Gate | Why |
|---|---|---|
| 1 | Release and patch level identical between source and target | `usatcdb` is created from `/u01/app/oracle/product/19.3.0/db_1`, the same home, so both are 19.32.0.0.0 |
| 2 | Character set and national character set match | A mismatch fails the plug-in. `dbca` does not default to the source's setting |
| 3 | `COMPATIBLE` matches | Carried into the PDB |
| 4 | Time zone file version matches | A higher version in the container forces an upgrade of the PDB after plug-in |
| 5 | Every component in the non-CDB exists in the container | Checked by `DBMS_PDB.CHECK_PLUG_COMPATIBILITY` |
| 6 | Disk for a second copy of the datafiles | `COPY` leaves the source intact, which is what makes rollback a restart rather than a restore |
| 7 | No encrypted tablespaces | TDE is Phase 5. If it lands first, the keystore has to be exported and imported with the PDB |
| 8 | No unconverted Oracle-maintained type data | Checked by `noncdb_to_pdb.sql` rather than by `CHECK_PLUG_COMPATIBILITY`, so it stops the run in Part 2 §6 rather than at §5 |

---

## Estate facts this phase depends on

| | |
|---|---|
| Host | `oemserver01`, single instance, **no Grid Infrastructure**, so datafiles are on a filesystem rather than ASM |
| Oracle home | `/u01/app/oracle/product/19.3.0/db_1` |
| Source SID | `oemcdb`, 19.32.0.0.0, non-CDB, [Phase 7a](phase-7a-repository-db-ru32.md) |
| OMS | 24ai Release 1 Update 12, `/u01/app/oracle/Middleware/24ai`, [Phase 7c](phase-7c-oms-upgrade.md) |
| Console | `https://oemserver01.usat.com:7803/em` |
| Staging | `/u01/app/oracle/staging` |

---

## What this feeds into

- **Any repository release past 19c.** Non-CDB is desupported from 21c, so this is
  the gate in front of that move.
- **Phase 4, GoldenGate Classic.** `ggpdb` is created here and populated there.

---

**Sources:**
[Oracle Multitenant Administrator's Guide 19c](https://docs.oracle.com/en/database/oracle/oracle-database/19/multi/index.html),
the `DBMS_PDB.DESCRIBE`, `CHECK_PLUG_COMPATIBILITY` and `noncdb_to_pdb.sql` sequence ·
[Administering PDBs with SQL\*Plus, Multitenant Administrator's Guide 19c](https://docs.oracle.com/en/database/oracle/oracle-database/19/multi/administering-pdbs-with-sql-plus.html),
the default PDB service, why it is for administration only, and the rule that
`CREATE_SERVICE` attaches a service to the current container ·
[`DBMS_SERVICE`, PL/SQL Packages and Types Reference 19c](https://docs.oracle.com/en/database/oracle/oracle-database/19/arpls/DBMS_SERVICE.html),
the `service_name` and `network_name` parameters and the `ORA-44302` and `ORA-44303`
exceptions ·
[`CREATE PLUGGABLE DATABASE`, SQL Language Reference 19c](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/CREATE-PLUGGABLE-DATABASE.html),
the `COPY`, `NOCOPY` and `MOVE` clauses and `FILE_NAME_CONVERT` ·
[Manual Non-CDB Release Upgrades to Multitenant Architecture, Upgrade Guide 21c](https://docs.oracle.com/en/database/oracle/oracle-database/21/upgrd/upgrade-scenarios-non-cdb-oracle-databases.html),
which is also where non-CDB desupport is stated ·
[Enterprise Manager High Availability, Administrator's Guide 24ai](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/24.1/emadv/enterprise-manager-high-availability.html),
the source for `emctl config oms -store_repos_details` and `emctl config emrep` ·
[`migrate_noncdb_to_pdb`, EM CLI Verb Reference](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/13.4/emcli/migrate_noncdb_to_pdb.html),
the verb this phase deliberately does not use ·
`emctl config oms -help` on `oemserver01`, the authority for the `store_repos_details`
sequence and its two parameter shapes

### Field report consulted

Read against the documentation above and cited where it contributed a step Oracle's
documents do not spell out. It is not a substitute for them.

- Asanga Pradeep,
  [Converting EM Repository DB from non-CDB to PDB](https://asanga-pradeep.blogspot.com/2021/09/converting-em-repository-db-from-non.html),
  September 2021, against EM 13.4. Four things taken from it: building the container
  from a template captured off the existing repository rather than from
  `General_Purpose.dbc`, so the memory parameters, redo sizing and hidden parameters
  come with it ([Part 1 §4.2](phase-7d-part1-pre-deployment.md#42-capture-a-template-from-the-existing-repository));
  proving a service name descriptor against the source **before** the window
  ([Part 1 §7](phase-7d-part1-pre-deployment.md#7-prove-a-service-name-descriptor-reaches-the-repository));
  the `dbsnmp` common user arriving locked in a new container
  ([Part 3 §1.2](phase-7d-part3-post-deployment.md#1-repoint-the-repository-target));
  and two targets that keep the old SID in their monitoring configuration even after
  `-list_repos_details` reports the service name
  ([Part 3 §1.3](phase-7d-part3-post-deployment.md#1-repoint-the-repository-target))

---

## Screenshots

Phase 7d's screenshots go in [`screenshots/7d/`](screenshots/7d/), not in the flat
`screenshots/` directory alongside them.

`monitoring/screenshots/` holds 180 files from Phases 7a, 7b and 7c under four
different naming schemes, and the collision it has already produced is recorded on the
[7c index](phase-7c-oms-upgrade.md#screenshots): Phase 7b's images carry a `7c-` prefix
because they were captured before the phase letters were swapped.

A subdirectory keeps the paths sibling-relative to the pages that embed them,
`screenshots/7d/7d1-01-source-state.png`, and keeps the phase's images together if
these pages ever move.

Files are named `7dN-NN-slug.png`, where `N` is the part number. Each part carries its
own checklist.

## Appendix: what this closes

Two places in this repository already carry a dormant branch waiting for this phase.
Part 3 closes both.

- **[`phase-7a-ansible.md`](phase-7a-ansible.md#design-notes-for-anyone-editing-the-role).**
  The `oem_repo_patch` role detects CDB against non-CDB and keeps an
  `ALTER PLUGGABLE DATABASE ALL OPEN` branch that has never executed. From this phase
  on it does.
- **[`phase-7a-part3-verification.md` §13.1](phase-7a-part3-verification.md#13-datapatch-the-step-people-forget).**
  Records that the branch stays in the role permanently because "Phase 7d converts
  this database, and the day it does, the branch has to already be there."

---