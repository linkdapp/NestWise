---
title: "Backup & Recovery"
---

# Backup & Recovery

**Status: ⬜ Planned — not built yet.** This page will hold the SOP once this phase is
built; no procedures or output are documented here yet.

## Scope

- **RMAN** — backup strategy for the RAC database (full/incremental, backup to the
  `RECO01` diskgroup / FRA already provisioned in [`installation/`](../installation/)),
  restore/recovery drills, block media recovery.
- **Data Pump** — the logical companion to RMAN's physical backups: schema-level
  export/import, used later for PDB relocation prep and cross-version migration during
  the 12c→19c and 19c→26ai upgrade phases.
- Recovery validation against the Data Guard standby once [`high-availability/`](../high-availability/)
  is built — a backup strategy that's never been tested by an actual restore isn't a
  backup strategy.

Not yet assigned an explicit phase number in [`../02-roadmap-skeleton.md`](../02-roadmap-skeleton.md)
beyond being implied throughout — will get a dedicated phase or fold into Phase 3
(security & performance baseline) as the roadmap firms up.

## What will go here once built

- `README.md` rewritten as a step-by-step SOP (same format as [`installation/README.md`](../installation/README.md))
- `screenshots/` — RMAN backup/restore command output, a recovery drill end to end,
  Data Pump export/import logs
