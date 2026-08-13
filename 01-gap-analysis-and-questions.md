---
title: "Road to OCM: Gap Analysis"
generated: 2026-08-05
---

# Road to OracleOCM — Gap Analysis

Your list is strong and already maps well onto real OCM-blueprint territory (CDB/PDB, RMAN, Data Guard, RAC-adjacent HA/DR, performance, security). Below are the gaps worth closing before you lock in the roadmap, organized by category, with why each one matters for both the exam and the showcase story.

## Gaps by category

| Category | What's missing | Why it matters |
|---|---|---|
| Grid Infrastructure & ASM | Not listed at all | You can't build the 2-node RAC without Grid Infrastructure (Clusterware) and shared storage — ASM or ACFS/dNFS. This is a prerequisite phase, not optional. |
| Cluster networking | Public/private interconnect, SCAN listener, node VIPs, name resolution | RAC lives or dies on network config. Worth its own showcase post — it's the part most single-instance DBAs have never touched. |
| Upgrade tooling | AutoUpgrade (and optionally Zero Downtime Migration) not named | DBUA is legacy. AutoUpgrade is Oracle's current standard for 12c→19c→26ai jumps and is itself a great "new feature to demo." |
| Data Pump | Not listed | RMAN handles physical backup/recovery; Data Pump is the logical companion (schema moves, PDB relocation prep, cross-version migration). Usually expected alongside RMAN. |
| Security specifics | "Security best practices" is generic | Naming TDE, Unified Audit, Database Vault, and Data Redaction turns one vague bullet into four concrete, demoable showcase topics. |
| Performance tooling | "Performance tuning" is generic | AWR, ADDM, SQL Tuning Advisor, and 26ai's new Real-Time SQL Plan Management are specific, nameable skills that read much stronger on a resume/blog than "performance tuning." |
| Patching terminology | "PSU Patching" | Oracle retired PSU terminology in 2017 in favor of Release Updates (RU/RUR). Also worth noting: OEM 24ai's Fleet Maintenance patches out-of-place via EMCLI only — no GUI for that step. |
| Application Continuity | Not listed | This is what separates "failover eventually" from "the application barely notices." A strong OCM-level HA topic to pair with Data Guard/RAC. |
| Cross-database integration | Dropped from this list (it was in your earlier project notes — MongoDB, SQL Server) | Worth a deliberate decision: keep it in scope or park it. Oracle 23ai/26ai now speaks the MongoDB API natively, which is a genuinely interesting, differentiated showcase topic if you want it. |
| Infrastructure-as-Code for the lab itself | Ansible/GitLab mentioned only for "automation," not for provisioning the VMs | Since the whole lab lives on VirtualBox, scripting the VM provisioning (Vagrant/Packer/VBoxManage + Ansible) is itself a compelling automation showcase, separate from in-database automation. |
| AI-native features in 26ai | Not mentioned | 26ai's headline differentiator is built-in AI Vector Search / Select AI, not traditional DBA features. If you're upgrading to 26ai, demoing at least one AI-native capability (not just "here's what changed for DBAs") will make that phase's post stand out. |
| OCI DBaaS scope | "Experience with DBaaS in OCI" is vague | Base Database Service, Autonomous Database, and Exadata Cloud Service have very different admin surfaces. Worth naming which one(s) you mean. |

## Open questions (need your answer, free-form)

1. **Compute budget**: roughly how do you want to split the 32 vCPU / 128GB across the RAC+DG+GG cluster, the OEM 13.5→24ai box, and the existing EBS app/DB servers?
2. **Network resolution**: real DNS for SCAN/VIPs, or `/etc/hosts` across the VMs? And will the private interconnect be a VirtualBox internal network?
3. **Audience for the posts**: are you writing mainly for non-DBA recruiters/hiring managers, or for DBAs from other platforms (SQL Server/Mongo people) who understand databases but not Oracle specifics? This changes how much Oracle jargon you can assume.
4. **Pacing**: rough timeline per phase, or open-ended?

I've also put four higher-leverage decisions in front of you as a quick multiple-choice — see the question prompt.

---
Sources:
- [Oracle Database 19c OCM blueprint overview](https://591lab.com/oracle/oracle-ocm/)
- [Oracle AI Database 26ai New Features Guide](https://docs.oracle.com/en/database/oracle/oracle-database/26/nfcoa/)
- [Oracle AI Database 26ai: Practical Features — DBTA](https://www.dbta.com/Editorial/Quest-IOUG-Database--Technology-Community-News/Oracle-AI-Database-26ai-Practical-Features-173715.aspx)
- [Overview of Upgrading to Enterprise Manager 24ai](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/24.1/emupg/overview-upgrading-enterprise-manager.html)
- [OEM 24ai: Patch/Upgrade via Fleet Maintenance](https://support.oracle.com/knowledge/Enterprise%20Management/2434260_1.html)
