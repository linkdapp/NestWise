# High Availability — Part 3: Post Checks

**SOP: Data Guard Standby (`usatclust2`) — 2-Node Physical Standby for `apexdb`, on Oracle Linux 7**

Part 3 of 3 in this Data Guard series. [Part 1](part1-active-data-guard.md) covers the host
build through role-based services. [Part 2](part2-broker-fsfo-observer.md) covers the Data
Guard Broker, a real switchover test, and Fast-Start Failover with the Observer. **Part 3
(this page)** covers post-standby validation — the real remaining work in this series.

Status: ⬜ Planned — not built at all yet, described here only so the full shape of the
phase is visible up front.

| # | Section | Status |
|---|---|---|
| 16 | Post-standby validation | ⬜ Planned — not built |

Before starting here, read
[`known-risks.md`](../phase-01-foundation-2node-rac-12cR2/docs/known-risks.md) — the
same reasoning doc referenced throughout [Part 1](part1-active-data-guard.md) and
[Part 2](part2-broker-fsfo-observer.md).

---

## Contents

16. [⬜ Planned — Post-standby validation](#16-planned--post-standby-validation)
17. [Screenshot checklist and naming convention](#17-screenshot-checklist-and-naming-convention)

Back to **[Part 2 — Broker, Fast-Start Failover, and Observer](part2-broker-fsfo-observer.md)**.

---

## 16. ⬜ Planned — Post-standby validation

Not yet built. Intended to include a Swingbench-driven switchover (per this project's
standing toolkit) so there's a throughput chart showing the application barely
noticing, not just a log line saying failover completed.

---

## 17. Screenshot checklist and naming convention

Same convention as
[`installation/README.md` Section 15](../installation/README.md#15-screenshot-checklist-and-naming-convention) —
`NN[a/b]-short-description.png`, numbered to match each part's own section numbers
(so Part 1 screenshots are `01`-`13`, Part 2's are `14`-`15`, Part 3's are `16`).
Nothing captured yet; every 📸 marker across all three parts is a real gap, not a
placeholder to ignore.

---

Back to **[Part 2 — Broker, Fast-Start Failover, and Observer](part2-broker-fsfo-observer.md)**,
or **[Part 1 — Setting Up Active Data Guard](part1-active-data-guard.md)**.
