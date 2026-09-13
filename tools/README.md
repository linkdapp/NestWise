# Tools

This section covers the standing tools used across every phase of this project. They
are not tied to any single build phase; each is reached for whenever a phase needs
load, health or query-level evidence rather than a config change asserted to have
worked.

- **[Swingbench: install and use](swingbench/)** 🟩 Built. The load-generation tool
  behind every real throughput chart in this project, including the Data
  Guard and Application Continuity switchover test in
  [`high-availability/part3-post-checks.md` Section 16](../high-availability/part3-post-checks.md#16-confirmed--post-standby-validation).
- **Oracle Autonomous Health Framework (AHF)**: the modern home of `orachk` and
  `exachk` plus TFA, run for a compliance check before and after every patch or
  upgrade phase. No dedicated page. The commands and the pre-patch baseline are in
  [`monitoring/phase-7a-part1-before-the-window.md` §5.6](../monitoring/phase-7a-part1-before-the-window.md#56-ahf-compliance-baseline),
  and the reference notes are in
  [`monitoring/phase-7c-part2c-post-deployment.md` Appendix A.3](../monitoring/phase-7c-part2c-post-deployment.md#11-appendix-a-reference-notes).
- **SQL Developer**: the everyday GUI for query work and schema browsing across the
  estate. Background tool rather than a phase headline; no dedicated page planned.
