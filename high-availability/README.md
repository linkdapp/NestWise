# High Availability

**SOP: Data Guard Standby (`usatclust2`) — 2-Node Physical Standby for `apexdb`, on Oracle Linux 7**

Status: 🟩 Confirmed. This SOP is split into three parts, meant to be read and run in order:

| Part | Covers | Status |
|---|---|---|
| [Part 1 — Setting Up Active Data Guard](part1-active-data-guard.md) | Sections 1-13: host build, OS baseline, cluster config, RMAN-duplicate standby, RAC conversion, role-based services | 🟩 Confirmed |
| [Part 2 — Broker, Fast-Start Failover, and Observer](part2-broker-fsfo-observer.md) | Sections 14-15: Data Guard Broker, a real switchover test, FSFO + Observer | 🟩 Confirmed |
| [Part 3 — Post checks](part3-post-checks.md) | Sections 16-17: post-standby validation (Swingbench), screenshot checklist | 🟩 Confirmed |

Start with Part 1 if you're building this from scratch. Each part carries its own detailed
status table, prerequisites, and section-by-section commands/output.

Before starting, read
[`known-risks.md`](../phase-01-foundation-2node-rac-12cR2/docs/known-risks.md) for the full
reasoning and debugging history behind every fix referenced across all three parts, and
[`group_vars/all.yml`](../phase-01-foundation-2node-rac-12cR2/ansible/group_vars/all.yml)
for the real `standby_nodes`/`standby_cluster_name`/`standby_scan_name`/`standby_scan_ips`
addressing this repo already assumes.

This page follows the same format as
[`../installation/README.md`](../installation/README.md); update each part's status table
as it actually gets run.

Screenshots referenced across all three parts go in [`screenshots/`](screenshots/) once
captured — same naming convention as `installation/`'s Section 15, numbered to match each
part's own section numbers.

**Standing monitoring scripts** live in [`scripts/`](scripts/), referenced from the
part where each one is actually used: `montor_manage_observer.sh` (start/stop/status
for the FSFO Observer, Part 2) and `monitor_dataguard.sh` (role-aware primary/standby
health check, Part 3). A third script, `cluster_log_monitor.sh`, is general RAC/GI
log housekeeping rather than Data Guard-specific — it's referenced from
[`../installation/README.md`](../installation/README.md#14-post-install-validation)
instead, even though the file itself lives here.

---

*Previously this was a single ~1,900-line page. It's now split into the three parts above
for easier reading and GitHub publishing; the full section-by-section detail (prerequisites,
real commands, real output, known-risks cross-references) lives in each part, unchanged.*
