# Monitoring

**Status: ⬜ Planned — not built yet.** This page will hold the SOP once this phase is
built; no procedures or output are documented here yet.

## Scope

- **OEM 13.5 → 24ai upgrade** (Phase 5) — out-of-place, requires starting from EM 13.5
  RU22 or later. Fleet Maintenance in 24ai patches databases/Grid Infrastructure
  out-of-place via the `emcli` verb only — no GUI option for that step, which is itself
  worth documenting since it trips people up.
- **Extending OEM coverage** to the RAC cluster and (once built) the standby database —
  Administrative Groups, metric thresholds, incident rules.
- **AHF / orachk compliance checks** — run before and after every patch or upgrade phase
  project-wide (see the root README's "Standing toolkit"), with the pre/post reports
  archived here as evidence rather than just asserted.

See [`../02-roadmap-skeleton.md`](../02-roadmap-skeleton.md) Phase 5 for full scope.

## What will go here once built

- `README.md` rewritten as a step-by-step SOP (same format as [`installation/README.md`](../installation/README.md))
- `screenshots/` — OEM 24ai console showing the cluster under management, Fleet
  Maintenance `emcli` patching session output, AHF compliance report diffs
