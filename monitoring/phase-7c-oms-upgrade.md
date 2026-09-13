# Phase 7c: Upgrading Enterprise Manager from 13.5 to 24ai

**SOP: `oemserver01` (Oracle Linux) and the `oemcdb` repository, 13.5.0.0.0 to 24ai Release 1**

Status: 🟨 In progress. Part 1 is confirmed. Part 2 is scoped and waiting on the
24ai software.

| Part | Covers | Status |
|---|---|---|
| [Part 1: Patching the OMS to 13.5 RU33](phase-7c-part1-oms-ru33.md) | Sections 1 to 10: OMSPatcher upgrade, JDBC prerequisites, the property file, analyze, the patch window, verification, rollback | 🟩 Confirmed 2026-09-06. OMS at 13.5.0.33 |
| [Part 2: Upgrading the OMS to 24ai Release 1](phase-7c-part2-24ai-upgrade.md) | Split into three: [2a Pre-deployment](phase-7c-part2a-pre-deployment.md) stages and patches the 24ai binaries to RU12 with no downtime, [2b Deployment](phase-7c-part2b-deployment.md) is the `ConfigureGC.sh` window, [2c Post-deployment](phase-7c-part2c-post-deployment.md) re-secures the emkey and moves the agents | 🟨 In progress. Binaries staged, no blockers |

Start with Part 1. It is a hard prerequisite for Part 2, and it is executable
today with what is already staged.

---

## Why two parts, in this order

There are three version floors: **OMS at 13.5 with RU22 or later**, **repository
database at 19.22 or later in 19c**, and a **24ai target Release Update decided by
the starting 13.5 Release Update**.

The 24ai Upgrade Guide's prerequisites chapter names only 13c Release 5 and the
repository database version. The Release Update floor is in My Oracle Support
KB590189, along with the matrix that ties the starting Release Update to the
minimum 24ai target. At 13.5.0.33 this estate must go to **24ai RU06 or later**,
which is why Part 2 uses the **Upgrade software only with plug-ins and Configure
Later** method. The matrix is in
[Part 2 §2.1](phase-7c-part2-24ai-upgrade.md#21-the-starting-release-update-decides-the-target-release-update).

Part 1 clears the OMS floor with margin. RU33 also carries accumulated fixes onto
an OMS that has never had a Release Update applied, which is worth doing on its
own merits.

**Two floors were already cleared by earlier phases, neither of them for this
reason.**

| Floor | Cleared by | Value |
|---|---|---|
| Repository database 19.22 or later | [Phase 7a](phase-7a-repository-db-ru32.md) | 19.32.0.0.0 |
| Agents at 13c Release 5 | [Phase 7b](phase-7b-extending-coverage.md) | 13.5.0.0.0 estate wide |

Phase 7a was done because Oracle's own documentation makes the repository RU a
prerequisite for the 24ai upgrade. Phase 7b was moved ahead of this phase so that
the upgrade would be exercised against eight monitored hosts rather than three.
Both turn out to have cleared 24ai prerequisites as a side effect.

---

## Starting state

To be confirmed by Part 1 §3 rather than assumed. These are the values recorded by
earlier phases.

| | |
|---|---|
| Host | `oemserver01.usat.com` |
| OMS version | 13c Release 5, `13.5.0.0.0` at the start of Part 1, **13.5.0.33** after it |
| Middleware Oracle Home | `/u01/app/oracle/Middleware/oms/13.5` |
| Central agent | 13.5.0.0.0, `/u01/app/oracle/Middleware/agent/13_5` |
| Repository database | `oemcdb`, **19.32.0.0.0**, non-CDB, single instance |
| Console | `https://oemserver01.usat.com:7803/em` |
| Monitored targets | 168 as of Phase 7b Part 1 |
| OMS topology | Single OMS, no Server Load Balancer, no standby |
| Single sign-on | None. Relevant because **OAM SSO is not supported in 24ai** |

Two properties shape the whole phase.

**Single OMS.** There is no rolling option. The OMS goes down for the apply, and
every monitored target is unmonitored for the duration. Blackout first.

**No Release Update has ever been applied.** This has three consequences, all
documented in the RU33 README: Rapid Platform Update is unavailable for this
first RU, the rollback patch id list is the simple one rather than the one behind
KB390077, and the mandatory PNEWS1628 post-patch step has definitely not been run
before.

---

## What is staged

In `/u01/app/oracle/staging/patches/oem` on `oemserver01`, confirmed 2026-09-06:

| File | Patch | Size |
|---|---|---|
| `oem13.5_RU5_p39676211_135000_Generic.zip` | 39676211, RU33 | 1.49 GB |
| `OMSPatcher_patch_version_13.9.5.27.0_p19999993_135000_Generic.zip` | 19999993 | 1.3 MB |
| `Oracle_JDBC_Fusion_Middleware_12.2.1.4.0_p35430934_122140_Generic.zip` | 35430934 | 1.4 MB |
| `Oracle_JDBC_Fusion_Middleware_12.2.1.4.0_p34153238_122140_Generic.zip` | 34153238 | 59 KB |
| `Oracle_JDBC_Fusion_Middleware_12.2.1.4.0_p31657681_191000_Generic.zip` | 31657681 | 468 KB |

Everything Part 1 needs. Part 2 needs the 24ai software, which is not staged.

**`RU5` in the RU filename means Release 5, not Update 5.** The README title is
the authority: *"Oracle Enterprise Manager 13c Release 5 Update 33 (13.5.0.33) for
Oracle Management Service"*.

---

## What stays manual

Five things, each for a stated reason in
[Part 1 Appendix B](phase-7c-part1-oms-ru33.md#appendix-b-what-stays-manual-and-why):
creating and clearing the blackout, creating the WebLogic property file, the `sys`
prompt during the apply, the PNEWS1628 post-patch step, and rollback.

The common thread is credentials. The blackout needs `emcli` and `sysman` login
credentials, and the property file needs the WebLogic Administration Server
password. Neither belongs in this repository, in `group_vars`, or on a command
line where it lands in the process table.

Creating the blackout has its own page, because every maintenance window in this
project starts with it:
**[Creating a Blackout in Enterprise Manager 13.5](oem-create-blackout.md)**.

---

## What this feeds into

- **Phase 7d.** Convert `oemcdb` from non-CDB to a CDB, and create `oempdb` plus
  `ggpdb` for GoldenGate. Whether this is a prerequisite for Part 2 or independent
  work is still open, and is the question most worth closing first.
- **Agent upgrade** follows the OMS upgrade, not the other way round. The gold
  image built in [Phase 7b Part 3](phase-7b-part3-golden-image.md) is the
  mechanism, and it will need a new version cut against the 24ai agent software.
- **Fleet Maintenance** in 24ai patches databases and Grid Infrastructure out of
  place. For the initial 13.5 to 24ai path it is driven through the `emcli` verb
  only, with no console equivalent for that step.

---

## Open questions

- ~~**Does the 24ai repository require a CDB?**~~ **Answered 2026-09-06: no.**
  24ai supports pluggable database, lone pluggable database and non-container
  database repositories, and its postupgrade chapter documents migrating a non-CDB
  repository to a PDB *after* the upgrade. Phase 7d does not block Part 2. See
  [Part 2 §3.2](phase-7c-part2-24ai-upgrade.md#32-the-repository-does-not-have-to-be-a-cdb).
- ~~**Is there a Release Update floor for the 24ai upgrade at all?**~~ **Answered
  2026-09-09: yes, RU22.** My Oracle Support KB590189 states it, and adds the
  matrix that sets the minimum 24ai target from the starting 13.5 Release Update.
  At 13.5.0.33 the target is 24ai RU06 or later.
- ~~**Which upgrade mode for Part 2?**~~ **Answered 2026-09-09: Upgrade software
  only with plug-ins and Configure Later.** KB590189 requires it for any upgrade
  starting at 13.5 RU25 or later, because it is the method that allows the 24ai
  Release Update to be applied to the binaries before configuration.
- **Which 24ai Release Update.** RU06 is the floor. The one to stage is the
  latest available at the time of the window.

---

## Screenshots

Screenshots live in [`screenshots/`](screenshots/), named `7c-NN[a-z]-slug.png`
and numbered to each part's own section numbers, the same convention as
[`../installation/README.md`](../installation/README.md#15-screenshot-checklist-and-naming-convention)'s
Section 15.

**Naming collision to be aware of.** Phase 7b's screenshots also carry a `7c-`
prefix, because they were shot before the 7b and 7c phase letters were swapped on
2026-09-05 and were deliberately not renamed. Phase 7b's files are numbered from
`7c-01` to `7c-18` against that page's sections. This phase starts its numbering
at `7c-03` for Part 1 §3, so check the section a file belongs to rather than the
number alone.
