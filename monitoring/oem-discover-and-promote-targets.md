# Discovering and Promoting Targets in Enterprise Manager 13.5

**SOP: turn a host that has an agent into a host whose databases, clusters, ASM and listeners are actually monitored**

Status: 🟨 Not yet run. Statuses, real console output and screenshots get filled
in as it is actually executed.

**This is a standing procedure, run once per host.** It is written as its own page
because it happens more than once: five times in
[Phase 7c Part 2 §12](phase-7c-part2-admin-groups.md#12-discover-and-promote-targets--all-five-hosts),
and again for any host onboarded afterwards.

> **Run it after the administration groups exist**, not before. Each target then
> joins its group and receives its monitoring settings as it is promoted, rather
> than needing a separate apply pass.

Screenshots are in [`screenshots/`](screenshots/) as `discover-NN-slug.png` —
same convention as [`oem-create-blackout.md`](oem-create-blackout.md).

---

## Contents

1. [What discovery does, and what it does not](#1-what-discovery-does-and-what-it-does-not)
2. [Before you start](#2-before-you-start)
3. [Run automatic discovery](#3-run-automatic-discovery)
4. [Read the results before promoting anything](#4-read-the-results-before-promoting-anything)
5. [Promote, and supply monitoring credentials](#5-promote-and-supply-monitoring-credentials)
6. [Data Guard association — standby hosts only](#6-data-guard-association--standby-hosts-only)
7. [What each host type should yield](#7-what-each-host-type-should-yield)
8. [Verify](#8-verify)
9. [Screenshot checklist](#9-screenshot-checklist)

---

## 1. What discovery does, and what it does not

**An agent on a host gives you the host, and nothing else.** Everything running on
it — the database, the cluster, ASM, the listener — has to be found and then
promoted separately. This is the step most often left half done, and a half-done
promotion looks identical to a quiet, healthy system.

Three things worth being clear about before starting:

**Discovery is per-host.** It runs against a host whose agent is already uploading,
and it registers what *that* machine runs. Nothing found here is carried to
another host, baked into a gold image, or inherited by anything.

**Discovery is not promotion.** Auto discovery produces a list of *candidates*.
Until each is promoted, it is not monitored, does not appear in the target count,
and raises no incidents. The list will sit there indefinitely without complaining.

**Discovery is what causes plug-ins to be deployed.** When a target type is
discovered and promoted on an agent, the OMS deploys the plug-in that target type
needs. This is why a host provisioned from a minimal gold image is not a problem —
it acquires what it needs here, on its own account.

---

## 2. Before you start

| # | Check | How |
|---|---|---|
| 2.1 | The agent is running and uploading | `emctl status agent` — `Heartbeat Status : Ok`, `0` pending files, a real `Last successful upload`, not `(none)` |
| 2.2 | `root.sh` has been run | Skipping it leaves the agent unable to run privileged collections, which surfaces later as missing metrics rather than as an error now |
| 2.3 | You know what this host runs | Discovery finds what is running *at that moment*. A database that is down will not be found |
| 2.4 | Monitoring credentials are ready | §5.1 — `dbsnmp` unlocked and granted, for any host with a database |

> **A host whose agent is not uploading will still appear discoverable.** The
> console works from the repository, so it can offer you targets on an agent that
> stopped talking an hour ago. 2.1 is not a formality.

---

## 3. Run automatic discovery

**Who:** SYSMAN, or a user with Add Target privilege
**Where:** `https://oemserver01.usat.com:7803/em`

**Setup → Add Target → Configure Auto Discovery**

Enable discovery for the host and run it. Discovery can also be scheduled; for
onboarding a known host, run it on demand so you are watching when it completes.

📸 *Screenshot: `discover-01-configure-auto-discovery.png` — enabling discovery on the target host.*

**Setup → Add Target → Auto Discovery Results**

📸 *Screenshot: `discover-02-auto-discovery-results.png` — the discovered, unpromoted candidates.*

---

## 4. Read the results before promoting anything

Two traps live in this list, and both are easier to avoid than to undo.

### 4.1 A RAC node's discovery shows you the whole cluster

Discovery on one node of a cluster sees cluster-level targets belonging to
**both** nodes, because that is what a cluster looks like from the inside.

**Do not promote targets belonging to a node whose agent does not exist yet.** A
target promoted against a non-existent agent is monitored by nothing — it will sit
in the target count looking healthy and collecting no metrics. Promote node 2's
host, listener and instance after node 2 has its own agent, from the same results
page, which will still be there.

### 4.2 Promote what you intend to monitor, not everything offered

Discovery is thorough. It will offer Oracle Homes, individual listeners, and
occasionally targets belonging to software you have no intention of monitoring.
Each promoted target is one more thing to threshold, template, and explain later.

> **The target count is a number you will be asked to justify.** Phase 7a's patch
> window verified "43 targets before, 43 after" as evidence nothing was lost.
> That check is only as meaningful as the deliberateness of the number.

---

## 5. Promote, and supply monitoring credentials

Promotion is where a discovered thing becomes a monitored target.

### 5.1 Prepare the database monitoring account

Databases need a monitoring credential. `dbsnmp` is the conventional account and
exists already; it is normally locked.

**Who:** `oracle`
**Where:** the database host

```sql
ALTER USER dbsnmp ACCOUNT UNLOCK;
ALTER USER dbsnmp IDENTIFIED BY "<password>";
GRANT SELECT_CATALOG_ROLE TO dbsnmp;
```

> **On a standby, do this on the primary.** A physical standby is read-only;
> the change replicates. Running it against `apexdb_stby` will fail, and the
> failure is easy to misread as a permissions problem.

### 5.2 Promote

Select the candidates and promote. For each database supply **Monitoring
Username** `dbsnmp`, the password set above, and role `Normal`.

**Save it as a Named Credential — `NC_DB_DBSNMP`.** Referencing it by name means
[Phase 7c Part 2](phase-7c-part2-admin-groups.md)'s template work and
[Part 4](phase-7c-part4-metric-extensions.md)'s SQL Metric Extension do not each
need the password re-entered, and the password itself lives only in the OEM
credential store — never in this repository.

📸 *Screenshot: `discover-03-promote-with-credentials.png` — promoting a cluster database with its monitoring credential.*

📸 *Screenshot: `discover-04-promotion-complete.png` — the promoted targets appearing in All Targets.*

---

## 6. Data Guard association — standby hosts only

Discovery finds `apexdb_stby` as a database in its own right. **That is correct** —
Data Guard standbys are separate targets — but it does not create the Data Guard
*relationship*.

The association is configured from the **primary** database's target page:

**Targets → Databases → `apexdb` → Availability → Data Guard Administration**

Doing this makes the broker configuration built in
[`../high-availability/part2-broker-fsfo-observer.md`](../high-availability/part2-broker-fsfo-observer.md)
visible in Enterprise Manager — apply lag, transport lag, protection mode and
Fast-Start Failover state — instead of being observable only through `dgmgrl`.

📸 *Screenshot: `discover-05-data-guard-association.png` — the standby associated with its primary.*

---

## 7. What each host type should yield

### 7.1 A RAC node

From the **first** node of a cluster:

| Target type | Count | Note |
|---|---|---|
| Host | 1 | this node |
| Cluster | 1 | a cluster target, not a per-node one |
| Cluster ASM + ASM instance | 1 + 1 | cluster ASM, plus this node's instance |
| Listener | 1 (+ SCAN listeners) | SCAN listeners are cluster-wide |
| Database Instance | 1 | e.g. `apexdb1` |
| Cluster Database | 1 | e.g. `apexdb` — gains its second instance when node 2 is onboarded |
| Oracle Home | several | one per home discovered |

From the **second** node: its host, its listener, its ASM instance and its
database instance, which joins the existing cluster database.

### 7.2 An application-tier host

`oradbserv04` runs ORDS, MongoDB and a Node proxy. **None of the three is a target
type EM 13.5 knows about**, so discovery returns the host and stops.

**That is expected, not a failure.** It is the reason
[Phase 7c Part 4](phase-7c-part4-metric-extensions.md) exists.

Had ORDS been deployed on WebLogic it would discover as an Oracle WebLogic Server
target with real out-of-the-box metrics. It is deployed **standalone** here
(`ords serve` under systemd, per
[`../nestwise-app/docs/ords-server-install.md`](../nestwise-app/docs/ords-server-install.md)),
so there is no WebLogic domain to find. A genuine trade-off rather than a gap:
standalone ORDS is simpler to run and monitored by hand; WebLogic ORDS is heavier
and monitored for free.

📸 *Screenshot: `discover-06-app-tier-host-only.png` — the app tier discovering as a host with no application targets.*

---

## 8. Verify

### 8.1 Nothing left unpromoted by accident

Go back to **Auto Discovery Results**. Anything still listed is either a
deliberate decision or an oversight, and the difference should be written down
rather than remembered.

### 8.2 Every promoted target is uploading

A promoted target that never collects is the failure this whole page exists to
prevent. Open the host's **All Metrics** page and confirm real values with recent
timestamps, not blanks.

📸 *Screenshot: `discover-07-metrics-collecting.png` — real metric values against a newly promoted database.*

### 8.3 The plug-ins the host now carries

**Who:** `oracle`
**Where:** the host

```bash
export AGENT_HOME=/u01/app/oracle/Middleware/agent/agent_13.5.0.0.0
$AGENT_HOME/bin/emctl listplugins agent
```

A RAC node should now show the Oracle Database plug-in and the Clusterware / High
Availability ones; the app tier will not, and has no reason to. **Divergence
between hosts here is correct** — each agent carries what its own targets need.
It is not drift, and it is not something a gold image should have decided in
advance.

📸 *Screenshot: `discover-08-agent-plugins-after.png` — the plug-ins deployed as a result of promotion.*

### 8.4 Record the target count

```bash
. ~/.env/oms_env
emcli login -username=sysman
emcli get_targets | wc -l
```

Record it against the host you just onboarded. When the estate is complete, the
final figure replaces Phase 7a's **43** in every future patch window's
verification checklist.

📸 *Screenshot: `discover-09-target-count.png` — the target count after this host.*

---

## 9. Screenshot checklist

```
screenshots/
├── discover-01-configure-auto-discovery.png
├── discover-02-auto-discovery-results.png
├── discover-03-promote-with-credentials.png
├── discover-04-promotion-complete.png
├── discover-05-data-guard-association.png
├── discover-06-app-tier-host-only.png
├── discover-07-metrics-collecting.png
├── discover-08-agent-plugins-after.png
└── discover-09-target-count.png
```

One set covers the procedure. Capture them on the first host that exercises each
step — `discover-05` needs a standby, `discover-06` needs the app tier — rather
than repeating the whole set per host.

---

## Where this is used

- [Phase 7c Part 2 §12](phase-7c-part2-admin-groups.md#12-discover-and-promote-targets--all-five-hosts) — all five hosts, after the administration groups exist
- Any host onboarded after Phase 7c
