# High Availability

**Status: ⬜ Planned — not built yet.** This page will hold the SOP once this phase is
built; no procedures or output are documented here yet, so nothing below is a substitute
for the real thing.

## Scope

This folder will cover the availability layer built on top of the [`installation/`](../installation/)
RAC cluster:

- **Data Guard** — physical standby, Broker configuration, Fast-Start Failover (Phase 2
  of the roadmap).
- **RAC failover behavior** — proving instance/node failover actually holds client
  sessions, not just that the cluster reports healthy.
- **Application Continuity** — the feature that separates "failover eventually happens"
  from "the application barely notices." Demoed with Swingbench driving load through a
  switchover so there's a throughput chart to show, not just a log line.
- **GoldenGate** — Classic replication (Phase 2), later migrated to Microservices
  (Phase 6).

See [`../02-roadmap-skeleton.md`](../02-roadmap-skeleton.md) for exact phase numbers and
sequencing.

## What will go here once built

- `README.md` rewritten as a step-by-step SOP (same format as [`installation/README.md`](../installation/README.md))
- `screenshots/` — Data Guard Broker status, FSFO failover timing, Swingbench
  throughput graphs across a switchover, GoldenGate lag/status output
