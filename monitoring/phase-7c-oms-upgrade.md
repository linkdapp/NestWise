# Phase 7c: Upgrading Enterprise Manager from 13.5 to 24ai

**SOP: `oemserver01` (Oracle Linux) and the `oemcdb` repository, 13.5.0.0.0 to 24ai Release 1 Update 12**

Status: 🟩 **Confirmed 2026-09-13.** Both parts are complete. The OMS and all six
agents run 24ai Release 1 Update 12.

| Part | Covers | Status |
|---|---|---|
| [Part 1: Patching the OMS to 13.5 RU33](phase-7c-part1-oms-ru33.md) | Sections 1 to 10: OMSPatcher upgrade, JDBC prerequisites, the property file, analyze, the patch window, verification, rollback | 🟩 Confirmed 2026-09-06 |
| [Part 2: Upgrading the OMS to 24ai Release 1](phase-7c-part2-24ai-upgrade.md) | Split into three: [2a Pre-deployment](phase-7c-part2a-pre-deployment.md), [2b Deployment](phase-7c-part2b-deployment.md), [2c Post-deployment](phase-7c-part2c-post-deployment.md) | 🟩 Confirmed 2026-09-13 |

---

## The result

| | |
|---|---|
| OMS version | 13.5.0.0.0 to 13.5.0.33 to **24ai Release 1 Update 12 (24.1.0.12)** |
| Central agent | 13.5.0.0.0 to **24.1.0.0.0** |
| Repository database | `oemcdb`, 19.32.0.0.0, non-CDB, unchanged by the upgrade |
| 24ai Middleware home | `/u01/app/oracle/Middleware/24ai` |
| 24ai agent base | `/u01/app/oracle/Middleware/agent24` |
| Console | `https://oemserver01.usat.com:7803/em`, unchanged |
| Part 1 window | 2026-09-06 |
| Part 2 window | 2026-09-12 |

---

## Starting state

Recorded by earlier phases and confirmed in Part 1 §3.

| | |
|---|---|
| Host | `oemserver01.usat.com` |
| OMS version | 13c Release 5, `13.5.0.0.0` |
| Middleware Oracle Home | `/u01/app/oracle/Middleware/oms/13.5` |
| Central agent | 13.5.0.0.0, `/u01/app/oracle/Middleware/agent/13_5` |
| Repository database | `oemcdb`, **19.32.0.0.0**, non-CDB, single instance |
| OMS topology | Single OMS, no Server Load Balancer, no standby |
| Single sign-on | None. Relevant because **OAM SSO is not supported in 24ai** |

**Single OMS.** There is no rolling option. The OMS goes down for the apply and
every monitored target is unmonitored for the duration. Blackout first.

**No Release Update had ever been applied.** Three consequences at Part 1, all
documented in the RU33 README: Rapid Platform Update was unavailable for that
first RU, the rollback patch id list was the simple one rather than the one
behind KB390077, and the PNEWS1628 post-patch step had not been run before.

---

## Why two parts, in this order

Three version floors apply: **OMS at 13.5 with RU22 or later**, **repository
database at 19.22 or later in 19c**, and a **24ai target Release Update decided
by the starting 13.5 Release Update**.

The 24ai Upgrade Guide's prerequisites chapter names only 13c Release 5 and the
repository database version. The Release Update floor is in My Oracle Support
KB590189, along with the matrix that ties the starting Release Update to the
minimum 24ai target. At 13.5.0.33 the target had to be **24ai RU06 or later**,
which is why Part 2 used the **Upgrade software only with plug-ins and Configure
Later** method. RU12 was applied.

Part 1 cleared the OMS floor with margin and carried accumulated fixes onto an
OMS that had never had a Release Update applied.

Two floors were already cleared by earlier phases, neither of them for this
reason:

| Floor | Cleared by | Value |
|---|---|---|
| Repository database 19.22 or later | [Phase 7a](phase-7a-repository-db-ru32.md) | 19.32.0.0.0 |
| Agents at 13c Release 5 | [Phase 7b](phase-7b-extending-coverage.md) | 13.5.0.0.0 across the six agents in scope |

---

## What stays manual

Five things, each for a stated reason in
[Part 1 Appendix B](phase-7c-part1-oms-ru33.md#appendix-b-what-stays-manual-and-why):
creating and clearing the blackout, creating the WebLogic property file, the
`sys` prompt during the apply, the PNEWS1628 post-patch step, and rollback.

The common thread is credentials. The blackout needs `emcli` and `sysman` login
credentials, and the property file needs the WebLogic Administration Server
password. Neither belongs in this repository, in `group_vars`, or on a command
line where it lands in the process table.

Creating the blackout has its own page:
**[Creating a Blackout in Enterprise Manager 13.5](oem-create-blackout.md)**.

---

## What this feeds into

- **[Phase 7d](phase-7d-noncdb-to-pdb.md).** Plug `oemcdb` into a new container as
  `oempdb` and create `ggpdb` alongside it. Not a prerequisite for 7c, since 24ai
  supports a non-CDB repository. It remains a prerequisite for taking this database
  past 19c.

---

## Screenshots

Screenshots live in [`screenshots/`](screenshots/), numbered to each part's own
section numbers, the same convention as
[`../installation/README.md`](../installation/README.md#15-screenshot-checklist-and-naming-convention)'s
Section 15.

**Naming collision to be aware of.** Phase 7b's screenshots also carry a `7c-`
prefix, because they were shot before the 7b and 7c phase letters were swapped on
2026-09-05 and were deliberately not renamed. Phase 7b's files are numbered from
`7c-01` to `7c-18` against that page's sections. Part 1 starts its numbering at
`7c-03` for its §3, so check the section a file belongs to rather than the number
alone.

---

## Appendix A: questions settled during the phase

| Question | Answer |
|---|---|
| Does the 24ai repository require a CDB? | No. 24ai supports pluggable database, lone pluggable database and non-container database. The postupgrade chapter documents migrating a non-CDB repository to a PDB after the upgrade |
| Is there a Release Update floor for the 24ai upgrade? | Yes, 13.5 RU22. Stated in KB590189, not in the Upgrade Guide's prerequisites chapter |
| Which upgrade method for Part 2? | Upgrade software only with plug-ins and Configure Later. KB590189 requires it from 13.5 RU25 or later, because it is the method that allows the Release Update to be applied to the binaries before configuration |
| Which 24ai Release Update? | RU12, patch 39675954. RU06 was the floor for a 13.5.0.33 starting point |

---

## Appendix B: what was staged for Part 1

In `/u01/app/oracle/staging/patches/oem` on `oemserver01`, confirmed 2026-09-06:

| File | Patch | Size |
|---|---|---|
| `oem13.5_RU5_p39676211_135000_Generic.zip` | 39676211, RU33 | 1.49 GB |
| `OMSPatcher_patch_version_13.9.5.27.0_p19999993_135000_Generic.zip` | 19999993 | 1.3 MB |
| `Oracle_JDBC_Fusion_Middleware_12.2.1.4.0_p35430934_122140_Generic.zip` | 35430934 | 1.4 MB |
| `Oracle_JDBC_Fusion_Middleware_12.2.1.4.0_p34153238_122140_Generic.zip` | 34153238 | 59 KB |
| `Oracle_JDBC_Fusion_Middleware_12.2.1.4.0_p31657681_191000_Generic.zip` | 31657681 | 468 KB |

**`RU5` in the RU filename means Release 5, not Update 5.** The README title is
the authority: *"Oracle Enterprise Manager 13c Release 5 Update 33 (13.5.0.33)
for Oracle Management Service"*.

What was staged for Part 2 is in
[Part 2a §1.1](phase-7c-part2a-pre-deployment.md#11-what-is-staged).
