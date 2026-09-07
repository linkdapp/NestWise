# Phase 7c Part 2: Upgrading the OMS to 24ai Release 1

**Scope: `oemserver01`, Enterprise Manager 13.5.0.33 to 24ai Release 1 (24.1)**

Status: ⬜ Planned. The 24ai software is not staged.

**Not the current priority.** [Part 1](phase-7c-part1-oms-ru33.md) takes the OMS to
RU33 and must complete first. Nothing on this page blocks Part 1, and only §3.2 is
worth running early.

This page is a checklist, not a runbook. It exists so the prerequisites are known
before the software is downloaded.

---

## Contents

1. [Version floors](#1-version-floors)
2. [Where this estate stands](#2-where-this-estate-stands)
3. [Prerequisites](#3-prerequisites)

[Appendix A](#appendix-a-oradbserv01-and-orappsserv01): two agents out of scope.
[Appendix B](#appendix-b-certificate-remediation-not-required): certificate
remediation, not needed.

---

## 1. Version floors

| Floor | Requirement | This estate |
|---|---|---|
| OMS | 13c Release 5 | 13.5.0.33 after Part 1 |
| Repository database | 19.22 or later | 19.32.0.0.0, Phase 7a |
| Management Agents | 13c Release 5 | Six of eight, see [Appendix A](#appendix-a-oradbserv01-and-orappsserv01) |

The Upgrade Guide names no Release Update floor. Part 1 makes the question moot.

---

## 2. Where this estate stands

| | |
|---|---|
| OMS version after Part 1 | 13.5.0.33 |
| Repository database | `oemcdb`, 19.32.0.0.0, non-CDB, single instance |
| Monitored targets | 168 as of Phase 7b Part 1 |
| OMS topology | Single OMS, no Server Load Balancer, no standby |
| Single sign-on | None |

### 2.1 Already satisfied

| Prerequisite | Standing |
|---|---|
| Minimum OMS 13c Release 5 | 13.5.0.33 after Part 1 |
| Minimum repository database 19.22 | 19.32.0.0.0, Phase 7a |
| Latest database PSU | RU 19.32, Phase 7a |
| OMS ports above 1024 | Console on 7803 |
| Certificate key strength and signature algorithm | 🟩 Passed 2026-09-06, check and remediation in [Appendix B](#appendix-b-certificate-remediation-not-required) |
| Repository container architecture | Non-CDB is supported, see [§2.2](#22-the-repository-does-not-have-to-be-a-cdb) |

### 2.2 The repository does not have to be a CDB

Enterprise Manager 24ai supports three repository configurations: pluggable
database, lone pluggable database, and non-container database. `oemcdb` is a
non-CDB and stays one.

Corroborated by two chapters of the 24ai documentation. The prerequisites chapter
names a database version floor of 19.22 and is silent on container architecture.
The postupgrade chapter documents migrating a non-CDB repository to a CDB or PDB
**after** the upgrade.

**Phase 7d is not a prerequisite for this part.** It remains a prerequisite for
taking `oemcdb` past 19c, since non-CDB is desupported from Oracle Database 21c
onward.

Confirm against the Enterprise Manager certification matrix on My Oracle Support
before this appears in a showcase post.

### 2.3 Not applicable to this estate

| Prerequisite | Reason |
|---|---|
| OAM SSO conversion to SAML | No SSO configured. OAM SSO is not supported in 24ai |
| Server Load Balancer review | No SLB |
| Upgrade and Transition to DR Readiness | No standby OMS |
| Multi-OMS handling | Single OMS |
| Repository database upgrade from 12c to 19c | Already 19c |
| Smart card authentication removal | Not configured |
| Additional WebLogic data source parameters | None added |
| Database service instance creation requests | Self Service Portal not in use |
| Job type upgrade postponement | Applies above 5,000 active executions per job type. Verify |

---

## 3. Prerequisites

When each is due:

| When | Sections |
|---|---|
| Fold into the Part 1 window | 3.2 |
| Any time before the 24ai window | 3.1, 3.3, 3.4, 3.6 |
| Immediately before the 24ai upgrade | 3.5, 3.8 |
| Gated on the 24ai download | 3.7 |

### 3.1 Database initialization parameter

Requires a database restart.

```sql
ALTER SYSTEM SET "_allow_insert_with_update_check" = TRUE SCOPE = BOTH;
-- restart the database
SHOW PARAMETER _allow_insert_with_update_check
```

Expected value after restart: `TRUE`.

### 3.2 Undeploy obsolete plug-ins

Six plug-ins are obsolete in 24ai.

| Plug-in | Identifier | Undeploy from |
|---|---|---|
| Big Data Appliance | `oracle.sysman.bda` | OMS and agents |
| Oracle Fusion Application | `oracle.sysman.emfa` | OMS and agents |
| Oracle OraHealth Checks | `oracle.sysman.orhc` | OMS and agents |
| Microsoft .NET Framework | `oracle.em.smdn` | OMS and agents |
| Oracle Virtualization | `oracle.sysman.vt` | Agents only. The upgrade removes it from the OMS |
| Client System Analyzer | `oracle.sysman.csa` | Central agent. Its presence makes the central agent upgrade fail |

A plug-in must be off every agent before it can come off the OMS.

#### What is deployed here

```bash
emcli list_plugins_on_server
emcli list_plugins_on_agent -all
```

Seven plug-ins on the Management Server, one of them obsolete:

| Plug-in id | Version | Obsolete |
|---|---|---|
| `oracle.sysman.am` | 13.5.1.0.0 | No |
| `oracle.sysman.cfw` | 13.5.1.0.0 | No |
| `oracle.sysman.db` | 13.5.1.0.0 | No |
| `oracle.sysman.emas` | 13.5.1.0.0 | No |
| **`oracle.sysman.orhc`** | **13.4.1.0.0** | **Yes** |
| `oracle.sysman.si` | 13.5.1.0.0 | No |
| `oracle.sysman.xa` | 13.5.1.0.0 | No |

![emcli list_plugins_on_server output showing seven plug-ins deployed on oemserver01.usat.com:4889_Management_Service, with oracle.sysman.orhc at 13.4.1.0.0 and the rest at 13.5.1.0.0](screenshots/3.2_Undeploy_obsolete_plug-ins_oms.png)

`oracle.sysman.csa` 13.5.0.0.0 is on the central agent and on no other agent.

![emcli list_plugins_on_agent -all output across eight agents, showing oracle.sysman.csa 13.5.0.0.0 on oemserver01 and on no other agent](screenshots/3.2_Undeploy_obsolete_plug-ins_agent.png)

| Plug-in | Where | Action |
|---|---|---|
| `oracle.sysman.orhc` | OMS only | Undeploy from the OMS |
| `oracle.sysman.csa` | Central agent only | Undeploy from the central agent |
| `oracle.sysman.bda`, `oracle.sysman.emfa`, `oracle.em.smdn`, `oracle.sysman.vt` | Nowhere | None |

A populated **Latest Downloaded** column on the console Plug-ins page does not mean
deployed. **On Management Server** is the column that counts.

#### Blackout first

`undeploy_plugin_from_server` stops and restarts the Management Server as two of
its own steps. Measured on this estate, 2026-09-06:

| Step | Elapsed |
|---|---|
| Stop management server | 41 seconds |
| Deconfigure from middle tier | 4 seconds |
| Deconfigure from Management Repository | 14 seconds |
| Update inventory | 1 second |
| **Start management server** | **6 minutes 42 seconds** |

**Total OMS outage: 7 minutes 42 seconds.**

Create the blackout first, using
**[Creating a Blackout in Enterprise Manager 13.5](oem-create-blackout.md)**.
Agents queue uploads while the OMS is down and flush on its return, so no
collected data is lost.

The agent undeploy restarts that agent, not the OMS.

#### Undeploy

```bash
emcli undeploy_plugin_from_agent -plugin="oracle.sysman.csa" \
  -agent_names="oemserver01.usat.com:3872"

emcli undeploy_plugin_from_server -plugin="oracle.sysman.orhc"
```

![The emcli undeploy command being run](screenshots/3.2_Undeploy_obsolete_plug-ins_from_emcli.png)

#### The console route

**Setup → Extensibility → Plug-ins**

1. Select the row for the plug-in to remove.
2. Click **Undeploy From**, then **Management Server** or **Management Agent**.

The console submits the same job with the same OMS restart.

![The Plug-ins page under Setup, Extensibility](screenshots/3.2_Undeploy_obsolete_plug-ins_oem_console.png)

![Selecting the plug-in row and opening Undeploy From](screenshots/3.2_Undeploy_obsolete_plug-ins_from_console1.png)

![The Undeploy From dialog](screenshots/3.2_Undeploy_obsolete_plug-ins_from_console2.png)

![Confirming the undeploy](screenshots/3.2_Undeploy_obsolete_plug-ins_from_console3.png)

![The undeployment job progressing through its steps](screenshots/3.2_Undeploy_obsolete_plug-ins_from_console4.png)

#### Watch and confirm

The undeploy runs as a job and returns before it finishes.

```bash
emcli get_plugin_deployment_status -plugin=oracle.sysman.orhc

emcli list_plugins_on_server
emcli list_plugins_on_agent -all
```

#### Run record

| Plug-in | Where | Status |
|---|---|---|
| `oracle.sysman.orhc` | OMS | 🟩 Undeployed 2026-09-06, eleven steps, all Success |
| `oracle.sysman.csa` | Central agent | 🟨 Outstanding |

The ORAchk undeploy ran without a blackout. Check Incident Manager for
availability events raised between 18:41 and 18:49 on 2026-09-06 and clear any
that are artefacts of the restart.

Undeploying `oracle.sysman.orhc` removes the Enterprise Manager integration for
ORAchk health checks. AHF continues to run per host from the command line.

### 3.3 Check for repository snapshots and triggers

```sql
SELECT master, log_table FROM all_mview_logs WHERE log_owner = 'SYSMAN';

SELECT trigger_name FROM sys.dba_triggers
 WHERE triggering_event LIKE 'LOGON%' AND status = 'ENABLED';

SELECT trigger_name FROM sys.dba_triggers
 WHERE triggering_event LIKE 'LOGOFF%' AND status = 'ENABLED';
```

Drop any snapshots. Disable any logon or logoff triggers for the upgrade and
re-enable them after.

### 3.4 Enable Delete Target auditing

```bash
emcli show_audit_settings
```

If the Delete Target operation is not enabled, enable it with
`emcli update_audit_settings`.

### 3.5 Copy the emkey to the repository

```bash
$ORACLE_HOME/bin/emctl config emkey -copy_to_repos
$ORACLE_HOME/bin/emctl status emkey
```

Expected confirmation: *"The EMKey is configured properly, but is not secure"*.
That is the success message for this step.

### 3.6 Record the tuned memory settings

These have been tuned on this OMS and are reset by the upgrade.

```bash
for p in OMS_HEAP_MIN OMS_HEAP_MAX OMS_PERMGEN_MIN OMS_PERMGEN_MAX; do
  echo -n "$p = "; $ORACLE_HOME/bin/emctl get property -name $p
done
```

| Property | Before | After |
|---|---|---|
| `OMS_HEAP_MIN` | | |
| `OMS_HEAP_MAX` | | |
| `OMS_PERMGEN_MIN` | | |
| `OMS_PERMGEN_MAX` | | |

Re-apply with `emctl set property -name <name> -value <number>G`, then
`emctl stop oms -all` and `emctl start oms`. Set all four before restarting.

### 3.7 Run the EM Prerequisite Kit

**Gated on the 24ai download.** The kit ships inside the 24ai distribution and
checks against 24ai's requirements. The copy in the 13.5 home is the wrong one.

```bash
cd <24ai_software_location>/install/requisites/bin

./emprereqkit \
  -executionType upgrade \
  -prerequisiteXMLRootDir <24ai_software_location>/install/requisites/list \
  -prereqResultLoc /u01/app/oracle/staging/prereq_results \
  -connectString "(DESCRIPTION=(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCP)(HOST=oemserver01.usat.com)(PORT=1521)))(CONNECT_DATA=(SID=oemcdb)))" \
  -dbUser SYS \
  -dbRole sysdba \
  -reposUser SYSMAN \
  -runPrerequisites
```

`SID` rather than `SERVICE_NAME` because `oemcdb` is a non-CDB.

Do not pass `-dbPassword` or `-reposPassword`. Both land in the process table. Let
the kit prompt.

`-runPreCorrectiveActions` and `-runPostCorrectiveActions` apply fixes where the
kit offers them. Results are written as XML under `-prereqResultLoc`. 24ai also
ships an `emprereqkit_upgrade.rsp` response file.

### 3.8 Back up and shut down

Back up the same five artefacts as
[Part 1 §7.2](phase-7c-part1-oms-ru33.md#72-back-up): repository database,
Middleware home, `gc_inst`, Software Library, Oracle inventory.

```bash
$ORACLE_HOME/bin/emctl extended oms jvmd stop -all
$ORACLE_HOME/bin/emctl extended oms adp stop -all
$ORACLE_HOME/bin/emctl stop oms -all
```

Shut down the agent monitoring the **Management Services and Repository** target.
Leaving it running can fail the upgrade.

### 3.9 Still to decide

- **Upgrade mode.** Standard GUI, software-only with `ConfigureGC.sh`, or silent.
  The software-only route allows a 24ai Release Update to be applied to the
  binaries before configuration, which reduces total downtime.
- **Which 24ai Release Update, and whether to apply it during the upgrade.**

---

## Appendix A: `oradbserv01` and `orappsserv01`

**Out of scope. No work is planned.** These are the two agents deferred during
[Phase 7b Part 3](phase-7b-part3-golden-image.md).

`emcli list_plugins_on_agent -all` on 2026-09-06:

| Agent | Plug-ins | Level |
|---|---|---|
| `oemserver01` | `db` 13.5.1.0.0, `emas` 13.5.1.0.0, `csa` 13.5.0.0.0, `beacon` 13.5.0.0.0, `emrep` 13.5.0.0.0, `oh` 13.5.0.0.0 | 13.5 |
| `oradbserv04`, `05`, `06`, `09`, `10` | `oh` 13.5.0.0.0 | 13.5 |
| `oradbserv01` | `si` 13.3.1.0.0, `oh` 13.3.0.0.0, `db` 13.3.2.0.0 | 13.3 |
| `orappsserv01` | `emas` 13.3.1.0.0, `oh` 13.3.0.0.0 | 13.3 |

The gold image was cut from `oradbserv05`, which carries one plug-in.
`oradbserv01` carries three and `orappsserv01` carries two. Enterprise Manager
refuses to update an agent from an image carrying fewer plug-ins than the agent
already has, recorded in Phase 7b Part 3 Appendix B. Cutting a second gold image
with a wider plug-in set is one route, a fresh agent install is the other.

Plug-in version is not agent core version. Establish the agent versions first:

```bash
emcli get_targets -target="oracle_emd"
```

---

## Appendix B: Certificate remediation, not required

**Not needed. The check passed on 2026-09-06.** Kept because a failed certificate
check is expensive to research under time pressure.

The check itself:

```bash
openssl s_client -connect oemserver01.usat.com:7803 </dev/null 2>/dev/null \
  | openssl x509 -noout -text | grep -E 'Signature Algorithm|Public-Key'
```

`Public-Key: (1024 bit)` or higher passes. `(512 bit)` fails. Any
`Signature Algorithm` containing `md5` fails.

MD5 does not stop the upgrade. The installer writes the affected agents to
`/tmp/OraInstall<timestamp>/md5Target.txt`.

### Estate-wide view

```bash
$ORACLE_HOME/bin/emctl secdiag dumpcertsinrepos -repos_conndesc "<connect descriptor>"
```

Omit `-repos_pwd` and let it prompt. Companion verbs:
`emctl secdiag dumpcertsinfile -file <loc>` reads a JKS, SSO, P12 or base64 file;
`emctl secdiag openurl -url <url>` diagnoses a connectivity failure.

### Reissuing certificates

```bash
$ORACLE_HOME/bin/emctl secure oms -key_strength 2048 -sign_alg sha512 \
  -reset -force_newca -console
```

| Parameter | Accepts |
|---|---|
| `-key_strength` | `512`, `1024`, `2048` |
| `-sign_alg` | `md5`, `sha1`, `sha256`, `sha384`, `sha512` |
| `-cert_validity` | Days, 1 to 3650 |

`-reset` creates a new Certificate Authority and `-force_newca` proceeds even
where agents are still secured against the old one. Every agent then has to be
re-secured against the new CA.

My Oracle Support 2179909.1 covers reconfiguring MD5 agents to SHA. 1611578.1
covers key strength.

---

## Sources

- [Prerequisites for Upgrading to Enterprise Manager 24ai Release 1](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/24.1/emupg/prerequisites-upgrading-enterprise-manager-24.html)
- [Oracle Enterprise Manager Upgrade Guide 24ai Release 1](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/24.1/emupg/enterprise-manager-upgrade-guide.pdf)
- [Overview of the EM Prerequisite Kit, Basic Installation Guide 24ai](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/24.1/embsc/overview-em-prerequisite-kit.html)
- [EMCTL Security Commands, Cloud Control Administrator's Guide 13.5](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/13.5/emadm/emctl-security-commands.html)
- [undeploy_plugin_from_server](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/13.4/emcli/undeploy_plugin_from_server.html)
- My Oracle Support KB313420, 1611578.1, 2179909.1
