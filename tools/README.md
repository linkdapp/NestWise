# Tools

This section covers the standing tools used across every phase of this project — not
tied to any single build phase, reached for whenever a phase needs load, health, or
query-level evidence rather than just a config change asserted to have worked.

- **[Swingbench — Install and Use](swingbench/)** — 🟩 Built. The load-generation tool
  behind every real throughput chart in this project, including the Data
  Guard/Application Continuity switchover test in
  [`high-availability/part3-post-checks.md` Section 16](../high-availability/part3-post-checks.md#16-confirmed--post-standby-validation).
- **Oracle Autonomous Health Framework (AHF)** — the modern home of `orachk`/`exachk`
  plus TFA, run for a compliance check before and after every patch or upgrade phase.
  No dedicated page yet; documented as part of [`monitoring/`](../monitoring/) once
  that phase is built.
- **SQL Developer** — the everyday GUI for query work and schema browsing across the
  estate. Background tool, not a phase headline — no dedicated page planned.
