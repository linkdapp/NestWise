# Maintenance

**Status: ⬜ Planned — not built yet.** This page will hold the SOP once this phase is
built; no procedures or output are documented here yet.

## Scope

- **Patching methodology** — same patch-before-configure discipline used in
  [`installation/`](../installation/), applied to ongoing quarterly Release Updates
  once the cluster is live (not just the initial build).
- **AutoUpgrade** — the current standard for the 12c → 19c (Phase 4) and 19c → 26ai
  (Phase 7) upgrades. DBUA is legacy and intentionally not used anywhere in this project.
- **Fleet Maintenance** (once [`monitoring/`](../monitoring/)'s OEM 24ai upgrade is
  done) — out-of-place patching orchestrated from OEM, `emcli`-only for the initial
  workflow.
- AHF compliance check, run and archived before/after every maintenance action here too
  (see root README "Standing toolkit").

See [`../02-roadmap-skeleton.md`](../02-roadmap-skeleton.md) Phases 4 and 7 for full scope.

## What will go here once built

- `README.md` rewritten as a step-by-step SOP (same format as [`installation/README.md`](../installation/README.md))
- `screenshots/` — AutoUpgrade pre-checks and execution output, post-upgrade validation,
  AHF compliance diffs
