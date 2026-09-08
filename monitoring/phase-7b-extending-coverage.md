# Phase 7b: Extending Enterprise Manager Coverage

**SOP: onboard the RAC and app-tier hosts, group them by lifecycle, standardise them with monitoring templates and an agent golden image, and monitor APEX, ORDS and MongoDB with Metric Extensions**

Status: 🟨 In progress. Steps 1 to 5 are confirmed. Metric Extensions remain.

**This phase is manual, by design.** Phase 7a automated a patch window because
the work was a fixed sequence of shell commands against one host. This phase is
console work, most of it one-time configuration whose value is in the decisions
(which targets are Production, what a Development database should alert on)
rather than in the keystrokes.

**The file names follow section numbering. The execution order does not.** Work
through the steps below in order.

| Step | Do this | Where | Status |
|---|---|---|---|
| 1 | Deploy one reference agent to `oradbserv05` | [Part 1](phase-7b-part1-reference-agent.md) §§1-5 | 🟩 Confirmed |
| 2 | Cut the gold image from it | [Part 3](phase-7b-part3-golden-image.md) §§13-14 | 🟩 Confirmed |
| 3 | Install agents on `oradbserv04`, `06`, `09`, `10` from the image | [Part 3](phase-7b-part3-golden-image.md) §§15-17 | 🟩 Confirmed |
| 4 | Administration groups, monitoring templates, template collections | [Part 2](phase-7b-part2-admin-groups.md) §§6-11 | 🟩 Confirmed |
| 5 | Discover and promote targets on all five hosts | [Discovery procedure](oem-discover-and-promote-targets.md) | 🟩 Confirmed |
| 6 | Metric Extensions for APEX, ORDS, MongoDB | [Part 4](phase-7b-part4-metric-extensions.md) §§18-24 | 🟨 Next |

Subscription is not a step. Installing an agent from a gold image subscribes it
automatically, confirmed in
[Part 3 §16](phase-7b-part3-golden-image.md#16-subscriptions).

---

## Why this order

### One agent by hand, four from the image

**Only `oradbserv05` is installed with the wizard.** `oradbserv04`, `06`, `09` and
`10` are *provisioned from a gold image* cut off that first agent, in Part 3 §15.

A gold agent image does two jobs, and the ordering decides how many of them you
get:

| Job | What it means |
|---|---|
| **Provisioning** | Deploy a new agent to a bare host from the image, with version, patches and plug-ins already baked in |
| **Lifecycle** | Existing agents subscribe; a new image version is staged and pushed to all of them in one operation, with drift reported |

Install all five from the installer and only then build an image, and you get the
second job alone, having done the install work five times. One install, one
image, four clones gets both.

**The image is a software baseline, not a copy of `oradbserv05`.** It carries the
agent version, its patches and its plug-ins. It does not carry that host's
targets, its `emd.properties`, or anything else specific to the machine.

**The image is cut before any discovery has run**, which keeps it a plain 13.5
agent. Target discovery is per host and runs after each host's own agent exists,
covered in
[Part 2 §12](phase-7b-part2-admin-groups.md#12-discover-and-promote-the-remaining-targets).
Each host then acquires the plug-ins its own targets need.

**One consequence, measured on this estate.** A gold image carrying fewer plug-ins
than an existing agent cannot update that agent. `oradbserv05` carries one
plug-in, `oracle.sysman.oh`, so the image cut from it could not update
`oradbserv01` or `orappsserv01`, which carry three and two. See
[Part 3 Appendix B.2](phase-7b-part3-golden-image.md#b2-updating-an-agent-that-carries-more-plug-ins-than-the-image).

### Groups before discovery, not after

**This is the point of administration groups.** Oracle's Monitoring Guide:
*"Template collections contain the monitoring settings ... meant to be applied to
targets **as they join** the administration group. ... Once added to the
administration group, Enterprise Manager **automatically applies** the requisite
monitoring settings."*

So a target promoted after step 4 lands in its group and takes its thresholds in
the same motion. Promote first and group afterwards, and an explicit apply pass
over existing targets is needed, which also overwrites any per-target tuning done
in between.

**Cluster templates do not have to wait for discovery.** Seeding a template from
**Target Type** rather than from a named target does not require a target of that
type to exist, so Cluster Database and Cluster templates were built in step 4
alongside the Database Instance and Host ones. See
[Part 2 §8.2](phase-7b-part2-admin-groups.md#82-copy-monitoring-settings).

### The rest of the ordering

1. **The image before the groups**, because the image should be cut from a clean
   agent and nothing in the grouping work touches the agent.
2. **Targets promoted before the hierarchy existed need Lifecycle Status set by
   hand.** `oemserver01`, `oradbserv01`, `orappsserv01` and `oradbserv05` fall
   into that group. See
   [Part 2 §10.3](phase-7b-part2-admin-groups.md#103-on-targets-already-promoted).
   Everything promoted from step 5 takes the property in the promotion wizard.
3. **Metric Extensions last.** They are deployed to targets and, where they should
   apply estate-wide, added to a template collection. Both need the rest finished.

---

## The estate after this phase

| Host | Runs | Lifecycle Status | Agent today |
|---|---|---|---|
| `oemserver01.usat.com` | OMS 13.5, `oemcdb` repository database | **Production** | 🟩 Already monitored |
| `oradbserv05.usat.com` | RAC node 1, `usatclust1`, `apexdb` | **Production** | 🟩 Part 1, the reference agent, installed by hand |
| `oradbserv06.usat.com` | RAC node 2, `usatclust1`, `apexdb` | **Production** | 🟩 Part 3 §15, from the image |
| `oradbserv09.usat.com` | RAC node 1, `usatclust2`, `apexdb_stby` | **Test** | 🟩 Part 3 §15, from the image |
| `oradbserv10.usat.com` | RAC node 2, `usatclust2`, `apexdb_stby` | **Test** | 🟩 Part 3 §15, from the image |
| `oradbserv04.usat.com` | NestWise app tier: ORDS 26.x, MongoDB 6.0, Node proxy | **Development** | 🟩 Part 3 §15, from the image |
| `oradbserv01.usat.com` | Legacy single-instance database | **Development** | 🟩 Already monitored |
| `orappsserv01.usat.com` | EBS application server | **Development** | 🟩 Already monitored |

> **`oradbserv05` is in the list even though the roadmap line said "06/09/10".**
> The blackout created during Phase 7a covered `oemserver01`, `oradbserv01` and
> `orappsserv01` and nothing else, which is the evidence that neither RAC cluster
> was monitored. Part 1 §1 confirmed it rather than trusting this table. `05` then
> became the natural reference host, which is what makes the roadmap's "pushed to
> `oradbserv06/09/10`" the right description of the other three.

> **`oradbserv04` is Development, not Production.** It fronts `apexdb`, which is
> Production, but it is a showcase application tier rather than a production
> service. Grouping it with the other non-production hosts also means the
> Metric Extensions in Part 4 land on a tier whose thresholds can be loose without
> anyone worrying about it.

**Target count is the number to watch.** Phase 7a recorded 43 targets before and
after the patch. Part 1 §1 recorded 168 once the agents were in. A RAC node alone
brings the host, the cluster, ASM, the listener, the database instance and the
cluster database. Use the current count in the next patch window, not 43.

---

## What this phase deliberately does not do

- **No Ansible.** See the note at the top. A future phase that needs agents
  deployed repeatedly, a fleet rebuild for example, is the point at which
  `agentDeploy.sh` justifies a role.
- **No credentials in this repository.** Named Credentials are created in the
  console and referenced by name. The MongoDB Metric Extension in Part 4 needs a
  Mongo login and the `NESTWISE_ADMIN_TOKEN` stays in
  `/etc/nestwise-proxy.env` (mode 640, `root:nestwise`) where the app already
  keeps it. Neither value is written down here.
- **No incident rules or notification methods.** Administration groups and
  template collections decide what is measured and at what threshold. Deciding who
  gets told is separate work. Incident rule sets bind to administration groups, so
  they are easier to write once the hierarchy is populated.
- **No 24ai-specific features.** This is all EM 13.5 functionality. Fleet
  Maintenance, the out-of-place patching mechanism, arrives with
  [Phase 7c](phase-7c-oms-upgrade.md).

---

## Screenshots

Screenshots for all four parts are in [`screenshots/`](screenshots/), following
the naming convention in
[`../installation/README.md`](../installation/README.md#15-screenshot-checklist-and-naming-convention)
Section 15: a prefix, then the section number the image illustrates.

**The prefix is `7c-`, not `7b-`.** These files were captured and committed while
this phase was numbered 7c, before it was moved ahead of the OMS upgrade. The
prefix was left alone during the renumber because renaming committed image files
risks silent broken links for no functional gain. It still serves its purpose,
which is to keep these distinct from Phase 7a's `03a-` and `16b-` series in the
same directory.

Per-part checklists are in
[Part 1 §6](phase-7b-part1-reference-agent.md#6-screenshot-checklist) and
[Part 3 §18](phase-7b-part3-golden-image.md#18-screenshot-checklist).

---

## Related pages

Two standing procedures this phase leans on, each written once and referenced
from wherever it is needed rather than duplicated:

- **[Discovering and Promoting Targets in Enterprise Manager 13.5](oem-discover-and-promote-targets.md)**,
  run once per host after its agent is uploading. Used by Part 2 §12 for all five
  hosts, and by any host onboarded after this phase.
- **[Creating a Blackout in Enterprise Manager 13.5](oem-create-blackout.md)**,
  needed before any agent restart that would otherwise raise incidents. Not
  required by this phase, since the hosts were unmonitored when their agents were
  installed. See [Part 3 Appendix B.1](phase-7b-part3-golden-image.md#b1-updating-an-agent-that-is-already-monitoring-live-targets).
- **[Phase 7a: Patching the OEM repository database](phase-7a-repository-db-ru32.md)**,
  the prerequisite for the OMS upgrade, already complete.
- **[`../nestwise-app/docs/architecture.md`](../nestwise-app/docs/architecture.md)**,
  the application Part 4 monitors: which data lives in Oracle, which lives in
  MongoDB, and how APEX reaches each tier.

---

## What this feeds into

- **Phase 7c**, the OMS 13.5 to 24ai upgrade. Doing coverage first means the
  upgrade is validated against a realistic estate rather than three hosts, and
  gives a real before and after target count.
- **Incident rules and notifications**, which are simpler to author once
  administration groups exist, because rule sets target groups rather than
  individual targets.
- **Phase 7d**, the non-CDB to CDB conversion of `oemcdb`.

## Open questions

- **Is `apexdb` 12cR2 or 19c?** `nestwise-app/docs/architecture.md` describes the
  cluster as 12cR2, while `../maintenance/` documents a `DBMS_ROLLING` upgrade to
  19c against it. Target discovery reports the truth. Record it and correct
  whichever document is stale.
- **Is there an ORDS or MongoDB plug-in for EM 13.5 to use instead of Metric
  Extensions?** Part 4 assumes not and builds Metric Extensions. Check the Self
  Update console and current Oracle documentation first. A supported plug-in is
  preferable to a hand-built extension.
- **`oradbserv01` and `orappsserv01` are still on 13.3 plug-ins.** Out of scope
  here and recorded in
  [Phase 7c Part 2 Appendix A](phase-7c-part2-24ai-upgrade.md#appendix-a-oradbserv01-and-orappsserv01).

Two questions from the original scoping are now settled. `oradbserv05` had no
agent, which is why it became the reference host. The reference agent was built
fresh rather than taken from `oemserver01`, so no drift was inherited.
