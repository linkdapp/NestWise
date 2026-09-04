# Phase 7a — Patching the OEM Repository Database to 19c RU32

**SOP: `oemcdb` on `oemserver01` — Combo 39618649 (Database RU 39472050 + OJVM 39222882), 19.19.0.0.0 → 19.32.0.0.0, Oracle Linux**

Status: 🟩 Confirmed — ran clean end to end on 2026-09-04. This SOP is split into
three parts, meant to be read and run in order:

| Part | Covers | Status |
|---|---|---|
| [Part 1 — Before the window](phase-7a-part1-before-the-window.md) | Sections 1-5: prerequisites, the syntax check, preflight, staging the combo, and every read-only check that belongs days ahead of the window | 🟩 Confirmed |
| [Part 2 — The patch window](phase-7a-part2-the-patch-window.md) | Sections 6-12: OPatch update, the blackout pause, stopping the stack, backup and restore point, rolling back the superseded one-offs, applying both patches | 🟩 Confirmed |
| [Part 3 — Datapatch, verification and aftermath](phase-7a-part3-verification.md) | Sections 13-19: datapatch, `extjob`, bringing EM back, the verification checklist against the real run, rollback, what is still outstanding, screenshot checklist | 🟩 Confirmed |

Start with Part 1. Each part carries its own status table, prerequisites, and
section-by-section commands with the real output from the confirmed run.

---

## The result

| | |
|---|---|
| Version | **19.19.0.0.0 → 19.32.0.0.0** |
| Database RU `39472050` | `APPLY` / `SUCCESS`, 04-SEP-26 07:14:28 |
| OJVM RU `39222882` | `APPLY` / `SUCCESS`, 04-SEP-26 07:10:04 |
| Superseded one-off `29213893` | `ROLLBACK` / `SUCCESS`, 04-SEP-26 06:56:06 |
| Invalid objects | 2 → 0 |
| Registry components not `VALID` | 1 → 1 (`RAC` `OPTION OFF`, expected on a single instance) |
| Targets monitored | 43 → 43 |
| Enterprise Manager | OMS, agent and listener back up, `EMD upload completed successfully` |
| Play recap | `oemserver01 : ok=88 changed=19 unreachable=0 failed=0` |
| Window | blackout 06:40, database open and uploading 07:26 |

---

## Why this phase comes first

The instinct is to upgrade Enterprise Manager first and patch the repository
database afterwards. Oracle's own upgrade documentation reverses that: applying
the latest database Release Update to the Management Repository database is
**mandatory before** upgrading to Enterprise Manager 24ai, not after.

So this is a prerequisite, not a side quest. Getting it wrong means discovering
the problem partway through an OMS upgrade, which is a considerably worse place
to be.

There is a second gate on the OMS side, covered in Phase 7b rather than here:
**EM 13.5 RU22 (13.5.0.22) is the documented minimum** for upgrading to 24ai.
Confirm the current RU before planning that phase.

---

## This is automated

The parts explain *why* each step happens and what to watch for. The steps
themselves run from Ansible. Roles, tags, variables and design notes are in
[`phase-7a-ansible.md`](phase-7a-ansible.md); the debugging history behind every
fix referenced across the three parts is in
[`known-risks.md`](../phase-01-foundation-2node-rac-12cR2/docs/known-risks.md).

All commands run as `ansible` from
`phase-01-foundation-2node-rac-12cR2/ansible`. Three commands, in order:

```bash
# 0. Syntax check first — cheap, and it is what the failed first attempt should have started with
bash syntax-check.sh

# 1. Preflight — read-only, safe at any time                                    (Part 1 §3)
ansible-playbook -i inventory/hosts.ini oem-repo-patch.yml \
  -e oem_patch_confirm=yes --tags oem_repo_patch_preflight

# 2. Stage the combo — idempotent, safe to re-run                               (Part 1 §4)
ansible-playbook -i inventory/hosts.ini oem-repo-patch.yml \
  -e oem_patch_confirm=yes --tags oem_repo_patch_stage

# 3. The full run — destructive; pauses for the blackout before anything stops  (Part 2)
ansible-playbook -i inventory/hosts.ini oem-repo-patch.yml \
  -e oem_patch_confirm=yes -e oem_repo_conflict_check_fatal=false
```

**Six things stay manual**, each for a stated reason in
[`phase-7a-ansible.md`](phase-7a-ansible.md#what-stays-manual-and-why): creating
and clearing the blackout, the AHF compliance check either side, dropping the
guaranteed restore point, the RMAN catalog upgrade, re-enabling
optimizer-affecting bug fixes, and rollback.

Creating the blackout has its own page, because every maintenance window in this
project starts with it: **[Creating a Blackout in Enterprise Manager 13.5](oem-create-blackout.md)**.

---

## Starting state

Captured from the live lab on 2026-08-31.

| | |
|---|---|
| Host | `oemserver01.usat.com` |
| Repository database | `oemcdb`, **19.19.0.0.0** |
| Architecture | **non-CDB** — confirmed, `SELECT cdb FROM v$database` returns `NO` |
| Instance type | **single instance**, no Grid Infrastructure |
| Oracle Home | `/u01/app/oracle/product/19.3.0/db_1` |
| OMS version | 13c Release 5 (`13.5.0.0.0`) |
| OMS home | `/u01/app/oracle/Middleware/oms/13.5` |
| EM instance home | `/u01/app/oracle/product/19.3.0/db_1/em/EMGC_OMS1` |
| Agent | 13.5.0.0.0, `/u01/app/oracle/Middleware/agent/13_5` |
| Targets monitored | 43 |
| Console | `https://oemserver01.usat.com:7803/em` |

Two properties of that table shape the whole runbook.

**Single instance, not RAC.** There is no rolling patch available. The repository
goes down, and Enterprise Manager goes down with it.

**Non-CDB, despite being named `OEMCDB`.** Two consequences, one for this window
and one further out:

- **This window:** the non-CDB column of Oracle's datapatch procedure applies
  ([Part 3 §13](phase-7a-part3-verification.md#13-datapatch-the-step-people-forget)).
  A plain `STARTUP` is correct; there are no PDBs to open.
- **The upgrade arc:** non-CDB architecture was deprecated in 12.1 and is
  desupported from Oracle Database 21c onward. That makes Phase 7d's conversion a
  **prerequisite for ever taking this database past 19c**, not a tidiness
  exercise — worth confirming against current Oracle documentation before it gets
  planned, since desupport details are exactly the kind of thing that shifts.

Whether the EM 24ai repository itself imposes a CDB requirement is a separate
question, and one this project has not established. Check it while scoping Phase
7b rather than discovering it mid-upgrade.

---

## Screenshots

Screenshots referenced across all three parts are in
[`screenshots/`](screenshots/) — same naming convention as
[`../installation/README.md`](../installation/README.md#15-screenshot-checklist-and-naming-convention)'s
Section 15, numbered to match each part's own section numbers. The full checklist
is in [Part 3 §19](phase-7a-part3-verification.md#19-screenshot-checklist-and-naming-convention).

---

## What this feeds into

- **Phase 7b** — the OMS upgrade to 24ai, which required this patch first, and
  which has its own gate at EM 13.5 RU22. Agent upgrade follows the OMS.
- **Phase 7c** — administration groups and metric templates (dev/test/prod),
  agent golden image, pushed to `oradbserv06/09/10`, plus APEX / ORDS / MongoDB
  monitoring via Metric Extensions.
- **Phase 7d** — convert `OEMCDB` from non-CDB to a CDB, and create `oempdb`
  (plus `ggpdb` for GoldenGate). Still to do: `SELECT cdb FROM v$database`
  returned `NO` again on 2026-09-04, after the patch.

> **Numbering note.** The original scoping put the RU32 patch at 7b and the CDB
> conversion at 7c. This renumbered because the patch is a hard prerequisite for
> the OMS upgrade and had to come first — so RU32 became 7a, and everything after
> it shifted. The CDB conversion is **7d** here, not 7c. Earlier drafts of this
> document and of `known-risks.md` #142 called it 7c, which collided with the
> administration-groups phase; corrected 2026-08-31.

---

## Open questions for the write-up

Recorded so they get answered deliberately rather than forgotten. Struck-through
entries were open when this phase was scoped and are now settled.

- **Where does the OEM repository database actually live?** This runbook assumes
  `/u01/app/oracle/product/19.3.0/db_1` on `oemserver01`, because that is the
  home `emctl status oms -details` reports the EM instance home beneath. But
  `group_vars/all.yml` describes that same path as *"its own, unrelated 19.3.0
  Oracle **Client** (19.19 DGMGRL)"*. A client home and a repository database
  home are not the same thing, and patching the wrong one is the most expensive
  mistake available in this phase. **Settled by the preflight**, which proves the
  running instance's `pmon` binary resolves inside this home — a client home has
  no instance running from it. The `group_vars` description is what is wrong, not
  the path; fix it there.
- ~~Is OJVM in scope, and which component carries it?~~ **Answered by the choice
  of combo: 39618649 IS the OJVM + DB RU combo.** Component `39222882`.
- ~~Is the repository database in ARCHIVELOG mode with a usable fast recovery
  area, making the guaranteed restore point viable?~~ **Answered by the run:
  `ARCHIVELOG`, but `FLASHBACK_ON` is `NO`.** The restore point was created and
  is guaranteed, but flashback database is not enabled, so it was never the
  rollback mechanism — the RMAN backup was. See
  [Part 2 §9](phase-7a-part2-the-patch-window.md#9-back-up-before-the-patch).
- ~~Which apply mechanism, `opatch apply` or `opatchauto`?~~ **Answered from both
  READMEs: plain `opatch apply`, twice.** Neither component is a system patch — a
  GI combo is, and this is not one.
- ~~Do the five one-off patches on RU 19.19 need merge patches?~~ **Answered by
  the run.** Two were rolled back explicitly; the other three were auto-deactivated
  as subsets, and `opatch` said so by name. Full account in
  [Part 2 §11](phase-7a-part2-the-patch-window.md#11-roll-back-the-superseded-one-offs).
- ~~Is the repository database a CDB or a non-CDB?~~ **Answered against the live
  database: non-CDB**, despite the SID being `OEMCDB`.
- **Does EM 24ai's Management Repository require a CDB?** Not established, and it
  changes whether Phase 7d is a prerequisite for 7b or an independent piece of
  work. Settle it while scoping 7b.
- **Does a recovery catalog exist for this database at all?** The backup ran
  `rman target /` with no catalog and reported *"using target database control
  file instead of recovery catalog"*, which is consistent with there being none —
  but that is an absence of evidence, not evidence of absence. Confirm before the
  next window, because Oracle's §3.3.3 catalog upgrade is a real post-patch step
  if one exists.

---

*Previously this was a single ~1,300-line page. It is now split into the three
parts above for easier reading and GitHub publishing, and the blackout procedure
has moved to its own reusable page; the section-by-section detail — real commands,
real output, screenshots, known-risks cross-references — lives in each part.*
