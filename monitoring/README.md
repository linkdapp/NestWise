# Monitoring

**Enterprise Manager Cloud Control: the OEM 13.5 estate, its repository database, and the road to 24ai**

Status: 🟨 In progress. Phases 7a and 7b are confirmed. 7c Part 1 is confirmed and
Part 2 is scoped. 7d is scoped but not started.

| Phase | Covers | Status |
|---|---|---|
| **7a** [Patching the OEM repository database to 19c RU32](phase-7a-repository-db-ru32.md) | `oemcdb` 19.19.0.0.0 to 19.32.0.0.0, combo 39618649 (DB RU plus OJVM), fully automated with a human checkpoint at the blackout | 🟩 Confirmed 2026-09-04 |
| **7b** [Extending coverage](phase-7b-extending-coverage.md) | Agents onto the RAC clusters and the NestWise app tier from a gold agent image, administration groups and monitoring templates (Production, Test, Development), APEX, ORDS and MongoDB via Metric Extensions. Manual SOP, no Ansible | 🟩 Confirmed 2026-09-09 |
| **7c** [OMS 13.5 to 24ai](phase-7c-oms-upgrade.md) | Part 1 takes the OMS from base 13.5.0.0.0 to RU33 (13.5.0.33) with patch 39676211. Part 2 is the 24ai Release 1 upgrade. Verified gates: OMS at 13c Release 5, repository database at 19.22 or later. Agent upgrade follows the OMS. Fleet Maintenance in 24ai patches databases and Grid Infrastructure out of place through the `emcli` verb only, with no GUI for that step | 🟨 In progress |
| **7d** non-CDB to CDB conversion | Convert `OEMCDB`, which despite the name is **not** a CDB, and create `oempdb` plus `ggpdb` for GoldenGate. A prerequisite for taking this database past 19c, since non-CDB is desupported from 21c onward. **Not** a prerequisite for 7c: 24ai supports a non-CDB repository | ⬜ Planned |

**Coverage before the upgrade.** 7b was moved ahead of the OMS upgrade
deliberately. Upgrading to 24ai against eight monitored hosts and a real target
count exercises the upgrade far more than doing it against the three hosts the
estate started with. The same reasoning moved the RU32 patch to 7a.

---

## Standing procedures

Reusable across every phase in this directory, and referenced from the runbooks
rather than duplicated into them:

| Page | What it covers |
|---|---|
| [Creating a Blackout in Enterprise Manager 13.5](oem-create-blackout.md) | Console click-path, `emcli` and agent-side `emctl`, verifying a blackout is really active, clearing it, and why it is deliberately not automated. Needed before Phase 7a's patch window and before any agent update that restarts a live agent |
| [Discovering and Promoting Targets in Enterprise Manager 13.5](oem-discover-and-promote-targets.md) | Run once per host, after its agent is uploading. Auto discovery, why discovery is not promotion, `dbsnmp` monitoring credentials, the Data Guard association a standby needs, and what a RAC node versus an app-tier host should yield |
| [Phase 7a Ansible reference](phase-7a-ansible.md) | Roles, tags, variables, the `ssh_equivalence` consolidation, `syntax-check.sh`, and the design notes behind the `oem_repo_patch` role |

**Why 7a is automated and 7b is not.** 7a was a fixed sequence of shell commands
against one host, run inside a maintenance window with a rollback path, so the
automation is itself the artefact. 7b is console configuration whose value is in
the decisions (which targets are Production, what a Development database should
alert on), most of it done once.

---

## Open questions worth settling early

- ~~**Does EM 24ai's Management Repository require a CDB?**~~ **Answered
  2026-09-06: no.** 24ai supports pluggable database, lone pluggable database and
  non-container database repositories. Phase 7d is therefore **not** a prerequisite
  for 7c. It remains a prerequisite for taking `oemcdb` past 19c, since non-CDB is
  desupported from 21c onward.
- **Is there a Release Update floor for the 24ai upgrade?** The EM 13.5 RU22 figure
  carried from early scoping does not appear in the 24ai Upgrade Guide, which names
  the minimum starting point as 13c Release 5 without qualifying it by RU. Phase 7c
  Part 1 makes the question moot by taking the OMS to 13.5.0.33.
- **What RU is the OMS actually on?** Answered: **none**. The OMS is at base
  13.5.0.0.0, which is why Rapid Platform Update is unavailable for the first RU
  and why the PNEWS1628 post-patch step cannot have been run before.

---

## Standing toolkit in this phase

- **AHF and orachk compliance checks.** Run before and after every patch or
  upgrade phase project-wide, with the reports archived here as evidence. Phase
  7a's baseline is
  [Part 1 §5.6](phase-7a-part1-before-the-window.md#56-ahf-compliance-baseline).
  The post-patch run is still outstanding.
- **Screenshots** live in [`screenshots/`](screenshots/), named to match the
  section they illustrate, the same convention as
  [`../installation/README.md`](../installation/README.md#15-screenshot-checklist-and-naming-convention)
  Section 15.

See [`../02-roadmap-skeleton.md`](../02-roadmap-skeleton.md) for how this phase
sits against the rest of the project.
