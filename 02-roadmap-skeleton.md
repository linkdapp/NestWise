---
title: "Road to OracleOCM — Project Roadmap"
generated: 2026-08-05
status: "skeleton — pending your answers on network resolution, compute split, audience, and pacing"
---

# Road to OracleOCM — Roadmap

Decisions locked in: GoldenGate starts **Classic**, migrates to **Microservices** later (its own showcase post). RAC storage is **ASM**. **MongoDB/SQL Server integration is in scope.** VM provisioning is **scripted (IaC)**, not just in-database automation.

Still open: exact vCPU/RAM split across VMs, SCAN/VIP name resolution (DNS vs. `/etc/hosts`), audience depth, and pacing — fill these in before you start Phase 0, they'll shape the network and post-writing choices below.

| Phase | Focus | Build | 2-3 features to demo | Showcase post angle |
|---|---|---|---|---|
| 0 | Foundation & IaC | Oracle Linux 9 base image; Vagrant/Packer + Ansible to provision all VMs on the VirtualBox host; network design (interconnect, SCAN/VIP resolution) | Ansible role structure for repeatable Oracle VM builds | "Building a rebuildable Oracle lab with code, not clicks" |
| 1 | 12c RAC + ASM | Grid Infrastructure 12c, ASM, 2-node cluster, first CDB with PDBs | Multitenant CDB/PDB basics; ASM disk group layout | "Your first RAC cluster: what actually connects the two nodes" |
| 2 | 12c Data Guard (FSFO) + GoldenGate Classic | Standby DB, Broker with Fast-Start Failover; GoldenGate Classic Extract/Pump/Replicat colocated with DG on one server | Broker-managed automatic failover; GoldenGate Classic capture setup | "Same server, two jobs: running Data Guard and GoldenGate side by side" |
| 3 | Security & performance baseline | TDE, Unified Audit, Data Redaction; AWR/ADDM/SQL Tuning Advisor baseline; extend OEM 13.5 Administrative Groups/Metrics to the new estate | TDE tablespace encryption; Unified Audit policies | "Locking down and measuring the cluster before it goes further" |
| 4 | Upgrade 12c → 19c | AutoUpgrade utility across CDB/PDBs, RAC, DG, GG; re-validate and patch to latest RU | 2-3 genuinely-new-in-19c features (confirm current ones via docs when you arrive here) | "Upgrading a live RAC+DG+GG stack without starting over" |
| 5 | OEM 13.5 → 24ai + Fleet Maintenance | Out-of-place EM upgrade (13.5 RU22+ required); patch the RAC databases via Fleet Maintenance (EMCLI, out-of-place — no GUI for this step) | Fleet Maintenance patching workflow; Administrative Groups in 24ai | "Upgrading the thing that watches everything else" |
| 6 | GoldenGate Classic → Microservices | Migrate the Phase 2 GoldenGate deployment to Microservices/REST architecture | Microservices deployment model; REST-based monitoring | "Retiring GoldenGate Classic: the migration, not just the theory" |
| 7 | Upgrade 19c → 26ai | AutoUpgrade (or ZDM) to 26ai | Built-in AI Vector Search / Select AI; Automatic Transaction Rollback; Real-Time SQL Plan Management | "What an AI-native Oracle release actually changes for a DBA" |
| 8 | Cross-database integration | Native MongoDB API access on 26ai; SQL Server heterogeneous connectivity via Database Gateway | MongoDB API compatibility; Database Gateway config | "Polyglot persistence in an Oracle shop" |
| 9 | APEX + ORDS + WebLogic test app | APEX 18+, ORDS 22+, WebLogic 14 (Fusion Middleware + Suite), WebLogic patching; simple app against the RAC/DG-protected backend | ORDS REST-enabled endpoints; WebLogic patching workflow | "Putting a face on the cluster: a small app, a big backend" |
| 10 | Automation & CI/CD wrap-up | GitLab CI pipelines for patch testing/deployment; consolidated Ansible playbooks; OCI DBaaS excursion (name the specific service) | GitLab CI pipeline for DB patching; OCI DBaaS comparison | "From clicking through patches to pipelines" |
| 11 | Capstone | End-to-end OCM-style practical run-through across the whole stack | — | "What I'd tell someone starting this same road" |

Each phase, when you finish it, becomes one Mode-2 invocation: tell the skill what you built/observed and it drafts the post using the template in `03-showcase-post-template.md`.
