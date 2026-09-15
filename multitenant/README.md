# Multitenant

**CDB and PDB administration across this estate: what is built, and where it lives**

Multitenant is one of the areas the Oracle Certified Master 19c practical blueprint
centres on, alongside database and network configuration, tablespace and undo
management, backup and recovery, and performance tuning.

Status: 🟨 In progress. One build, filed with the phase it belongs to. Phase 7d's
container exists; the plug-in window has not opened.

| Topic | Covers | Where | Status |
|---|---|---|---|
| **Moving a non-CDB into a container** | A 19.32 non-CDB plugged into a new container as a PDB using `DBMS_PDB.DESCRIBE`, `CHECK_PLUG_COMPATIBILITY`, `CREATE PLUGGABLE DATABASE ... USING` and `noncdb_to_pdb.sql`, plus the Enterprise Manager side of moving a live repository | [`monitoring/phase-7d-noncdb-to-pdb.md`](../monitoring/phase-7d-noncdb-to-pdb.md) | 🟨 In progress |
| Creating and managing PDBs | `ggpdb` created from `PDB$SEED`, `SAVE STATE`, service registration | [Phase 7d Part 1 §5](../monitoring/phase-7d-part1-pre-deployment.md#5-create-ggpdb) | 🟨 In progress |
| Patching a container | `datapatch` across `CDB$ROOT` and every PDB, rather than the single-database path | [Phase 7d Part 3 §4](../monitoring/phase-7d-part3-post-deployment.md#4-close-the-dormant-ansible-branch) | ⬜ Planned |

---

## Why the pages live under `monitoring/`

The database being converted is the Enterprise Manager repository, and more than half
of the work is Enterprise Manager configuration rather than database administration:
three separate connect descriptor commands, the emkey, the monitored target
repointing, and a CDB detection branch in the `oem_repo_patch` Ansible role that has
been dormant since it was written.

Splitting that from the multitenant half would leave neither readable, so the pages
stay with Phase 7a to 7c, which is where that Enterprise Manager story runs. This page
exists so the skill area is reachable from the top navigation rather than only by
knowing to look under Monitoring.

The same pattern is used by [`tools/`](../tools/README.md) for the Autonomous Health
Framework.

---

## What is not here yet

| Topic | Expected in |
|---|---|
| Upgrading a container to a later release | Phase 9, 19c to 26ai |
| GoldenGate against a PDB | Phase 4, using `ggpdb` |
| Cloning and relocating PDBs | Not scoped |
| Application containers | Not scoped |

---

*Nothing on this page is a separate build. It is an index into work filed elsewhere.*
