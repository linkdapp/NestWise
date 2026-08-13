---
title: "Road to OracleOCM — Project Roadmap"
generated: 2026-08-05
updated: 2026-08-12
status: "Phase 0/1 built. Phase 2 (Data Guard) in progress. NestWise app moved up to Phase 3."
---

# Road to OracleOCM — Roadmap

Decisions locked in: OS is **Oracle Linux 7** for Phase 0/1 and Phase 2 (not certified
for the later 26ai upgrade — a planned OS migration before that phase, see
`phase-01-foundation-2node-rac-12cR2/docs/known-risks.md` #1). Grid Infrastructure is
**19c**, database software stays **12.2.0.1** through Phase 3 — an intentional,
independent-version pairing (`known-risks.md` #2), not a mismatch to fix. RAC storage
is **ASM**. GoldenGate starts **Classic**, migrates to **Microservices** later (its
own showcase post). **NestWise** (Oracle APEX + ORDS app) ships as pure-Oracle v1
right after Data Guard, with a MongoDB-backed v2 as its own later phase — not bundled
into the first app release. VM provisioning is **scripted (IaC)**, not just
in-database automation.

Still open: exact pacing past Phase 3, and how deep the MongoDB integration in Phase
10 goes (schema design, sync mechanism) — fill in once Phase 3 (NestWise v1) is done
and there's a real app to extend.

| Phase | Focus | Build | 2-3 features to demo | Showcase post angle |
|---|---|---|---|---|
| 0/1 | Foundation + 2-node RAC | Oracle Linux 7; Ansible-provisioned golden image + clone; Grid Infrastructure 19c + Database 12.2.0.1, 2-node admin-managed RAC on ASM; General Purpose non-CDB database (`apexdb`) | Silent GI/DB install end to end; ASM diskgroup layout (`DATA01`/`RECO01`); redo log multiplexing via DBCA response file | "Building a rebuildable Oracle RAC lab with code, not clicks" — 🟩 Built |
| 2 | Data Guard (Broker + FSFO) | Standby database, Broker-managed automatic failover | Broker-managed automatic failover; Swingbench load through a switchover | "Protecting the cluster before anything depends on it" — 🟨 In progress |
| 3 | **NestWise v1** — APEX + ORDS application | APEX + ORDS against the RAC/DG-protected `apexdb` backend, pure Oracle | ORDS REST-enabled endpoints; a real app surviving a Data Guard failover | "Putting a face on the cluster: a small app, a big backend" |
| 4 | GoldenGate Classic | Extract/Pump/Replicat colocated with DG on one server | GoldenGate Classic capture setup against a live app | "Same server, two jobs: Data Guard and GoldenGate side by side" |
| 5 | Security & performance baseline | TDE, Unified Audit, Data Redaction; AWR/ADDM/SQL Tuning Advisor baseline against NestWise's real workload | TDE tablespace encryption; Unified Audit policies | "Locking down and measuring the cluster once something's actually using it" |
| 6 | Upgrade 12c → 19c | AutoUpgrade utility across RAC, DG, GG, with NestWise running through it | 2-3 genuinely-new-in-19c features (confirm current ones via docs when you arrive here) | "Upgrading a live RAC+DG+GG stack without starting over" |
| 7 | OEM 13.5 → 24ai + Fleet Maintenance | Out-of-place EM upgrade (13.5 RU22+ required); patch the RAC databases via Fleet Maintenance (EMCLI, out-of-place — no GUI for this step) | Fleet Maintenance patching workflow; full NestWise observability | "Upgrading the thing that watches everything else" |
| 8 | GoldenGate Classic → Microservices | Migrate the Phase 4 GoldenGate deployment to Microservices/REST architecture | Microservices deployment model; REST-based monitoring | "Retiring GoldenGate Classic: the migration, not just the theory" |
| 9 | Upgrade 19c → 26ai | AutoUpgrade (or ZDM) to 26ai | Built-in AI Vector Search / Select AI; Automatic Transaction Rollback; Real-Time SQL Plan Management | "What an AI-native Oracle release actually changes for a DBA" |
| 10 | **NestWise v2** — MongoDB cross-database integration | Native MongoDB API access, extending NestWise with listings/weather/venue data | MongoDB API compatibility against a real app; hybrid relational + document queries | "Polyglot persistence, running behind an app people can actually use" |
| 11 | Automation & CI/CD wrap-up | GitLab CI pipelines for patch testing/deployment; consolidated Ansible playbooks; OCI DBaaS excursion (name the specific service) | GitLab CI pipeline for DB patching; OCI DBaaS comparison | "From clicking through patches to pipelines" |
| 12 | Capstone | End-to-end OCM-style practical run-through across the whole stack, NestWise included | — | "What I'd tell someone starting this same road" |

Each phase, when finished, becomes one Mode-2 invocation: describe what was built/observed
and the skill drafts the post using the template in `03-showcase-post-template.md`.

SQL Server heterogeneous connectivity (originally slated for the old Phase 8) is
deferred indefinitely — MongoDB is the confirmed cross-database target for NestWise
v2; a second non-Oracle source isn't currently planned unless that changes.
