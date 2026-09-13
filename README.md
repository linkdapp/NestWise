---
layout: home
title: NestWise
permalink: /
---

# NestWise: A real application running on a real Oracle high-availability platform

**Road to Oracle OCM:** building a production-grade Oracle Maximum Availability
Architecture (MAA) lab from scratch, on real infrastructure, then proving it works by
running a real application on top of it, in public, mistakes included.

---

## The short version

Companies don't pay Oracle DBAs to install software once and walk away. They pay
them to keep systems running when hardware fails, data grows, and versions age out.
Customers should never notice. This project builds that skill set end to end: a real
two-node database cluster, automatic failover, live version upgrades, and a working
application layered on top, so the infrastructure has something real to protect
instead of sitting there configured but unused.

**NestWise** is that application, a local-recommendations tool (good neighborhoods,
restaurants, places to stay, what's playing nearby) built on Oracle APEX and ORDS.
It's deliberately small. What matters isn't its feature list; it's that it's a real
app, taking real traffic, depending on the platform underneath it actually staying up.

Where things stand right now: the database cluster is built and running a real
database, and automatic failover protection (Data Guard broker, Fast-Start
Failover, and a real Swingbench-driven switchover test with a genuine throughput
dip and recovery) is confirmed. The 12c to 19c rolling upgrade is done. Enterprise
Manager has been taken from 13.5 to 24ai, so the estate is monitored. NestWise v1
is being built on top of that foundation. From there the platform keeps growing
through replication, security hardening, an upgrade to 26ai, and eventually a
second data source (MongoDB) feeding into the same app.

Every step gets documented as it actually happened, including the parts that broke
first. [`known-risks.md`](phase-01-foundation-2node-rac-12cR2/docs/known-risks.md) alone
runs to 158 numbered issues hit and fixed during the build so far. That's the
point: this isn't a polished diagram of what Oracle HA is supposed to look like,
it's a record of building it.

---

## For the technical reader

![NestWise Architecture]({{ site.baseurl }}/assets/images/nestwise-architecture.svg)

🟩 Built &nbsp;&nbsp; 🟨 In progress &nbsp;&nbsp; ⬜ Planned

Single VirtualBox host (32 vCPU / 128GB RAM). RAC (Real Application Clusters) lets
both nodes serve the same database at once, so losing one doesn't mean losing the
database; ASM (Automatic Storage Management) is Oracle's own storage layer underneath
it, in place of a generic filesystem. Node 1 (`oradbserv05`) is built and
verified by hand, then cloned via Ansible to produce node 2 (`oradbserv06`). See
[`phase-01-foundation-2node-rac-12cR2/docs/golden-image-and-cloning.md`](phase-01-foundation-2node-rac-12cR2/docs/golden-image-and-cloning.md).
Grid Infrastructure runs 19c against a 12.2.0.1 database home, a deliberate and
independently versioned pairing rather than a mismatch. See
[`known-risks.md` #2](phase-01-foundation-2node-rac-12cR2/docs/known-risks.md). Full
network/DNS/time-sync design lives in
[`network-and-hosts.md`](phase-01-foundation-2node-rac-12cR2/docs/network-and-hosts.md).

---

## What is NestWise?

NestWise is a small, complete application that helps someone pick a neighborhood to
live in or stay in. It ships in two stages:

- **v1, in progress:** Oracle APEX and ORDS, pure Oracle end to end, with
  restaurant and neighborhood data and basic accounts, all in the RAC-protected
  database. The schema, seed data, Node proxy and ORDS REST modules are deployed
  and verified. The application pages are being built.
- **v2, a later phase:** the same app extended with MongoDB as a second data
  source for listings, weather and local-venue data, proving the platform handles
  polyglot data (relational plus document), not just Oracle.

It stays intentionally simple. The point isn't the app. It's that a real
application is what turns "a RAC cluster with failover configured" into "a RAC
cluster that keeps an application up," which is the thing a company actually pays
for.

---

## Project status

| Phase | Focus | Status | NestWise tie-in |
|---|---|---|---|
| 0/1 | [Foundation + 2-node RAC](installation/README.md) (GI 19c, DB 12.2.0.1, ASM) | 🟩 Built | The platform NestWise runs on |
| 2 | [Data Guard](high-availability/README.md) (Active DG, Broker, Fast-Start Failover, post-checks) | 🟩 Built | HA for NestWise before it goes live |
| 3 | **[NestWise](nestwise-app/docs/architecture.md)**, APEX, ORDS and MongoDB hybrid application | 🟨 In progress. Oracle schema, DDL and seed data, MongoDB seed data, Node proxy and ORDS REST modules all deployed and verified against live data. Oracle APEX 26.1 installed and reachable ([`apex-server-install.md`](nestwise-app/docs/apex-server-install.md)). Building the 12 application pages next | The application itself |
| 4 | GoldenGate Classic replication | ⬜ Planned | |
| 5 | Security and performance baseline (TDE, Unified Audit, AWR/ADDM) | ⬜ Planned | Hardens and tunes NestWise's backend |
| 6 | [Upgrade 12c to 19c](maintenance/README.md) (DBMS_ROLLING and AutoUpgrade) | 🟩 Built | Live upgrade, near-zero downtime |
| 7 | [OEM 13.5 to 24ai](monitoring/README.md) and Fleet Maintenance | 🟨 In progress. OMS at 24ai Release 1 Update 12. Agents and post-upgrade tasks outstanding | Full observability of NestWise |
| 8 | GoldenGate Classic to Microservices | ⬜ Planned | |
| 9 | Upgrade 19c to 26ai | ⬜ Planned | AI-native features (Vector Search, Select AI) |
| 10 | **NestWise v2**, MongoDB cross-database integration | ⬜ Planned | Hybrid relational and document data |
| 11 | Automation & CI/CD wrap-up | ⬜ Planned | Fully rebuildable NestWise demo |
| 12 | Capstone | ⬜ Planned | End-to-end OCM-style walkthrough |

Full phase detail: [`02-roadmap-skeleton.md`](02-roadmap-skeleton.md).

---

## How the repo is organized

- **Topic folders.** The showcase side, organized by DBA skill area the way a hiring
  manager or another DBA would browse a portfolio. Each is a self-contained SOP plus a
  `screenshots/` and real-output evidence trail:
  - [`installation/`](installation/README.md) 🟩 built
  - [`high-availability/`](high-availability/README.md) 🟩 built:
    [Part 1: Active Data Guard](high-availability/part1-active-data-guard.md) 🟩,
    [Part 2: Broker, FSFO, Observer](high-availability/part2-broker-fsfo-observer.md) 🟩,
    [Part 3: Post checks](high-availability/part3-post-checks.md) 🟩
  - [`backup-recovery/`](backup-recovery/README.md) ⬜ planned
  - [`performance-tuning/`](performance-tuning/README.md) ⬜ planned
  - [`monitoring/`](monitoring/README.md) 🟨 in progress:
    Phase 7a repository patch 🟩, Phase 7b coverage 🟩, Phase 7c OMS to 24ai 🟨
  - [`maintenance/`](maintenance/README.md) 🟩 built:
    [Part 1: INIT_PLAN to SWITCHOVER](maintenance/part1-dbms-rolling-plan-to-switchover.md) 🟩,
    [Part 2: FINISH_PLAN, troubleshooting, pre-flight checklist](maintenance/part2-finish-plan-and-troubleshooting.md) 🟩
- **`phase-NN-*/` folders** (for example `phase-01-foundation-2node-rac-12cR2/`) hold the
  infrastructure-as-code (Ansible roles, silent-install response files, patch
  scripts) that builds the lab, one per roadmap phase.
- **[`nestwise-app/`](nestwise-app/docs/architecture.md)** is the application itself (Phase 3):
  Oracle schema and packages, MongoDB seed data, ORDS REST modules, a thin Node proxy
  fronting MongoDB, the APEX page plan, and a custom Swingbench workload. The schema,
  seed data, proxy and REST modules are deployed and verified against the live
  cluster. The application pages are not built yet.

```
Oracle-DBA-POC/
├── README.md                                  ← you are here
├── 01-gap-analysis-and-questions.md            planning: blueprint gap analysis
├── 02-roadmap-skeleton.md                      planning: full phased roadmap
├── 03-showcase-post-template.md                planning: post template
├── installation/                               built: SOP plus screenshots
├── high-availability/                          built: all 3 parts confirmed
├── backup-recovery/                            planned: RMAN, Data Pump
├── performance-tuning/                         planned: AWR, ADDM, SQL Tuning Advisor
├── monitoring/                                 in progress: OEM 13.5 to 24ai, AHF
├── maintenance/                                built: DBMS_ROLLING 12c to 19c upgrade
└── phase-01-foundation-2node-rac-12cR2/        the actual Ansible/scripts for Phase 1
    ├── README.md
    ├── docs/
    ├── ansible/
    ├── response-files/
    └── scripts/
```

---

## Standing toolkit

- **Swingbench** drives real, sustained load so HA and DR claims have an actual
  throughput chart behind them, not just a log line saying "failover completed."
  Once NestWise is live, this is what proves it barely noticed a switchover.
- **Oracle Autonomous Health Framework (AHF)** runs compliance checks, the modern
  home of `orachk`, before and after every patch or upgrade, diffed as evidence.
- **SQL Developer** for everyday query and schema work across the estate.

Two things shape the design without being tools themselves: this build follows
Oracle's **Maximum Availability Architecture (MAA)** reference design, and its
filesystem layout follows **Optimal Flexible Architecture (OFA)** conventions from
Phase 0 onward.

---

## About

Built and documented in public by me as a hands-on demonstration of Oracle DBA
skills at OCM depth: installation, high availability, backup and recovery,
performance, monitoring, maintenance, and from Phase 3 a real application running
on top of all of it. Not a collection of isolated demos, but a living platform
that gets an actual workload once NestWise goes live and stays live through every
upgrade after that.
