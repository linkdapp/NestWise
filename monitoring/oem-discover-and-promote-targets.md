# Discovering and Promoting Targets in Enterprise Manager 13.5

**SOP: turn a host that has an agent into a host whose databases, clusters, ASM and listeners are monitored**

Status: 🟩 Confirmed 2026-09-06. Run five times during
[Phase 7b](phase-7b-extending-coverage.md).

**Standing procedure, run once per host.** Run it after the administration groups
exist, so each target joins its group and receives its monitoring settings as it
is promoted.

An agent on a host gives you the host and nothing else. Everything running on it
has to be discovered and then promoted separately. Auto discovery produces a list
of candidates. Until each is promoted it is not monitored, does not appear in the
target count, and raises no incidents.

[Appendix A](#appendix-a-notes) holds the reasoning behind the steps.

---

## Contents

1. [Before you start](#1-before-you-start)
2. [Run automatic discovery](#2-run-automatic-discovery)
3. [Read the results before promoting](#3-read-the-results-before-promoting)
4. [Promote, and supply monitoring credentials](#4-promote-and-supply-monitoring-credentials)
5. [Data Guard association, standby hosts only](#5-data-guard-association-standby-hosts-only)
6. [What each host type should yield](#6-what-each-host-type-should-yield)
7. [Verify](#7-verify)
8. [Screenshots to capture](#8-screenshots-to-capture)

---

## 1. Before you start

| # | Check | How |
|---|---|---|
| 1.1 | The agent is running and uploading | `emctl status agent`. Look for `Heartbeat Status : Ok`, `0` pending files, and a real `Last successful upload`, not `(none)` |
| 1.2 | `root.sh` has been run | Skipping it leaves the agent unable to run privileged collections |
| 1.3 | You know what this host runs | Discovery finds what is running at that moment. A database that is down will not be found |
| 1.4 | Monitoring credentials are ready | §4.1, for any host with a database |

A host whose agent is not uploading will still appear discoverable, because the
console works from the repository. Check 1.1 rather than assuming.

---

## 2. Run automatic discovery

**Who:** SYSMAN, or a user with Add Target privilege.
**Where:** `https://oemserver01.usat.com:7803/em`

1. **Setup → Add Target → Configure Auto Discovery**
2. Enable discovery for the host and run it.
3. **Setup → Add Target → Auto Discovery Results**

---

## 3. Read the results before promoting

**Do not promote targets belonging to a node whose agent does not exist yet.**
Discovery on one node of a cluster returns cluster-level targets belonging to
both nodes. A target promoted against an agent that does not exist collects
nothing and sits in the target count looking healthy. Promote node 2's host,
listener and instance after node 2 has its own agent.

**Promote what you intend to monitor.** Discovery also offers Oracle Homes,
individual listeners, and targets belonging to software you may not want
monitored.

---

## 4. Promote, and supply monitoring credentials

### 4.1 Prepare the database monitoring account

`dbsnmp` is the conventional monitoring account. It exists already and is normally
locked.

**Who:** `oracle`. **Where:** the database host.

```sql
ALTER USER dbsnmp ACCOUNT UNLOCK;
ALTER USER dbsnmp IDENTIFIED BY "<password>";
GRANT SELECT_CATALOG_ROLE TO dbsnmp;
```

**On a standby, run this on the primary.** A physical standby is read-only and the
change replicates. Running it against `apexdb_stby` fails.

### 4.2 Promote

1. Select the candidates and click **Promote**.
2. For each database supply **Monitoring Username** `dbsnmp`, the password set
   above, and role `Normal`.
3. Tick the option to save it as a Named Credential, `NC_DB_DBSNMP`.
4. Set Lifecycle Status and the group in the same wizard, per
   [Part 2 §10.4](phase-7b-part2-admin-groups.md#104-during-promotion).

The wizard accepts a monitoring username and password without saving them, in
which case the credential is bound to that target and cannot be referenced by name
later.

Confirm it afterwards on **Setup → Security → Named Credentials**.

---

## 5. Data Guard association, standby hosts only

Discovery finds `apexdb_stby` as a database in its own right. It does not create
the Data Guard relationship.

Configure the association from the **primary** database's target page:

**Targets → Databases → `apexdb` → Availability → Data Guard Administration**

This makes apply lag, transport lag, protection mode and Fast-Start Failover state
visible in Enterprise Manager rather than only through `dgmgrl`. The broker
configuration is in
[`../high-availability/part2-broker-fsfo-observer.md`](../high-availability/part2-broker-fsfo-observer.md).

---

## 6. What each host type should yield

### 6.1 A RAC node

From the **first** node of a cluster:

| Target type | Count | Note |
|---|---|---|
| Host | 1 | This node |
| Cluster | 1 | A cluster target, not a per-node one |
| Cluster ASM plus ASM instance | 1 plus 1 | Cluster ASM, plus this node's instance |
| Listener | 1 plus SCAN listeners | SCAN listeners are cluster-wide |
| Database Instance | 1 | For example `apexdb1` |
| Cluster Database | 1 | For example `apexdb`. Gains its second instance when node 2 is onboarded |
| Oracle Home | Several | One per home discovered |

From the **second** node: its host, its listener, its ASM instance and its database
instance, which joins the existing cluster database.

### 6.2 An application-tier host

`oradbserv04` runs ORDS, MongoDB and a Node proxy. None of the three is a target
type EM 13.5 knows about, so discovery returns the host and stops. That is
expected. [Phase 7b Part 4](phase-7b-part4-metric-extensions.md) monitors them
with Metric Extensions.

---

## 7. Verify

### 7.1 Nothing left unpromoted by accident

Return to **Auto Discovery Results**. Record anything still listed as a deliberate
decision.

### 7.2 Every promoted target is uploading

Open the host's **All Metrics** page and confirm real values with recent
timestamps.

### 7.3 The plug-ins the host now carries

**Who:** `oracle`. **Where:** the host.

```bash
export AGENT_HOME=/u01/app/oracle/Middleware/agent/13_5/agent_13.5.0.0.0
$AGENT_HOME/bin/emctl listplugins agent -type all
```

A RAC node shows the Oracle Database plug-in and the cluster ones. The app tier
does not. Divergence between hosts is correct, since each agent carries what its
own targets need.

### 7.4 Record the target count

```bash
. ~/.env/oms_env
emcli login -username=sysman
emcli get_targets | wc -l
```

Record it against the host just onboarded.

---

## 8. Screenshots to capture

None captured yet. One set covers the procedure. Capture each on the first host
that exercises the step rather than repeating the set per host.

| File | Shows |
|---|---|
| `discover-01-configure-auto-discovery.png` | Enabling discovery on the target host |
| `discover-02-auto-discovery-results.png` | The discovered, unpromoted candidates |
| `discover-03-promote-with-credentials.png` | Promoting a cluster database with its monitoring credential |
| `discover-04-promotion-complete.png` | The promoted targets in All Targets |
| `discover-05-data-guard-association.png` | The standby associated with its primary. Needs a standby |
| `discover-06-app-tier-host-only.png` | The app tier discovering as a host with no application targets. Needs the app tier |
| `discover-07-metrics-collecting.png` | Real metric values against a newly promoted database |
| `discover-08-agent-plugins-after.png` | The plug-ins deployed as a result of promotion |
| `discover-09-target-count.png` | The target count after this host |

Naming follows the same convention as
[`oem-create-blackout.md`](oem-create-blackout.md).

---

## Appendix A: Notes

None of this is needed to run the steps.

**Discovery is per host.** It registers what that machine runs. Nothing found is
carried to another host, baked into a gold image, or inherited.

**Discovery is what causes plug-ins to be deployed.** When a target type is
discovered and promoted on an agent, the OMS deploys the plug-in that target type
needs. A host provisioned from a minimal gold image acquires what it needs here.

**A RAC node's discovery shows the whole cluster** because that is what a cluster
looks like from the inside. The results page persists, so node 2's targets can be
promoted from it later.

**The target count is a number worth being deliberate about.** Phase 7a's patch
window verified 43 targets before and 43 after as evidence nothing was lost. That
check is only as meaningful as the deliberateness of the number.

**Why ORDS does not discover.** It is deployed standalone under systemd, per
[`../nestwise-app/docs/ords-server-install.md`](../nestwise-app/docs/ords-server-install.md),
so there is no WebLogic domain to find. On WebLogic it would discover as an Oracle
WebLogic Server target with out-of-the-box metrics.

**Why the Named Credential matters.** Referencing it by name means the password
lives only in the Enterprise Manager credential store rather than in this
repository, and it can be reused rather than re-entered.

---

## Where this is used

- [Phase 7b Part 2 §12](phase-7b-part2-admin-groups.md#12-discover-and-promote-the-remaining-targets), all five hosts, after the administration groups exist
- Any host onboarded after Phase 7b
