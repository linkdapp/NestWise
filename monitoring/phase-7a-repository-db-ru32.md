# Phase 7a: Patching the OEM Repository Database to 19c RU32

**SOP: `oemcdb` on `oemserver01`, Combo 39618649 (Database RU 39472050 plus OJVM 39222882), 19.19.0.0.0 to 19.32.0.0.0, Oracle Linux**

Status: 🟩 Confirmed. Ran clean end to end on 2026-09-04.

| Part | Covers | Status |
|---|---|---|
| [Part 1: Before the window](phase-7a-part1-before-the-window.md) | Sections 1 to 5. Prerequisites, syntax check, preflight, staging the combo, and the read-only checks that belong days ahead | 🟩 |
| [Part 2: The patch window](phase-7a-part2-the-patch-window.md) | Sections 6 to 12. OPatch update, blackout pause, stopping the stack, backup and restore point, rolling back superseded one-offs, applying both patches | 🟩 |
| [Part 3: Datapatch, verification and aftermath](phase-7a-part3-verification.md) | Sections 13 to 19. Datapatch, `extjob`, bringing EM back, verification, rollback, outstanding items, screenshot checklist | 🟩 |

Start with Part 1. Each part carries its own status table, prerequisites, and
section-by-section commands with the output from the confirmed run.

---

## The result

| | |
|---|---|
| Version | 19.19.0.0.0 to **19.32.0.0.0** |
| Database RU `39472050` | `APPLY` / `SUCCESS`, 04-SEP-26 07:14:28 |
| OJVM RU `39222882` | `APPLY` / `SUCCESS`, 04-SEP-26 07:10:04 |
| Superseded one-off `29213893` | `ROLLBACK` / `SUCCESS`, 04-SEP-26 06:56:06 |
| Invalid objects | 2 to 0 |
| Registry components not `VALID` | 1 to 1. `RAC` `OPTION OFF`, expected on a single instance |
| Targets monitored | 43 to 43 |
| Enterprise Manager | OMS, agent and listener back up, `EMD upload completed successfully` |
| Play recap | `oemserver01 : ok=88 changed=19 unreachable=0 failed=0` |
| Window | Blackout 06:40, database open and uploading 07:26 |

---

## Starting state

Captured from the live lab on 2026-08-31.

| | |
|---|---|
| Host | `oemserver01.usat.com` |
| Repository database | `oemcdb`, **19.19.0.0.0** |
| Architecture | **non-CDB**. `SELECT cdb FROM v$database` returns `NO` |
| Instance type | Single instance, no Grid Infrastructure |
| Oracle Home | `/u01/app/oracle/product/19.3.0/db_1` |
| OMS version | 13c Release 5, `13.5.0.0.0` |
| OMS home | `/u01/app/oracle/Middleware/oms/13.5` |
| EM instance home | `/u01/app/oracle/product/19.3.0/db_1/em/EMGC_OMS1` |
| Agent | 13.5.0.0.0, `/u01/app/oracle/Middleware/agent/13_5` |
| Targets monitored | 43 |
| Console | `https://oemserver01.usat.com:7803/em` |

Two properties shape the runbook. **Single instance**, so there is no rolling
patch and Enterprise Manager goes down with the repository. **Non-CDB**, so the
non-CDB column of Oracle's datapatch procedure applies and a plain `STARTUP` is
correct.

---

## Run it

All commands run as `ansible` from
`phase-01-foundation-2node-rac-12cR2/ansible`.

```bash
# 0. Syntax check
bash syntax-check.sh

# 1. Preflight. Read-only, safe at any time                        (Part 1 §3)
ansible-playbook -i inventory/hosts.ini oem-repo-patch.yml \
  -e oem_patch_confirm=yes --tags oem_repo_patch_preflight

# 2. Stage the combo. Idempotent, safe to re-run                   (Part 1 §4)
ansible-playbook -i inventory/hosts.ini oem-repo-patch.yml \
  -e oem_patch_confirm=yes --tags oem_repo_patch_stage

# 3. The full run. Destructive. Pauses for the blackout            (Part 2)
ansible-playbook -i inventory/hosts.ini oem-repo-patch.yml \
  -e oem_patch_confirm=yes -e oem_repo_conflict_check_fatal=false
```

Roles, tags and variables are in
[`phase-7a-ansible.md`](phase-7a-ansible.md). The debugging history behind every
fix referenced across the three parts is in
[`known-risks.md`](../phase-01-foundation-2node-rac-12cR2/docs/known-risks.md).

### Six steps stay manual

Each with a stated reason in
[`phase-7a-ansible.md`](phase-7a-ansible.md#what-stays-manual-and-why):

1. Creating and clearing the blackout
2. The AHF compliance check either side
3. Dropping the guaranteed restore point
4. The RMAN catalog upgrade
5. Re-enabling optimizer-affecting bug fixes
6. Rollback

Creating the blackout has its own page:
**[Creating a Blackout in Enterprise Manager 13.5](oem-create-blackout.md)**.

---

## What this feeds into

- **[Phase 7b: Extending coverage](phase-7b-extending-coverage.md).** Agents onto
  the RAC clusters and the app tier, administration groups, monitoring templates,
  and Metric Extensions for APEX, ORDS and MongoDB. Complete.
- **[Phase 7c: OMS 13.5 to 24ai](phase-7c-oms-upgrade.md).** This patch was a
  prerequisite. 19.32.0.0.0 clears the 19.22 floor that 24ai requires. Part 1 took
  the OMS to RU33 and Part 2 took it to 24ai Release 1 Update 12.
- **Phase 7d.** Convert `oemcdb` from non-CDB to a CDB and create `oempdb` plus
  `ggpdb` for GoldenGate.

---

*Screenshots for all three parts are in [`screenshots/`](screenshots/), numbered to
each part's own section numbers. The full checklist is in
[Part 3 §19](phase-7a-part3-verification.md#19-screenshot-checklist-and-naming-convention).*



