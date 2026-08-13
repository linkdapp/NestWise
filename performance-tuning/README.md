# Performance Tuning

**Status: ⬜ Planned — not built yet.** This page will hold the SOP once this phase is
built; no procedures or output are documented here yet.

## Scope

Part of Phase 3 in the roadmap (security & performance baseline), run against the RAC
cluster and non-CDB database built in [`installation/`](../installation/):

- **AWR / ADDM** — baseline snapshots, established *with real load* (Swingbench, not an
  idle instance) so the reports mean something.
- **SQL Tuning Advisor** — real tuning cycles against Swingbench-generated workload.
- **Real-Time SQL Plan Management** — a 26ai feature; will only apply once the stack
  reaches Phase 7 (19c → 26ai upgrade), but the AWR/ADDM baseline methodology
  established here is what makes the "before/after" comparison at that phase credible.

See [`../02-roadmap-skeleton.md`](../02-roadmap-skeleton.md) Phase 3 for full scope.

## What will go here once built

- `README.md` rewritten as a step-by-step SOP (same format as [`installation/README.md`](../installation/README.md))
- `screenshots/` — AWR report excerpts, ADDM findings, SQL Tuning Advisor
  recommendations and before/after execution plans, Swingbench load charts
