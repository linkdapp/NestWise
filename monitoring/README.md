# Monitoring

**Enterprise Manager Cloud Control — the OEM 13.5 estate, its repository database, and the road to 24ai**

Status: 🟨 In progress. Phase 7a is confirmed; 7b, 7c and 7d are scoped but not
built.

| Phase | Covers | Status |
|---|---|---|
| **7a** — [Patching the OEM repository database to 19c RU32](phase-7a-repository-db-ru32.md) | `oemcdb` 19.19.0.0.0 → 19.32.0.0.0, combo 39618649 (DB RU + OJVM), fully automated with a human checkpoint at the blackout | 🟩 Confirmed 2026-09-04 |
| **7b** — OMS 13.5 → 24ai | Out-of-place upgrade. Gate: **EM 13.5 RU22 or later**, unconfirmed. Agent upgrade follows the OMS. Fleet Maintenance in 24ai patches databases and Grid Infrastructure out-of-place via the `emcli` verb only — no GUI for that step, which is itself worth documenting | ⬜ Planned |
| **7c** — [Extending coverage](phase-7c-extending-coverage.md) | Agents onto the RAC clusters and the NestWise app tier, administration groups and monitoring templates (Production/Test/Development), agent golden image across the estate, APEX / ORDS / MongoDB via Metric Extensions. **Manual SOP, no Ansible** | 🟨 Planned, documented |
| **7d** — non-CDB → CDB conversion | Convert `OEMCDB` (which, despite the name, is **not** a CDB) and create `oempdb`, plus `ggpdb` for GoldenGate. A prerequisite for ever taking this database past 19c | ⬜ Planned |

---

## Standing procedures

Reusable across every phase in this directory, and referenced from the runbooks
rather than duplicated into them:

| Page | What it covers |
|---|---|
| [Creating a Blackout in Enterprise Manager 13.5](oem-create-blackout.md) | Console click-path, `emcli` and agent-side `emctl`, verifying a blackout is really active, clearing it, and why it is deliberately not automated. Needed before Phase 7a's patch window and before Phase 7c's golden-image rollout |
| [Discovering and Promoting Targets in Enterprise Manager 13.5](oem-discover-and-promote-targets.md) | Run once per host, after its agent is uploading. Auto discovery, why discovery is not promotion, `dbsnmp` monitoring credentials, the Data Guard association a standby needs, and what a RAC node versus an app-tier host should yield |
| [Phase 7a Ansible reference](phase-7a-ansible.md) | Roles, tags, variables, the `ssh_equivalence` consolidation, `syntax-check.sh`, and the design notes behind the `oem_repo_patch` role |

**Why 7a is automated and 7c is not.** 7a was a fixed sequence of shell commands
against one host, run inside a maintenance window with a rollback path — worth
automating, and the automation is the artefact. 7c is console configuration whose
value is in the decisions (which targets are Production, what a Development
database should alert on), most of it done once. Wrapping a one-time wizard in
Ansible would take longer than running it and produce a role nobody runs twice.

---

## Open questions worth settling early

- **Does EM 24ai's Management Repository require a CDB?** Not established. It
  changes whether Phase 7d is a prerequisite for 7b or an independent piece of
  work — settle it while scoping 7b rather than discovering it mid-upgrade.
- **What RU is the OMS actually on?** 7b's gate is EM 13.5 RU22 minimum, and the
  current level has not been confirmed against the live OMS.

---

## Standing toolkit in this phase

- **AHF / orachk compliance checks** — run before and after every patch or upgrade
  phase project-wide (see the root README's "Standing toolkit"), with the pre/post
  reports archived here as evidence rather than asserted. Phase 7a's baseline is
  [Part 1 §5.6](phase-7a-part1-before-the-window.md#56-ahf-compliance-baseline);
  the post-patch run is still outstanding.
- **Screenshots** live in [`screenshots/`](screenshots/), named to match the
  section they illustrate — the same convention as
  [`../installation/README.md`](../installation/README.md#15-screenshot-checklist-and-naming-convention)'s
  Section 15.

See [`../02-roadmap-skeleton.md`](../02-roadmap-skeleton.md) for how this phase
sits against the rest of the project.
