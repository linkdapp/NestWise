# Phase 7c Part 2: Upgrading the OMS to 24ai Release 1

**SOP: `oemserver01`, Enterprise Manager 13.5.0.33 to 24ai Release 1 (24.1) RU12, Oracle Linux**

Part 2 of 2. [Part 1](phase-7c-part1-oms-ru33.md) took the OMS from base
13.5.0.0.0 to 13.5.0.33 and is confirmed. The phase index is
[`phase-7c-oms-upgrade.md`](phase-7c-oms-upgrade.md).

Status: 🟨 In progress. The OMS is at **24ai Release 1** as of 2026-09-12. Part 2c
is outstanding.

| Part | Covers | Downtime | Status |
|---|---|---|---|
| [Part 2a: Pre-deployment](phase-7c-part2a-pre-deployment.md) | Stage, prerequisites, EM Prerequisite Kit, software-only install, RU12 applied to the binaries with `-bitonly` | **None** | 🟨 In progress |
| [Part 2b: Deployment](phase-7c-part2b-deployment.md) | Blackout, stop the 13.5 stack, backup, `ConfigureGC.sh`, and the five checks that confirm the upgrade succeeded | **The window** | 🟩 Confirmed 2026-09-12 |
| [Part 2c: Post-deployment](phase-7c-part2c-post-deployment.md) | Clear the blackout, secure the emkey, lock the console and agent upload, verify the Phase 7b configuration, agents to 24ai, restore what the upgrade weakened, deinstall 13.5 | None | ⬜ Planned |

Start with Part 2a.

---

## The idea in one paragraph

The upgrade is **out of place**: a new 24ai home is built beside the 13.5 home,
which is left untouched. That means the expensive half, installing 24ai and
patching it to RU12, happens while the 13.5 OMS is still serving the console. The
window only has to stop the stack and run one script. It also means rollback is a
repository restore and a restart of the 13.5 home rather than a rebuild.

---

## Why the software-only method, and not the obvious one

The installer offers two routes. **Upgrade End-to-End** installs and configures in
one pass and is the shorter of the two. This estate cannot use it.

My Oracle Support KB590189 ties the minimum 24ai target to the starting 13.5
Release Update:

| Starting 13.5 Release Update | Minimum 24ai target |
|---|---|
| **RU28 and later** | **24ai RU06 or later** |
| RU27 | 24ai RU04 or later |
| RU26 | 24ai RU02 or later |
| RU25 | 24ai RU01 or later |
| RU22 through RU24 | 24.1 Base Release or later |

At **13.5.0.33** the target is RU06 or later. End-to-End configures at base 24.1
and offers no opportunity to patch the binaries first, so it cannot reach RU06 in
a single pass. KB590189 names **Upgrade software only with plug-ins and Configure
Later** as the route, and KB282751 covers applying the Release Update to the new
binaries with `omspatcher apply -bitonly`.

**RU12 is what is staged**, six above the floor. Confirm against KA1271 whether a
later one exists before the window opens.

This was recorded as an open question in earlier scoping, on the basis that the
24ai Upgrade Guide's prerequisites chapter names no Release Update floor. It does
not; KB590189 does. The chapter is not the whole story.

---

## Starting state

| | |
|---|---|
| Host | `oemserver01.usat.com`, single OMS, no Server Load Balancer, no standby |
| OMS version | **13.5.0.33**, [Part 1](phase-7c-part1-oms-ru33.md) |
| Repository database | `oemcdb`, **19.32.0.0.0**, non-CDB, single instance, [Phase 7a](phase-7a-repository-db-ru32.md) |
| Agents in scope | Six, the gold image set from [Phase 7b Part 3](phase-7b-part3-golden-image.md) |
| Single sign-on | None |
| Console | `https://oemserver01.usat.com:7803/em` |
| Staging root | `/u01/app/oracle/staging/patches/oem`, shared with Part 1 |
| Automation | None. Manual SOP, as with the rest of Phase 7b and 7c |

**Run the installer and `ConfigureGC.sh` inside VNC.** A dropped VPN or an idle
timeout ends either run, and it restarts from the beginning.

---

## Gates, and where each stands

| Floor | Requirement | This estate |
|---|---|---|
| OMS | 13.5 with **RU22 or later** | 🟩 13.5.0.33 |
| Repository database | 19.22 or later in 19c | 🟩 19.32.0.0.0 |
| Management Agents | 13c Release 5 | 🟩 Confirmed 2026-09-10, [Part 2a §2.9](phase-7c-part2a-pre-deployment.md#29-every-agent-in-scope-is-at-13c-release-5) |
| `oracle.sysman.csa` off the central agent | Fails the agent upgrade inside `ConfigureGC.sh` | 🟩 Gone, [Part 2a §2.2](phase-7c-part2a-pre-deployment.md#22-undeploy-obsolete-plug-ins) |
| `oracle.sysman.orhc` off the OMS | Obsolete in 24ai | 🟩 Gone |
| Certificate signature algorithm | Not `SHA1withRSA` | 🟩 Passed 2026-09-06 |
| Software, RU12, OMSPatcher, OPatch | Staged | 🟩 2026-09-10 |
| `/tmp`, `/u01`, `softnofiles`, `file-max` | 14 GB, 40 GB, 30000, 65536 | ⬜ [Part 2a §1.4](phase-7c-part2a-pre-deployment.md#14-host-floors) |

**No blockers.**

### The repository does not have to be a CDB

24ai supports pluggable database, lone pluggable database and non-container
database repositories. `oemcdb` is a non-CDB and stays one.

**Phase 7d is not a prerequisite for this part.** It remains a prerequisite for
taking `oemcdb` past 19c, since non-CDB is desupported from Oracle Database 21c
onward.

### Not applicable to this estate

| Prerequisite | Reason |
|---|---|
| OAM SSO conversion to SAML | No SSO. OAM SSO is not supported in 24ai |
| Server Load Balancer review | No SLB |
| Upgrade and Transition to DR Readiness | No standby OMS |
| Multi-OMS handling | Single OMS |
| Repository database upgrade from 12c to 19c | Already 19c |
| Smart card authentication removal | Not configured |
| Additional WebLogic data source parameters | None added |
| Database service instance creation requests | Self Service Portal not in use |
| 24ai update plug-ins | Only the default plug-in set is deployed, [Part 2a §1.2](phase-7c-part2a-pre-deployment.md#12-the-update-plug-ins-are-not-needed-here) |
| Release Update prerequisite patches | Not part of the upgrade path, [Part 2a §5.3](phase-7c-part2a-pre-deployment.md#53-upgrade-opatch) |

---

## The result

| | |
|---|---|
| OMS version | 13.5.0.33 to **Oracle Enterprise Manager 24ai Release 1** |
| Central agent | 13.5.0.0.0 to **24.1.0.0.0** |
| Release Update | 24.1 RU12, patch 39675954, applied to the binaries before configuration |
| 24ai Middleware home | `/u01/app/oracle/Middleware/24ai` |
| 24ai agent base | `/u01/app/oracle/Middleware/agent24` |
| Targets monitored | 203 before. Record the count after |
| Console | `https://oemserver01.usat.com:7803/em`, unchanged |
| Upgrade date | 2026-09-12 |

Administration groups, Metric Extensions and the remaining agents are verified
and moved in [Part 2c](phase-7c-part2c-post-deployment.md).

---

## Sources

- My Oracle Support **KB315275**, *EM 24ai: How to Upgrade OEM from 13.5 to 24.1*
- My Oracle Support **KB590189**, *24.1: Checklist for Upgrading Enterprise
  Manager Cloud Control from Version 13.5 to 24.1*
- My Oracle Support **KB282751**, *24ai: How to Apply Release Update on the OMS
  During the Install/Upgrade*, the source for Part 2a §5
- My Oracle Support **KB371380**, *EM 24ai: How To Upgrade Enterprise Manager 24.1
  OMSPatcher Utility to the Latest Version*
- My Oracle Support **KA1271**, *Enterprise Manager 24ai Main Release Update List
  (Includes Plug-ins)*
- My Oracle Support **KB540933** and **KB253309**, the
  `CheckMinimumOPatchVersion` failure
- My Oracle Support **KB274749**, OMSCA *"Error reading trustStore Wallet"*
- My Oracle Support **KB639677**, *"handshake has no peer"* after a 24.1 upgrade
- My Oracle Support **KB621611**, the silent alternative
- My Oracle Support **KB313420** and **2812403.1**, the 13.5 `-bitonly`
  equivalent and its `OMSPatcher failed: null` known issue
- My Oracle Support **2543058.1**, emkey copy failure
- My Oracle Support **2166275.1**, gold agent image creation failing with
  *"Suspended: Agent is not Ready"*
- [Compliance Checking with Oracle Orachk and Oracle Exachk, AHF User's Guide](https://docs.oracle.com/en/engineered-systems/health-diagnostics/autonomous-health-framework/ahfug/compliance-checking-with-orchk-or-exachk.html)
  and [Running Generic Compliance Framework Commands](https://docs.oracle.com/en/engineered-systems/health-diagnostics/autonomous-health-framework/ahfug/generic-compliance-framework-commands.html),
  the source for Part 2c §10.1: compliance runs through `orachk`, `exachk` or
  `ahfctl compliance`, and `-a` runs all checks
- My Oracle Support **1611578.1**, **2179909.1**, key strength and MD5 agents
- [Prerequisites for Upgrading to Enterprise Manager 24ai Release 1](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/24.1/emupg/prerequisites-upgrading-enterprise-manager-24.html)
- [Oracle Enterprise Manager Upgrade Guide 24ai Release 1](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/24.1/emupg/enterprise-manager-upgrade-guide.pdf)
- [Overview of the EM Prerequisite Kit, Basic Installation Guide 24ai](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/24.1/embsc/overview-em-prerequisite-kit.html)
- [EMCTL Security Commands, Cloud Control Administrator's Guide 13.5](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/13.5/emadm/emctl-security-commands.html)
- [Upgrading Oracle Management Agents, Upgrade Guide 24ai](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/24.1/emupg/upgrading-oracle-management-agents.html),
  the source for Part 2c §5: the gold image recommendation, the 24ai standalone
  source requirement, and the console bootstrap
- [Managing the Lifecycle of Agent Gold Images, Advanced Installation Guide 24ai](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/24.1/emadv/managing-lifecycle-agent-gold-images.html),
  what a gold image can update, who cannot subscribe, and the base directory layout
  after an image update
- [`update_agents`, EM CLI Verb Reference](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/13.4/emcli/update_agents.html),
  the source for Part 2c §5.7: `-gold_image_name` and `-agents` are mandatory,
  `-validate_only` submits no job, and the image is pushed by default when it has
  not been staged

### Field reports consulted

Neither is a substitute for the documentation above. Both were read against these
pages and are cited where they contributed a step Oracle's documents do not spell
out.

- Fernando Simon, [Upgrade EM from 13.5 to 24ai (24.1.0.0.0)](https://www.fernandosimon.com/blog/upgrade-em-from-13-5-to-24ai-24-1-0-0-0/),
  December 2024. Source of the `em24100_linux64.bin` filename and five part
  layout, the `emcli` login requirement before the undeploy verbs, tracking the
  OMS restart with `emctl status oms -details`, the tolerable
  `Remove plug-in's Oracle home` failure, and `job_queue_processes`. Used the
  End-to-End method, which this estate cannot
- Asanga Pradeep, *Upgrading Enterprise Manager Cloud Control from 13.5 to 24.1*,
  [part 1](https://asanga-pradeep.blogspot.com/2026/02/upgrading-enterprise-manager-cloud.html),
  [part 2](https://asanga-pradeep.blogspot.com/2026/02/upgrading-enterprise-manager-cloud_01121249501.html),
  [part 3](https://asanga-pradeep.blogspot.com/2026/02/upgrading-enterprise-manager-cloud_15.html),
  February 2026. Source of the `CheckMinimumOPatchVersion` failure, the
  `-bitonly` interactive prompt and `ext_oms_home` featureset, the response file
  route, the repository grants, and the agent cleanup. Used the same
  software-only method as these pages, from 13.5.0.28 to 24.1.0.7, with the
  repository in a PDB rather than a non-CDB

---

*Screenshots are in [`screenshots/`](screenshots/), numbered to each part's own
section numbers. Each part carries its own checklist.*
