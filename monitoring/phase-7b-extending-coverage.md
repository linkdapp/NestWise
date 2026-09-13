# Phase 7b: Extending Enterprise Manager Coverage

**SOP: onboard the RAC and app-tier hosts, group them by lifecycle, standardise them with monitoring templates and an agent gold image, and monitor APEX, ORDS and MongoDB with Metric Extensions**

Status: 🟩 Confirmed 2026-09-09. All six steps complete.

Console work throughout. No Ansible.

## The six steps, in execution order

The file names follow section numbering. The execution order does not. Work
through the table.

| Step | Do this | Where | Status |
|---|---|---|---|
| 1 | Deploy one reference agent to `oradbserv05` | [Part 1](phase-7b-part1-reference-agent.md) §§1-5 | 🟩 |
| 2 | Cut the gold image from it | [Part 3](phase-7b-part3-golden-image.md) §§13-14 | 🟩 |
| 3 | Install agents on `oradbserv04`, `06`, `09`, `10` from the image | [Part 3](phase-7b-part3-golden-image.md) §§15-17 | 🟩 |
| 4 | Administration groups, monitoring templates, template collections | [Part 2](phase-7b-part2-admin-groups.md) §§6-11 | 🟩 |
| 5 | Discover and promote targets on all five hosts | [Discovery procedure](oem-discover-and-promote-targets.md) | 🟩 |
| 6 | Metric Extensions for APEX, ORDS, MongoDB | [Part 4](phase-7b-part4-metric-extensions.md) §§18-24 | 🟩 |

Subscription is not a step. Installing an agent from a gold image subscribes it
automatically, confirmed in
[Part 3 §16](phase-7b-part3-golden-image.md#16-subscriptions).

---

## The estate after this phase

| Host | Runs | Lifecycle Status | Agent |
|---|---|---|---|
| `oemserver01.usat.com` | OMS 13.5, `oemcdb` repository database | Production | Already monitored |
| `oradbserv05.usat.com` | RAC node 1, `usatclust1`, `apexdb` | Production | Part 1, installed by hand |
| `oradbserv06.usat.com` | RAC node 2, `usatclust1`, `apexdb` | Production | Part 3 §15, from the image |
| `oradbserv09.usat.com` | RAC node 1, `usatclust2`, `apexdb_stby` | Test | Part 3 §15, from the image |
| `oradbserv10.usat.com` | RAC node 2, `usatclust2`, `apexdb_stby` | Test | Part 3 §15, from the image |
| `oradbserv04.usat.com` | NestWise app tier: ORDS 26.x, MongoDB 6.0, Node proxy | Development | Part 3 §15, from the image |
| `oradbserv01.usat.com` | Legacy single-instance database | Development | Already monitored |
| `orappsserv01.usat.com` | EBS application server | Development | Already monitored |

**Record the target count.** `emcli get_targets | wc -l` returned 43 at Phase 7a,
168 in Part 1 §1 once the agents were in, and 203 before the 24ai upgrade window
in [Phase 7c Part 2b §1.2](phase-7c-part2b-deployment.md#12-record-the-target-count).
Take a fresh count in each window rather than carrying an earlier one forward.

---

## Standing procedures

- [Discovering and Promoting Targets in Enterprise Manager 13.5](oem-discover-and-promote-targets.md).
  Run once per host after its agent is uploading. Used by step 5.
- [Creating a Blackout in Enterprise Manager 13.5](oem-create-blackout.md). Needed
  before any agent restart that would raise incidents. Not required by this phase,
  since the hosts were unmonitored when their agents were installed.

## Related pages

- [Part 1: The reference agent](phase-7b-part1-reference-agent.md)
- [Part 2: Administration groups](phase-7b-part2-admin-groups.md)
- [Part 3: Agent gold image](phase-7b-part3-golden-image.md)
- [Part 4: Metric Extensions](phase-7b-part4-metric-extensions.md)
- [Phase 7a: Patching the OEM repository database](phase-7a-repository-db-ru32.md)
- [Phase 7c: OMS 13.5 to 24ai](phase-7c-oms-upgrade.md)
- [`../nestwise-app/docs/architecture.md`](../nestwise-app/docs/architecture.md),
  the application Part 4 monitors

---

## Appendix A: Notes

None of this is needed to run the six steps.

**Why one agent by hand and four from the image.** A gold agent image does two
jobs: provisioning a new agent onto a bare host, and lifecycle management, where
existing agents subscribe and a new image version is pushed to all of them.
Installing all five from the wizard and building an image afterwards gets the
second job only, having done the install work five times.

**The image is a software baseline, not a copy of `oradbserv05`.** It carries the
agent version, its patches and its plug-ins. It does not carry that host's
targets or its `emd.properties`.

**The image is cut before any discovery has run**, which keeps it a plain 13.5
agent. Discovery is per host and each host acquires the plug-ins its own targets
need.

**A gold image cannot update an agent that carries more plug-ins than the image.**
`oradbserv05` carries one plug-in, `oracle.sysman.oh`, so the image cut from it
could not update `oradbserv01` or `orappsserv01`, which carry three and two. See
[Part 3 Appendix B.2](phase-7b-part3-golden-image.md#b2-updating-an-agent-that-carries-more-plug-ins-than-the-image).


