---
title: "Road to OracleOCM — Project Roadmap"
generated: 2026-08-05
updated: 2026-08-31
status: "Phases 0/1, 2, 3, 6 and 10 built. Phases 4, 5, 7, 8, 9, 11, 12 outstanding."
---

# Road to OracleOCM — Roadmap

Decisions locked in: OS is **Oracle Linux 7** for Phase 0/1 and Phase 2 (not certified
for the later 26ai upgrade, so a planned OS migration precedes that phase, see
`phase-01-foundation-2node-rac-12cR2/docs/known-risks.md` #1). Grid Infrastructure is
**19c**. RAC storage is **ASM**. GoldenGate starts **Classic** and migrates to
**Microservices** later, as its own showcase post. VM provisioning is
**scripted (IaC)**, not just in-database automation.

## Where this has actually diverged from the plan

Two things happened out of sequence, and the table below now reflects reality rather
than the original ordering.

**The 12c to 19c upgrade (Phase 6) landed early**, ahead of GoldenGate and the
security baseline. The database now runs **19.32.0.0.0**, not 12.2.0.1. That
supersedes the original note about database software staying at 12.2.0.1 through
Phase 3, and `known-risks.md` #2's independent-version pairing no longer describes
the current state.

**NestWise shipped as one build rather than a v1/v2 split.** The plan was pure-Oracle
v1 at Phase 3 with MongoDB deferred to Phase 10. In practice both were built
together: 12 pages, hybrid from the start, including a `venues` collection that was
never in the original scope. Phase 10's content is therefore complete, and
`nestwise-app/docs/v2-roadmap.md` describes a future that has already happened.

Neither reordering was a mistake, but a reader comparing this roadmap against the
repository would otherwise find them contradicting each other.

## The gap that outranks the remaining phases

Five phases are built and, until 2026-08-31, **none of them had been written up**.
For a project whose stated purpose is showing hiring managers and other DBAs what
this work looks like, unpublished work counts for very little. The first post
(the Data Guard switchover under load) exists now; Phases 0/1, 6 and 10 still have
none.

Still open: exact pacing past the current position, and whether GoldenGate (Phase 4)
or the security and performance baseline (Phase 5) comes first.

| Phase | Focus | Build | 2-3 features to demo | Showcase post angle |
|---|---|---|---|---|
| 0/1 | Foundation + 2-node RAC | Oracle Linux 7; Ansible-provisioned golden image + clone; Grid Infrastructure 19c + Database 12.2.0.1, 2-node admin-managed RAC on ASM; General Purpose non-CDB database (`apexdb`) | Silent GI/DB install end to end; ASM diskgroup layout (`DATA01`/`RECO01`); redo log multiplexing via DBCA response file | "Building a rebuildable Oracle RAC lab with code, not clicks" — 🟩 Built |
| 2 | Data Guard (Broker + FSFO) | Standby database, Broker-managed automatic failover | Broker-managed switchover; role-based services relocating; Swingbench load through a switchover | "One minute, or never: measuring a Data Guard switchover under real load" — 🟩 Built, **post published** |
| 3 | **NestWise v1** — APEX + ORDS application | APEX + ORDS against the RAC/DG-protected `apexdb` backend | ORDS REST-enabled endpoints; a real app on the cluster | 🟩 Built. Superseded in scope by Phase 10, which was built at the same time. No post yet |
| 4 | GoldenGate Classic | Extract/Pump/Replicat colocated with DG on one server | GoldenGate Classic capture setup against a live app | "Same server, two jobs: Data Guard and GoldenGate side by side" — ⬜ Not started. Largest untouched area |
| 5 | Security & performance baseline | TDE, Unified Audit, Data Redaction; AWR/ADDM/SQL Tuning Advisor baseline against NestWise's real workload | TDE tablespace encryption; Unified Audit policies | "Locking down and measuring the cluster once something's actually using it" — ⬜ Not started. Prerequisite now exists: `nestwise-app/loadtest/k6/` gives repeatable, application-shaped load |
| 6 | Upgrade 12c → 19c | AutoUpgrade / DBMS_ROLLING across RAC and DG | 2-3 genuinely-new-in-19c features | "Upgrading a live RAC+DG stack without starting over" — 🟩 **Built out of sequence.** Now on 19.32.0.0.0. See `maintenance/` parts 1-2, including the `DBMS_ROLLING.DESTROY_PLAN` finding. No post yet |
| 7 | OEM 13.5 → 24ai + Fleet Maintenance | Out-of-place EM upgrade (13.5 RU22+ required); patch the RAC databases via Fleet Maintenance (EMCLI, out-of-place — no GUI for this step) | Fleet Maintenance patching workflow; full NestWise observability | "Upgrading the thing that watches everything else" |
| 8 | GoldenGate Classic → Microservices | Migrate the Phase 4 GoldenGate deployment to Microservices/REST architecture | Microservices deployment model; REST-based monitoring | "Retiring GoldenGate Classic: the migration, not just the theory" |
| 9 | Upgrade 19c → 26ai | AutoUpgrade (or ZDM) to 26ai | Built-in AI Vector Search / Select AI; Automatic Transaction Rollback; Real-Time SQL Plan Management | "What an AI-native Oracle release actually changes for a DBA" |
| 10 | **NestWise v2** — MongoDB cross-database integration | Node/Express proxy fronting MongoDB, surfaced through APEX REST Data Sources. Listings with embedded reviews, movies, weather, venues | Hybrid relational + document rendering on one page; a real cross-database integrity bug found and fixed at the cause | "Polyglot persistence, running behind an app people can actually use" — 🟩 **Built out of sequence**, alongside Phase 3. 12 pages. See `nestwise-app/README.md`. No post yet |
| 11 | Automation & CI/CD wrap-up | GitLab CI pipelines for patch testing/deployment; consolidated Ansible playbooks; OCI DBaaS excursion (name the specific service) | GitLab CI pipeline for DB patching; OCI DBaaS comparison | "From clicking through patches to pipelines" |
| 12 | Capstone | End-to-end OCM-style practical run-through across the whole stack, NestWise included | — | "What I'd tell someone starting this same road" |

Each phase, when finished, becomes one Mode-2 invocation: describe what was built/observed
and the skill drafts the post using the template in `03-showcase-post-template.md`.

SQL Server heterogeneous connectivity (originally slated for the old Phase 8) is
deferred indefinitely — MongoDB is the confirmed cross-database target for NestWise
v2; a second non-Oracle source isn't currently planned unless that changes.
