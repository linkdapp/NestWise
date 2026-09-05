# Phase 7c — Part 2: Administration Groups and Template Collections

**SOP: set Lifecycle Status on every target, build a Production / Test / Development hierarchy, and let OEM apply the right monitoring template automatically**

**Step 3 of 7 in execution order** — after the gold image is cut
([Part 3 §§13-14](phase-7c-part3-golden-image.md)) and **before** the four
remaining hosts are provisioned and discovered.

**Do this before discovery, not after.** Oracle's Monitoring Guide: template
collections hold settings *"meant to be applied to targets **as they join** the
administration group"*, and *"once added ... Enterprise Manager **automatically
applies** the requisite monitoring settings."* Build the hierarchy first and every
target promoted from §12 onward configures itself on arrival. Build it afterwards
and you need a separate apply pass, which also overwrites any per-target tuning
done in the meantime.

> **One constraint on §9.** Monitoring templates are per target type and
> "From Target" needs an instance of that type. `oemcdb` and the monitored hosts
> cover **Host** and **Database Instance** now; **Cluster Database, Cluster and
> Cluster ASM do not exist until discovery runs**. Build the collection with what
> you have and add cluster templates in §12.1 — §8's hierarchy and §7's Lifecycle
> Status, the parts that drive auto-join, have no such dependency.

Status: 🟨 Not yet run.

| # | Section | Status |
|---|---|---|
| 6 | The one thing to understand first | 🟨 |
| 7 | Set Lifecycle Status on every target | 🟨 |
| 8 | Create the administration group hierarchy | 🟨 |
| 9 | Build the monitoring templates | 🟨 |
| 10 | Create and associate template collections | 🟨 |
| 11 | Verify the templates actually applied | 🟨 |
| 12 | Discover and promote targets — all five hosts | 🟨 |

Screenshots go in [`screenshots/`](screenshots/) as `7c-NN[a-z]-slug.png`,
numbered to this page's own section numbers (6-12).

---

## Contents

6. [The one thing to understand first](#6-the-one-thing-to-understand-first)
7. [Set Lifecycle Status on every target](#7-set-lifecycle-status-on-every-target)
8. [Create the administration group hierarchy](#8-create-the-administration-group-hierarchy)
9. [Build the monitoring templates](#9-build-the-monitoring-templates)
10. [Create and associate template collections](#10-create-and-associate-template-collections)
11. [Verify the templates actually applied](#11-verify-the-templates-actually-applied)
12. [Discover and promote targets — all five hosts](#12-discover-and-promote-targets--all-five-hosts)

---

## 6. The one thing to understand first

**You do not put targets into an administration group. You give targets a
property, and OEM puts them in.**

That single fact is what separates administration groups from ordinary groups,
and getting it backwards is why people conclude the feature is broken:

| | Ordinary group | Administration group |
|---|---|---|
| Membership | you add targets by hand | **derived** from target properties |
| A new target appears | you remember to add it, or you don't | joins automatically if its properties match |
| Purpose | viewing and reporting | applying monitoring settings at scale |
| How many | as many as you like | **exactly one hierarchy per OMS** |

Two consequences worth internalising before touching the console:

**There is only one administration group hierarchy.** It is a single tree for the
whole Enterprise Manager installation. This is not a limitation to work around —
it is why the design decision in §8 matters more than the clicking does.

**A target with no Lifecycle Status joins nothing.** It is not an error, it
raises no warning, and the target simply keeps whatever monitoring it was
promoted with. §7 comes before §8 for exactly this reason: build the hierarchy
first and it will be empty, which looks like a broken feature rather than a
missing property.

---

## 7. Set Lifecycle Status on every target

**Where:** `https://oemserver01.usat.com:7803/em`

### 7.1 The assignment

| Lifecycle Status | Hosts | Rationale |
|---|---|---|
| **Production** | `oemserver01`, `oradbserv05`, `oradbserv06` | The OMS and its repository, plus the primary RAC serving `apexdb` |
| **Test** | `oradbserv09`, `oradbserv10` | The standby cluster `usatclust2` |
| **Development** | `oradbserv01`, `orappsserv01`, `oradbserv04` | Legacy single-instance DB, EBS app server, and the NestWise app tier |

**Only four of these targets exist right now** — `oemserver01`, `oradbserv01`,
`orappsserv01` and `oradbserv05`. Set the property on those now; the rest get it
as they are promoted in §12, and join their group automatically at that moment.

**Set it on every target, not just the hosts.** A database instance, a cluster, a
listener and an ASM instance each carry their own Lifecycle Status, and each is
matched independently. A host in Production whose database has no status leaves
that database ungoverned — and the database is the target whose thresholds you
actually care about.

> **Set Lifecycle Status during promotion where the wizard allows it.** That is
> what makes auto-join happen on arrival rather than as a follow-up chore.

> **Why the standby is Test and not Production.** It is a defensible call rather
> than an obvious one: the standby protects a production database, so an argument
> exists for Production. It is set to Test here because the tiering is being used
> to drive *alerting thresholds*, and this lab's standby is where switchover
> testing happens — a cluster that gets deliberately failed over should not page
> like a production service. Record the reasoning; a future reader will otherwise
> assume it was an oversight.

### 7.2 In bulk, from the console

**Targets → All Targets**, multi-select the targets for one tier, then
right-click → **Target Setup → Properties**, and set **Lifecycle Status**.

📸 *Screenshot: `7c-07a-all-targets-multiselect-properties.png` — selecting the Production targets to edit their properties together.*

📸 *Screenshot: `7c-07b-lifecycle-status-set.png` — the Lifecycle Status property being set.*

### 7.3 Read it back

Do this for at least one target per tier. **A property that did not take looks
exactly like a property that was never set.**

Open the target's **Target Setup → Properties** page again and confirm the value
is there.

📸 *Screenshot: `7c-07c-property-readback.png` — the property confirmed on the target.*

`emcli` equivalent: [Appendix B.1](#b1-set-and-read-lifecycle-status-7).

---

## 8. Create the administration group hierarchy

**Setup → Add Target → Administration Groups**

### 8.1 Define the hierarchy levels

Single level, on **Lifecycle Status**, with three of the five values used:

```
Administration Group Hierarchy
└── Lifecycle Status
    ├── Production      → oemserver01, oradbserv05/06 and their targets
    ├── Test            → oradbserv09/10 and their targets
    └── Development     → oradbserv01, orappsserv01, oradbserv04 and their targets
```

📸 *Screenshot: `7c-08a-hierarchy-levels.png` — the Hierarchy Levels tab with Lifecycle Status selected.*

> **A second level is available and deliberately not used yet.** Membership can be
> driven by any of: Contact, Cost Center, Customer Support Identifier, Department,
> **Lifecycle Status**, Line of Business, Location, Target Version, Target Type.
> The obvious second axis here would be Department — separating the database
> estate from the application estate. Left flat because a second level multiplies
> the template collections to maintain, and this estate has eight hosts. Add it
> when there is a reason, not because the feature exists.

### 8.2 Create the groups

The wizard generates the group nodes from the levels defined. Review the tree,
then **Create**.

📸 *Screenshot: `7c-08b-hierarchy-created.png` — the three-node hierarchy after creation.*

### 8.3 Confirm membership populated

Open each group. Members should already be there, derived from §7.

**An empty group means §7 did not take** — go back and read the property values
back rather than re-clicking the hierarchy wizard.

📸 *Screenshot: `7c-08c-production-group-members.png` — the Production group showing its derived members.*

---

## 9. Build the monitoring templates

A monitoring template is a saved set of metric thresholds and collection
schedules for **one target type**. Three tiers × the target types that matter
means several templates; build only the ones that will actually differ.

**Enterprise → Monitoring → Monitoring Templates → Create**

### 9.1 Which templates to build

| Template | Target type | Applies to |
|---|---|---|
| `TPL_DB_PROD` | Database Instance / Cluster Database | Production |
| `TPL_DB_TEST` | Database Instance / Cluster Database | Test |
| `TPL_DB_DEV` | Database Instance / Cluster Database | Development |
| `TPL_HOST_PROD` | Host | Production |
| `TPL_HOST_NONPROD` | Host | Test **and** Development |

Five, not nine. Host thresholds genuinely do not need to differ between Test and
Development in this estate, and a template that exists only for symmetry is a
template that drifts.

### 9.2 Build from a known-good target, not from scratch

**Create → From Target** rather than **From Scratch**. Pick a target already
monitored the way you want, and the template starts as its full current
configuration, which is far more complete than anything assembled by hand. Then
edit the handful of thresholds that should differ.

`oemcdb` on `oemserver01` is the sensible seed for `TPL_DB_PROD` — it is the
repository database, it has been running under this OMS since the start, and
Phase 7a confirmed it healthy.

### 9.3 The thresholds that carry the tiering

The point of three database templates is that they differ. Suggested starting
points — **tune against real observed behaviour, do not ship these as gospel**:

| Metric | Prod warning / critical | Test | Dev |
|---|---|---|---|
| Tablespace Space Used (%) | 85 / 95 | 90 / 97 | disabled |
| Archive Area Used (%) | 80 / 90 | 85 / 95 | 90 / 98 |
| Database Instance status | critical | critical | warning |
| Session Limit (%) | 80 / 90 | 90 / 95 | disabled |
| Average File Read Time | enabled | disabled | disabled |
| Failed Login Count | enabled | enabled | disabled |

**Disabled matters as much as the numbers.** A Development database that pages
on tablespace usage is how people learn to ignore Enterprise Manager. The tiering
is worth doing precisely because it lets you be strict where it counts and quiet
where it does not.

📸 *Screenshot: `7c-09a-template-create-metric-thresholds.png` — editing thresholds in `TPL_DB_PROD`.*

📸 *Screenshot: `7c-09b-monitoring-templates-list.png` — the five templates created.*

---

## 10. Create and associate template collections

A **template collection** bundles templates so they can be attached to an
administration group node. This is the step that makes the whole exercise
automatic.

**Setup → Add Target → Administration Groups → Template Collections tab**

### 10.1 Create one collection per tier

| Collection | Contains |
|---|---|
| `TC_PRODUCTION` | `TPL_DB_PROD`, `TPL_HOST_PROD` |
| `TC_TEST` | `TPL_DB_TEST`, `TPL_HOST_NONPROD` |
| `TC_DEVELOPMENT` | `TPL_DB_DEV`, `TPL_HOST_NONPROD` |

📸 *Screenshot: `7c-10a-template-collection-members.png` — `TC_PRODUCTION` with its two templates.*

### 10.2 Associate each collection with its group node

Back on the **Associations** tab, attach `TC_PRODUCTION` to the Production node,
and so on.

📸 *Screenshot: `7c-10b-associations.png` — the three collections attached to their hierarchy nodes.*

### 10.3 Apply

Associating does not apply. Use **Apply** — either on demand, or scheduled.

Two settings on the apply operation are worth a deliberate choice:

| Setting | Recommendation |
|---|---|
| **Apply to all targets** vs **only new targets** | First run: all. Afterwards: new only, so a hand-tuned threshold on one target is not silently reverted every cycle. |
| Schedule | Once, then on demand. A recurring apply is a recurring surprise. |

> **This overwrites per-target thresholds.** Anything tuned by hand on a target
> that falls inside an associated group will be replaced by the template's value.
> That is the entire point, and it is also the reason to run the first apply
> knowing it, rather than discovering it when a carefully raised threshold
> reverts overnight.

📸 *Screenshot: `7c-10c-apply-in-progress.png` — the apply operation running.*

---

## 11. Verify the templates actually applied

**Association alone proves nothing.** Same discipline as Phase 7a: check the end
state, not the operation's own success message.

### 11.1 Check the apply result

**Administration Groups → Associations → Apply Status**

📸 *Screenshot: `7c-11a-apply-status.png` — the apply status showing per-target results.*

### 11.2 Check a real threshold on a real target

The one that matters. Open a Production database → **Monitoring → Metric and
Collection Settings**, and confirm a threshold you set in `TPL_DB_PROD` — say
Tablespace Space Used at 85/95 — is what the target now carries.

Then open a Development database and confirm it carries the *different* value, or
is disabled. **Two targets, two tiers, two different answers** is the proof the
hierarchy is doing its job. One target proves only that a template was applied
somewhere.

📸 *Screenshot: `7c-11b-prod-threshold-applied.png` — a Production database showing the template's threshold.*

📸 *Screenshot: `7c-11c-dev-threshold-differs.png` — the same metric on a Development database, showing the different setting.*

### 11.3 Test that membership is really automatic

The claim in §6 is that a new target joins on its own. Test it rather than
believing it:

1. Pick any target still without a Lifecycle Status — or temporarily clear one.
2. Set its Lifecycle Status to `Development`.
3. Confirm it appears in the Development group without any further action.
4. Confirm the Development template's thresholds arrive on it at the next apply.

This is worth doing once, deliberately, because it is the difference between
understanding the feature and having clicked through it.

📸 *Screenshot: `7c-11d-automatic-membership.png` — a target joining its group purely from the property change.*

### 11.4 Verification checklist

| # | Check | Expected |
|---|---|---|
| 1 | Every existing target has a Lifecycle Status | no target in All Targets with the property blank |
| 2 | Hierarchy exists with three nodes | Production / Test / Development |
| 3 | Each node has members | non-zero, and matching §7's assignment |
| 4 | Five templates exist | §9.1 |
| 5 | Three collections exist and are associated | §10 |
| 6 | Apply completed with no per-target errors | §11.1 |
| 7 | A Production threshold matches its template | §11.2 |
| 8 | The same metric differs on Development | §11.2 |
| 9 | A property change moves a target between groups | §11.3 |
| 10 | Target count unchanged | grouping adds no targets — a changed count means something else happened |

---

## 12. Discover and promote targets — all five hosts

**Last, because the groups now exist to receive the targets.** Each one joins its
administration group and receives its monitoring settings **as it is promoted**,
rather than needing a separate apply pass afterwards.

### ➜ [Discovering and Promoting Targets in Enterprise Manager 13.5](oem-discover-and-promote-targets.md)

Run it once per host. Set **Lifecycle Status** during promotion where the wizard
allows it — that property is what triggers the join.

| Host | What to expect |
|---|---|
| `oradbserv05` | Node 1 of `usatclust1` — deferred from Part 1 so the gold image was cut from an agent that had discovered nothing |
| `oradbserv06` | Node 2 of `usatclust1`. Its host, listener, ASM instance and `apexdb2` instance join the existing `apexdb` cluster database |
| `oradbserv09`, `oradbserv10` | `usatclust2` and `apexdb_stby`. Then configure the Data Guard association from the **primary** database's page — the procedure's §6 |
| `oradbserv04` | Host only, and that is expected. Part 4 monitors what actually runs on it |

📸 *Screenshot: `7c-12a-full-estate-targets.png` — all eight hosts present with their targets promoted.*

### 12.1 Add the cluster templates now that those types exist

`Cluster Database`, `Cluster` and `Cluster ASM` did not exist when §9 built the
templates. They do now. Create templates for them, add them to the relevant
collections from §10, and re-apply.

📸 *Screenshot: `7c-12b-cluster-templates-added.png` — the cluster templates added to their collections.*

### 12.2 Record the estate target count

**Setup → Manage Cloud Control → Health Overview**, or **Targets → All Targets**
and read the total.

**This replaces Phase 7a's 43** in every future patch window's verification
checklist. Write it into the
[index's estate table](phase-7c-extending-coverage.md).

📸 *Screenshot: `7c-12c-target-count.png` — the estate target count after discovery.*

---

## Appendix B — `emcli` alternatives

**Optional.** The console is the primary route for everything above. All commands
assume:

```bash
. ~/.env/oms_env
emcli login -username=sysman
emcli sync
```

### B.1 Set and read Lifecycle Status (§7)

```bash
emcli set_target_property_value \
  -property_records="oradbserv05.usat.com:host:LifeCycle Status:Production"

emcli set_target_property_value \
  -property_records="apexdb:rac_database:LifeCycle Status:Production"

emcli get_target_property_value \
  -target_names="oradbserv05.usat.com" -target_types="host" \
  -property_names="LifeCycle Status"
```

`-property_records` takes `target_name:target_type:property_name:value` and
accepts a semicolon-separated list, or `-input_file` for a longer set. The
property is named `LifeCycle Status` — **note the capital C**, which is not what
the UI label suggests.

> **Verify the exact property name against your own OMS before scripting a long
> list.** Run `emcli list_target_property_names`, or set one target from the UI
> and read it back. A typo here silently sets nothing.

### B.2 Groups, collections and target count (§8, §10, §12)

```bash
emcli get_admin_group_hierarchy
emcli list_template_collections
emcli get_targets | wc -l
```

---

## Related pages

- [Discovering and Promoting Targets](oem-discover-and-promote-targets.md) — the
  standing procedure §12 runs, once per host
- [Creating a Blackout](oem-create-blackout.md) — needed before agent restarts in
  Part 3 §16

**Sources:** [Administration Groups and Template Collections (13.5)](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/13.5/emmon/administration-groups-and-template-collections.html) ·
[Defining Template Collections](https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/24.1/emmon/defining-template-collections.html) ·
[Using Monitoring Templates](https://docs.oracle.com/cd/E63000_01/EMADM/mon_temp.htm)

---

Back to **[Part 3 — Agent golden image](phase-7c-part3-golden-image.md)**.
Continue to **[Part 4 — Metric Extensions](phase-7c-part4-metric-extensions.md)**.
Back to the **[index](phase-7c-extending-coverage.md)**.
