# Phase 7c — Extending Enterprise Manager Coverage

**SOP: onboard the RAC and app-tier hosts, group them by lifecycle, standardise them with monitoring templates and an agent golden image, and monitor APEX, ORDS and MongoDB with Metric Extensions**

Status: 🟨 In progress. Parts 1 and 3 are confirmed, the reference agent is deployed
on `oradbserv05`. Statuses, real console output, screenshots and any surprises
get filled in as it is actually executed — the same way
[`../installation/README.md`](../installation/README.md) and
[`phase-7a-repository-db-ru32.md`](phase-7a-repository-db-ru32.md) were written.

**This phase is manual, by design.** Phase 7a automated a patch window because
the work was a fixed sequence of shell commands against one host. 7c is the
opposite: it is console work, most of it one-time configuration whose value is in
the decisions (which targets are Production, what a Development database should
alert on), not in the keystrokes. Automating a one-time wizard would take longer
than running it and would produce a script nobody runs twice.

**The file names follow section numbering; the execution order does not.** Work
through the steps below in order.

| Step | Do this | Where | Status |
|---|---|---|---|
| 1 | Deploy **one** reference agent to `oradbserv05` | [Part 1](phase-7c-part1-reference-agent.md) §§1-5 | 🟩 Confirmed |
| 2 | Cut the gold image from it | [Part 3](phase-7c-part3-golden-image.md) §§13-14 | 🟨 In progress |
| 3 | **Administration groups, monitoring templates, template collections** | [Part 2](phase-7c-part2-admin-groups.md) §§6-11 | 🟨 Not yet run |
| 4 | Provision `oradbserv04`, `06`, `09`, `10` from the image | [Part 3](phase-7c-part3-golden-image.md) §15.1-15.4 | 🟨 Not yet run |
| 5 | Discover and promote targets on all five hosts | [Discovery procedure](oem-discover-and-promote-targets.md) | 🟨 Not yet run |
| 6 | Subscribe the estate to the image, verify | [Part 3](phase-7c-part3-golden-image.md) §§16-17 | 🟨 Not yet run |
| 7 | Metric Extensions for APEX, ORDS, MongoDB | [Part 4](phase-7c-part4-metric-extensions.md) §§18-24 | 🟨 Not yet run |

---

## Why this order

### One agent by hand, four from the image

**Only `oradbserv05` is installed with the wizard.** `oradbserv04`, `06`, `09` and
`10` are *provisioned from a gold image* cut off that first agent, in Part 3 §15.

A gold agent image does two jobs, and the ordering decides how many of them you
get:

| Job | What it means |
|---|---|
| **Provisioning** | Deploy a new agent to a bare host from the image — version, patches and plug-ins already baked in |
| **Lifecycle** | Existing agents subscribe; a new image version is staged and pushed to all of them in one operation, with drift reported |

Install all five from the installer and only then build an image, and you get the
second job alone, having done the install work five times. One install, one
image, four clones gets both.

**The image is a software baseline, not a copy of `oradbserv05`.** It carries the
agent version, its patches and its plug-ins — not that host's targets, its
`emd.properties`, or anything else specific to the machine.

**The image is cut before any discovery has run**, which is what keeps it a plain
13.5 agent. **Target discovery is per-host** and runs on each host after its own
agent exists — all five together in
[Part 2 §12](phase-7c-part2-admin-groups.md#12-discover-and-promote-targets--all-five-hosts).
Each then acquires the plug-ins its own targets need, so there is nothing to be
gained by letting the reference host decide for everyone.

### Groups before discovery, not after

**This is the point of administration groups.** Oracle's Monitoring Guide:
*"Template collections contain the monitoring settings ... meant to be applied to
targets **as they join** the administration group. ... Once added to the
administration group, Enterprise Manager **automatically applies** the requisite
monitoring settings."*

So a target promoted after step 3 lands in its group and gets its thresholds in
the same motion. Promote first and group afterwards, and you need an explicit
apply pass over existing targets — a second operation, which also overwrites any
per-target tuning done in between.

**One constraint.** Monitoring templates are per target type, and building one
"From Target" needs an instance of that type to exist. `oemcdb` and the monitored
hosts cover **Host** and **Database Instance** today; **Cluster Database, Cluster
and Cluster ASM do not exist until step 5**. Build the collection with what you
have, then add cluster templates to it afterwards and re-apply. The hierarchy and
the Lifecycle Status assignment — the parts that drive auto-join — have no such
dependency.

### The rest of the ordering

1. **The image before the groups (step 2 before 3)** only because the image should
   be cut from a clean agent, and nothing in step 3 touches the agent. Either way
   round works; this way the image is already available when step 4 arrives.
2. **Existing targets still need Lifecycle Status set by hand** (Part 2 §7).
   `oemserver01`, `oradbserv01`, `orappsserv01` and `oradbserv05` were promoted
   before the hierarchy existed, so they join only once the property is on them.
   Auto-join covers targets promoted *after* step 3, which is everything from
   step 5.
3. **Metric Extensions last.** They are deployed to targets and, for the ones that
   should apply estate-wide, added to a template collection — both of which need
   the rest finished.

---

## The estate after this phase

| Host | Runs | Lifecycle Status | Agent today |
|---|---|---|---|
| `oemserver01.usat.com` | OMS 13.5, `oemcdb` repository database | **Production** | ✅ already monitored |
| `oradbserv05.usat.com` | RAC node 1, `usatclust1`, `apexdb` | **Production** | 🟩 **Part 1 — the reference agent, installed by hand** |
| `oradbserv06.usat.com` | RAC node 2, `usatclust1`, `apexdb` | **Production** | ⬜ Part 3 §15 — from the image |
| `oradbserv09.usat.com` | RAC node 1, `usatclust2`, `apexdb_stby` | **Test** | ⬜ Part 3 §15 — from the image |
| `oradbserv10.usat.com` | RAC node 2, `usatclust2`, `apexdb_stby` | **Test** | ⬜ Part 3 §15 — from the image |
| `oradbserv04.usat.com` | NestWise app tier — ORDS 26.x, MongoDB 6.0, Node proxy | **Development** | ⬜ Part 3 §15 — from the image |
| `oradbserv01.usat.com` | legacy single-instance database | **Development** | ✅ already monitored |
| `orappsserv01.usat.com` | EBS application server | **Development** | ✅ already monitored |

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
after the patch. Every host added here will raise that materially — a RAC node
alone brings the host, the cluster, ASM, the listener, the database instance and
the cluster database. Record the new baseline at the end of Part 1 and use *that*
number in the next patch window, not 43.

---

## What this phase deliberately does not do

- **No Ansible.** See the note at the top. If a future phase needs agents
  deployed repeatedly — a fleet rebuild, say — that is the point at which
  `agentDeploy.sh` becomes worth wrapping in a role, not now.
- **No credentials in this repository.** Named Credentials are created in the
  console and referenced by name. The MongoDB Metric Extension in Part 4 needs a
  Mongo login and the `NESTWISE_ADMIN_TOKEN` stays in
  `/etc/nestwise-proxy.env` (mode 640, `root:nestwise`) where the app already
  keeps it. Neither value is written down here.
- **No incident rules or notification methods.** Administration groups and
  template collections decide *what is measured and at what threshold*. Deciding
  *who gets told* is a separate piece of work — worth its own phase once these
  groups exist, because incident rule sets bind to administration groups and are
  much easier to write against a populated hierarchy.
- **No 24ai-specific features.** This is all EM 13.5 functionality. Fleet
  Maintenance, which is the 24ai-only out-of-place patching mechanism, belongs to
  Phase 7b and after.

---

## Screenshots

Screenshots referenced across all four parts go in
[`screenshots/`](screenshots/) as they are captured — same naming convention as
[`../installation/README.md`](../installation/README.md#15-screenshot-checklist-and-naming-convention)'s
Section 15, numbered `7c-NN[a-z]-slug.png` to match each part's own section
numbers. The `7c-` prefix keeps them distinct from Phase 7a's `03a-`/`16b-`
series in the same directory.

The full checklist is in
[Part 4 §24](phase-7c-part4-metric-extensions.md#24-screenshot-checklist-and-naming-convention).

---

## Related pages

Two standing procedures this phase leans on, each written once and referenced
from wherever it is needed rather than duplicated:

- **[Discovering and Promoting Targets in Enterprise Manager 13.5](oem-discover-and-promote-targets.md)**
  — run once per host, after its agent is uploading. Used by Part 2 §12 for all
  five hosts, and by any host onboarded after this phase.
- **[Creating a Blackout in Enterprise Manager 13.5](oem-create-blackout.md)** —
  needed before any agent restart that would otherwise raise incidents. Part 3's
  golden-image rollout restarts every subscribed agent.
- **[Phase 7a — Patching the OEM repository database](phase-7a-repository-db-ru32.md)**
  — the prerequisite for Phase 7b, already complete.
- **[`../nestwise-app/docs/architecture.md`](../nestwise-app/docs/architecture.md)**
  — the application Part 4 monitors: which data lives in Oracle, which lives in
  MongoDB, and how APEX reaches each tier.

---

## What this feeds into

- **Phase 7b** — OMS 13.5 → 24ai. Doing 7c first means the upgrade is validated
  against a realistic estate rather than three hosts, and gives a real
  before/after target count.
- **Incident rules and notifications** — much simpler to author once
  administration groups exist, because rule sets target groups rather than
  individual targets.
- **Phase 7d** — non-CDB to CDB conversion of `oemcdb`.

## Open questions

- **Does `oradbserv05` already have an agent?** Part 1 §1 checks rather than
  assumes. If it does, it becomes the reference agent for the golden image in
  Part 3 and the deploy list drops to four hosts.
- **Which agent version is the reference?** The golden image is only as good as
  the agent it is built from. If `oemserver01`'s agent has drifted (one-off
  patches, custom plug-ins), the image inherits that. Decide the reference host
  in Part 3 §13 deliberately.
- **Is `apexdb` 12cR2 or 19c?** `nestwise-app/docs/architecture.md` describes the
  cluster as 12cR2; `../maintenance/` documents a `DBMS_ROLLING` upgrade to 19c
  against it. Target discovery in Part 1 will report the truth — record it and fix
  whichever document is stale.
- **Is there an ORDS or MongoDB plug-in for EM 13.5 worth using instead of
  Metric Extensions?** Part 4 assumes not and builds MEs. Worth a check against
  the Self Update console and current Oracle documentation before writing them —
  a supported plug-in beats a hand-rolled ME if one exists.
