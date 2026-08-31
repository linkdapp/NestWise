---
layout: post
title: "One minute, or never: measuring a Data Guard switchover under real load"
date: 2026-08-31
categories: [oracle, ocm, dba]
tags: [data-guard, rac, application-continuity, fsfo, swingbench, maa]
---

## The problem, in plain terms

Almost anyone can run a Data Guard switchover and screenshot the words
"Switchover succeeded." That proves the database changed roles. It says nothing
about whether the application noticed, how long it was down, or whether it
recovered by itself.

I wanted the harder version: a switchover with a real workload running through
it, and a chart showing what that workload actually experienced. The interesting
number is not what the Broker reports. It is what the client saw.

## What I built

Two separate 2-node RAC clusters on Oracle Linux 7, `usatclust1` and
`usatclust2`, with a physical standby of `apexdb` protected by Data Guard
Broker in MaxAvailability mode, Fast-Start Failover enabled with an observer.
Grid Infrastructure 19c, database 12.2.0.1 at the time of this test.

Two details matter for everything that follows. The standby lives on a
genuinely separate cluster with its own SCAN listener, not a second node under
one shared SCAN. And the database is fronted by role-based services: `apexdb_rw`
follows the primary, `apexdb_ro` follows the standby.

The load came from Swingbench 2.8.0.1630 running the `SOE_Client_Side_AC`
benchmark at 16 concurrent users. That configuration matters: it is the Order
Entry workload built to exercise Application Continuity's replay and reconnect
behaviour, rather than a generic workload with no recovery logic of its own.

The switchover itself was driven by an Ansible role rather than typed by hand,
so the test is repeatable and direction-agnostic:

```bash
ansible-playbook -i inventory/hosts.ini site.yml \
  --tags dataguard_switchover_test -e sys_password='...'
```

It detects the current direction on every run:

```
Currently PRIMARY: apexdb_stby. Currently STANDBY: apexdb. This run will
SWITCHOVER TO apexdb — it becomes the new PRIMARY, apexdb_stby becomes the
new STANDBY.
```

## The three things this demonstrates

**1. Broker-managed switchover, verified independently of the Broker.**

DGMGRL reported success, and then immediately contradicted itself:

```
Switchover succeeded, new primary is "apexdb"

Configuration - apexdb_dg
  apexdb      - Primary database
    Error: ORA-16825: multiple errors or warnings ...
    apexdb_stby - (*) Physical standby database
      Error: ORA-12514: TNS:listener does not currently know of service ...
Configuration Status:
ERROR   (status updated 61 seconds ago)
```

Those errors are transient. Clusterware is still restarting the demoted primary
into its new standby role. The lesson is not to trust that message either way,
so the role verifies with real SQL instead:

```
apexdb: PRIMARY|READ WRITE
apexdb_stby: PHYSICAL STANDBY|READ ONLY
```

**2. Role-based services relocating on their own.**

This is the piece that makes the application's recovery possible at all.
Verified with `srvctl status service` on both clusters rather than assumed:

```
apexdb      / apexdb_rw: running on instance(s) apexdb1,apexdb2
apexdb      / apexdb_ro: not running
apexdb_stby / apexdb_rw: not running
apexdb_stby / apexdb_ro: running on instance(s) apexdb1,apexdb2
```

The read-write service moved to the new primary and the read-only service to the
new standby, with nothing manual in between.

**3. The application recovering itself, on a chart.**

Switchover was triggered at roughly 14:57. TPS, DML operations, and the
five-second moving response time all dipped hard within the next minute:
throughput to near zero, response time spiking. By about 14:59 all three were
back at baseline, with no manual reconnect and no client restart. Logged-on
users never dropped from 16 throughout.

That chart is the artifact. A log line saying the switchover worked is a claim.
A throughput graph dipping and climbing back on its own is evidence.

## What went wrong

The first attempt did not recover at all. Not slowly: never.

The client connected through a connect string pointing at one cluster's SCAN,
`//scan-usatclust1.usat.com:1521/apexdb_rw`. That was fine for the baseline. The
moment the switchover moved `apexdb_rw` onto `usatclust2`, every reconnect
attempt kept returning to `usatclust1`'s listener, which no longer had the
service registered. The result was an endless `SQLRecoverableException` loop
with no natural recovery, however long it ran.

It would have been easy, and wrong, to write that up as an Application
Continuity failure. It was not. It was a client pointed at the wrong cluster.
This topology spans two genuinely separate clusters, and a great many Data Guard
examples assume a single shared SCAN where this problem cannot arise.

The fix is one connect descriptor listing both clusters:

```
apexdb_rw =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = scan-usatclust1.usat.com)(PORT = 1521))
    (ADDRESS = (PROTOCOL = TCP)(HOST = scan-usatclust2.usat.com)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = apexdb_rw)
    )
  )
```

Worth being precise about what that bought. It did not reduce the RTO. It
changed the RTO from about a minute to never. That distinction is the whole
value of testing under load rather than testing idle.

## Stating the result in RPO and RTO terms

**RPO is zero**, and this test did not have to prove it. MaxAvailability with
`LogXptMode=SYNC` means the standby cannot fall behind by design, and DGMGRL
will not begin a switchover unless the standby is fully caught up. The
configuration already reported "Enabled in Zero Data Loss Mode." No committed
transaction was lost. This test only had to avoid contradicting that.

**RTO is roughly one minute**, and that is the number this test actually
measured. Not DGMGRL's own timestamp: the client-observed recovery time from the
Swingbench chart, from trigger to full self-recovery.

Two limits on that claim, stated because they matter:

This was a **planned switchover**, not an unplanned failover. Failover is
governed by a different mechanism, `FastStartFailoverThreshold`, currently at
Oracle's default of 30 seconds, and has not yet been measured under load.

So "the application barely noticed" is honest as *recovered on its own within
about a minute, under a real planned switchover*. It is not honest as "didn't
notice at all," and not yet a claim about an actual outage.

## Why this matters for an OCM-level DBA

Data Guard sits squarely in the OCM blueprint's backup, recovery and
high-availability territory, and this is a textbook Maximum Availability
Architecture build: RAC underneath, Data Guard across it, role-based services
on top, Application Continuity at the client. Naming it as MAA rather than
presenting it as a bespoke design is worth doing, because it is the reference
architecture Oracle publishes for exactly this problem.

But the part a hiring manager should care about is smaller and more specific.
Anyone can produce a screenshot of a successful switchover. Far fewer can say
what their RTO is, distinguish it from RPO, explain which one the test actually
measured, and name the client-side configuration that stood between a
one-minute recovery and an outage that never ended.

There is also a monitoring lesson buried in it. The health-check script used
here detects its own role and skips standby-only checks like MRP status when run
against a primary. The same script therefore runs unmodified on either side of a
switchover. A script that assumes a fixed role breaks the moment the roles
change, which is precisely when you need it.

## What's next

The unplanned failover under load, governed by `FastStartFailoverThreshold`
rather than a graceful role transition. That is the test that turns "bounded and
self-healing" into a claim about a real outage.
