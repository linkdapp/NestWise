# Monitoring

**Enterprise Manager Cloud Control: the OEM 13.5 estate, its repository database, and the road to 24ai**

Status: 🟨 In progress. Phases 7a, 7b and 7c are confirmed: the estate runs
**24ai Release 1 Update 12** on the OMS, all six agents on 24ai Release 1, and 7d has
moved the repository into a container database. 7e closes the patch level gap between
the OMS and the agents.

| Phase | Covers | Status |
|---|---|---|
| **7a** [Patching the OEM repository database to 19c RU32](phase-7a-repository-db-ru32.md) | `oemcdb` 19.19.0.0.0 to 19.32.0.0.0, combo 39618649 (DB RU plus OJVM), fully automated with a human checkpoint at the blackout | 🟩 Confirmed 2026-09-04 |
| **7b** [Extending coverage](phase-7b-extending-coverage.md) | Agents onto the RAC clusters and the NestWise app tier from a gold agent image, administration groups and monitoring templates (Production, Test, Development), APEX, ORDS and MongoDB via Metric Extensions. Manual SOP, no Ansible | 🟩 Confirmed 2026-09-09 |
| **7c** [OMS 13.5 to 24ai](phase-7c-oms-upgrade.md) | Part 1 took the OMS from base 13.5.0.0.0 to RU33 (13.5.0.33) with patch 39676211. Part 2 took it to **24ai Release 1 Update 12**, out of place, using **Upgrade software only with plug-ins and Configure Later** so RU12 was applied to the binaries before `ConfigureGC.sh` ran. Gates: OMS at 13.5 RU22 or later, repository database at 19.22 or later, 24ai target at RU06 or later from RU28 and above. Part 2c took the remaining agents to 24ai, one through the Agent Upgrade Console and the rest through the gold image | 🟩 Confirmed 2026-09-13 |
| **7d** [Moving the repository into a container](phase-7d-noncdb-to-pdb.md), also indexed under [Multitenant](../multitenant/README.md) | `OEMCDB`, which despite the name is **not** a CDB, is plugged into a new container `usatcdb` as `oempdb`, and `ggpdb` is created alongside it for GoldenGate. There is no in-place conversion: a non-CDB becomes a PDB inside a container. A prerequisite for taking this database past 19c, since non-CDB is desupported from 21c onward. **Not** a prerequisite for 7c: 24ai supports a non-CDB repository | 🟩 Confirmed 2026-09-16. [Parts 1 and 2](phase-7d-part2-deployment.md) ran the window on 2026-09-15 and the console is served from `oempdb`. [Part 3](phase-7d-part3-post-deployment.md) retired the old non-CDB including its datafiles, backed up the container and closed the compliance check. The repository service not restarting with the PDB took the OMS down the next day and is recorded as [Part 2 §6.5](phase-7d-part2-deployment.md#65-what-happens-when-the-service-does-not-come-back) |

| **7e** [Patching the 24ai agents to RU12](phase-7e-agent-patching.md) | The six agents sit at 24ai Release 1 while the OMS runs Release 1 Update 12. Patch plans need My Oracle Support, which this estate does not have, so `agentpatcher` patches the central agent and the gold image source by hand and a new image version, `V3_24.1_RU12_BASE`, carries it to the rest. Patches 33355570 and 39675970. No Ansible | 🟩 Confirmed 2026-09-17. `oemserver01` and `oradbserv05` patched by hand; `oradbserv04`, `oradbserv09` and `oradbserv10` updated from the new image version. `oradbserv06` deferred to its own write-up |

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
- **Query files** live in [`sql/`](sql/). Anything a page asks you to run more than
  once, or to run under `catcon.pl`, is held there as a file rather than pasted into
  the prose twice. Currently [`sql/uptab_check.sql`](sql/uptab_check.sql), the
  Oracle-maintained type check used by
  [Phase 7a Part 3 §13.4](phase-7a-part3-verification.md#134-tables-dependent-on-oracle-maintained-types)
  and [Phase 7d Part 2](phase-7d-part2-deployment.md#appendix-a-checking-every-container).

`02-roadmap-skeleton.md` holds how this phase sits against the rest of the project. It
is a working document and is not published to the site.

---

## Appendix: questions settled during the phase

Recorded because each one changed the plan.

| Question | Answer | Where it is documented |
|---|---|---|
| Does the 24ai repository require a CDB? | No. 24ai supports pluggable database, lone pluggable database and non-container database. `oemcdb` stayed a non-CDB | [Part 2 index](phase-7c-part2-24ai-upgrade.md#the-repository-does-not-have-to-be-a-cdb) |
| Is there a Release Update floor for the 24ai upgrade? | Yes, 13.5 RU22. The 24ai Upgrade Guide names only 13c Release 5; My Oracle Support KB590189 states the floor and adds the matrix tying the starting Release Update to the minimum 24ai target | [Part 2 index](phase-7c-part2-24ai-upgrade.md#why-the-software-only-method-and-not-the-obvious-one) |
| Which upgrade method for Part 2? | Upgrade software only with plug-ins and Configure Later. From 13.5 RU28 the 24ai target must be RU06 or later, and End-to-End configures at base 24.1 | [Part 2a](phase-7c-part2a-pre-deployment.md) |

**Phase 7d is not a prerequisite for 7c.** It remains a prerequisite for taking
`oemcdb` past 19c, since non-CDB is desupported from Oracle Database 21c onward.
