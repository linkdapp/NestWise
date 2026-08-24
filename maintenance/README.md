# Maintenance

**SOP: 12.2.0.1 → 19c rolling upgrade of `apexdb`/`apexdb_stby` (2-node RAC + Data Guard, both clusters), on Oracle Linux 7**

Status: 🟩 Built. This SOP is split into two parts, meant to be read and run in order:

| Part | Covers | Status |
|---|---|---|
| [Part 1 — DBMS_ROLLING: INIT_PLAN through SWITCHOVER](part1-dbms-rolling-plan-to-switchover.md) | Pre-upgrade decisions and checks, getting the 19c software in place, disabling Fast-Start Failover, INIT_PLAN/BUILD_PLAN/START_PLAN, AutoUpgrade against the transient logical standby, and SWITCHOVER (2 real failures fixed) | 🟩 Confirmed |
| [Part 2 — FINISH_PLAN, Troubleshooting, and the Pre-Flight Checklist](part2-finish-plan-and-troubleshooting.md) | The FINISH_PLAN prerequisite (3 real failures fixed), a pre-flight checklist worth running every time, the ORA-45414 root cause, final confirmation, and the post-upgrade procedure — normalization, switchback, and an RMAN Level 0 backup | 🟩 Confirmed |

Start with Part 1 if you're building this from scratch — **§3, "Before you start,"** is the pre-upgrade checklist worth reading before touching anything. **If you only read one section once you're mid-upgrade, read [Part 2 §7](part2-finish-plan-and-troubleshooting.md#7-pre-flight-checklist--run-this-before-finish_plan)** — the pre-flight checklist that would have caught both real failures behind `FINISH_PLAN` before they happened.

Upgrade mechanism: `DBMS_ROLLING` (Oracle's Data-Guard-based rolling upgrade package), not a plain in-place `AutoUpgrade` run — this project's 19c software home was already installed on all four nodes ahead of time (a separate groundwork phase), so the actual upgrade here is a near-zero-downtime role-swap-and-catch-up, orchestrated end to end via Ansible (`dbms-rolling-execute.yml`, role `dbms_rolling_upgrade`).

Screenshots referenced across both parts go in [`screenshots/`](screenshots/) once captured — same naming convention as [`installation/`](../installation/README.md)'s Section 15.

This page follows the same format as [`../high-availability/README.md`](../high-availability/README.md).

---

*This SOP is written as it actually happened, real failures included — see each part's "What went wrong" content inline. Nothing here is a sanitized retelling; every command and error message is real output from the live lab.*
