# Phase 7b Part 4: Metric Extensions for APEX, ORDS and MongoDB

**SOP: monitor three things Enterprise Manager has no target type for — the APEX engine inside `apexdb`, standalone ORDS on `oradbserv04:8080`, and MongoDB 6.0 bound to `127.0.0.1:27017`**

Part 4 of 4, and last in execution order.
[Part 3 §15](phase-7b-part3-golden-image.md#15-provision-the-remaining-four-hosts-from-the-image)
put an agent on `oradbserv04`, which is what makes everything here possible —
MongoDB binds to `127.0.0.1`, so the collection has to run locally.
[Part 2](phase-7b-part2-admin-groups.md) built the Development template
collection these extensions get added to. Index:
[`phase-7b-extending-coverage.md`](phase-7b-extending-coverage.md).

Status: 🟨 Not yet run.

| # | Section | Status |
|---|---|---|
| 18 | What is being monitored, and why by hand | 🟨 |
| 19 | Credentials first | 🟨 |
| 20 | ME 1 — APEX activity, SQL against `apexdb` | 🟨 |
| 21 | ME 2 — ORDS health, OS Command on `oradbserv04` | 🟨 |
| 22 | ME 3 — the NestWise Node proxy | 🟨 |
| 23 | ME 4 — MongoDB 6.0 | 🟨 |
| 24 | Screenshot checklist and naming convention | 🟨 |

Screenshots go in [`screenshots/`](screenshots/) as `7c-NN[a-z]-slug.png`,
numbered to this page's own section numbers (18-23).

---

## Contents

18. [What is being monitored, and why by hand](#18-what-is-being-monitored-and-why-by-hand)
19. [Credentials first](#19-credentials-first)
20. [ME 1 — APEX activity, SQL against apexdb](#20-me-1--apex-activity-sql-against-apexdb)
21. [ME 2 — ORDS health, OS Command on oradbserv04](#21-me-2--ords-health-os-command-on-oradbserv04)
22. [ME 3 — the NestWise Node proxy](#22-me-3--the-nestwise-node-proxy)
23. [ME 4 — MongoDB 6.0](#23-me-4--mongodb-60)
24. [Screenshot checklist and naming convention](#24-screenshot-checklist-and-naming-convention)

Back to **[Part 3 — Agent golden image](phase-7b-part3-golden-image.md)**.
Back to the **[index](phase-7b-extending-coverage.md)**.

---

## 18. What is being monitored, and why by hand

### 18.1 The stack

From [`../nestwise-app/docs/architecture.md`](../nestwise-app/docs/architecture.md)
and the two install write-ups, everything except the database sits on one OL7
host:

| Component | Where | Detail |
|---|---|---|
| APEX engine | inside `apexdb` on the RAC | Pages render in the database; ORDS is only the web front |
| ORDS 26.x | `oradbserv04.usat.com:8080` | **Standalone** under systemd, Java 21, connects via SCAN to `apexdb_rw` |
| Node/Express proxy | `oradbserv04.usat.com:4000` | `nestwise` service account, env at `/etc/nestwise-proxy.env` |
| MongoDB 6.0 | `oradbserv04.usat.com:27017` | **`bindIp: 127.0.0.1`**, `authorization: enabled` |

### 18.2 Why Metric Extensions rather than a plug-in

EM 13.5 has no target type for standalone ORDS, for a Node process, or for
MongoDB. Two of those are worth a sentence each:

**ORDS is monitored by hand because it was deployed standalone.** Had it been
deployed on WebLogic it would discover as an Oracle WebLogic Server target with
real out-of-the-box metrics and no work here at all. Standalone was the right
call for this app — simpler to run, fewer moving parts — and this section is the
price of it. Worth stating as a trade-off rather than a gap.

**MongoDB binds to `127.0.0.1`.** That is deliberate, per the install doc: a
Mongo instance on `0.0.0.0` with weak auth is a well-documented cause of data
loss. The monitoring consequence is absolute — **nothing off the host can reach
it**, so the collection has to be an OS Command Metric Extension executed by the
local agent on `oradbserv04`. A remote SQL-style ME is not an option, and this is
the reason Part 1 deployed an agent to that host at all.

> **Check for a supported plug-in before building all four.** Look in
> **Setup → Extensibility → Self Update → Plug-ins** and against current Oracle
> documentation. A supported plug-in beats a hand-rolled Metric Extension every
> time — it is maintained, it survives upgrades, and it does not become somebody
> else's undocumented shell script. This section assumes none exists for these
> three components in 13.5; confirm that rather than inheriting the assumption.

### 18.3 The Metric Extension lifecycle

Every ME below follows the same five steps, and the middle one is the one people
skip:

```
Create (Draft) → Test against a real target → Save as Deployable Draft
              → Publish → Deploy to targets
```

**Test while it is still a Draft.** A published ME cannot be edited — it can only
be superseded by a new version. Testing costs one click and saves a version
number every time it catches something.

**Enterprise → Monitoring → Metric Extensions**

---

## 19. Credentials first

Three of the four extensions need to authenticate, and none of those credentials
belongs in this repository.

| ME | Needs | Named Credential |
|---|---|---|
| APEX activity | database login on `apexdb` | `NC_DB_DBSNMP` — created during promotion, see the [discovery procedure §5](oem-discover-and-promote-targets.md#5-promote-and-supply-monitoring-credentials) |
| ORDS health | none — unauthenticated health endpoint | — |
| Node proxy | none for the read check | — |
| MongoDB | Mongo login | `NC_MONGO_MONITOR` — create below |

### 19.1 A read-only MongoDB user

Do not monitor as `dbadmin`. Create a user with the built-in `clusterMonitor`
role, which is exactly and only what monitoring needs.

**Who:** `mongod` administrator
**Where:** `oradbserv04`

```javascript
// mongosh -u dbadmin -p --authenticationDatabase admin
use admin
db.createUser({
  user: "em_monitor",
  pwd: passwordPrompt(),
  roles: [ { role: "clusterMonitor", db: "admin" } ]
})
```

`clusterMonitor` grants `serverStatus`, `replSetGetStatus`, `dbStats` and the
other read-only diagnostics, and grants no access to application data. The
NestWise collections stay unreadable by the monitoring account.

### 19.2 Store it as a Named Credential

**Setup → Security → Named Credentials → Create**

| Field | Value |
|---|---|
| Credential Name | `NC_MONGO_MONITOR` |
| Authenticating Target Type | `Host` |
| Credential Type | `Host Credentials` |
| Username | `em_monitor` |
| Password | *(as set above)* |

> **Why a Host credential for a database login.** The ME runs as an OS Command on
> `oradbserv04`, so OEM passes the credential to a shell on that host rather than
> opening a database connection itself. The credential type has to match how it
> is used, not what it authenticates to.

📸 *Screenshot: `7c-19-named-credential-mongo.png` — `NC_MONGO_MONITOR` created and tested.*

---

## 20. ME 1 — APEX activity, SQL against `apexdb`

APEX runs inside the database, so this one is an ordinary SQL Metric Extension
against the `apexdb` target — no agent-side scripting needed.

### 20.1 Definition

| Field | Value |
|---|---|
| Target Type | `Cluster Database` (and a sibling for `Database Instance` if per-instance detail is wanted) |
| Name | `ME$APEX_ACTIVITY` |
| Display Name | `APEX Application Activity` |
| Adapter | `SQL` |
| Collection Schedule | every 15 minutes |
| Upload | every collection |

### 20.2 The query

```sql
SELECT COUNT(*)                                        AS page_views_15m,
       NVL(ROUND(AVG(elapsed_time), 3), 0)             AS avg_elapsed_sec,
       COUNT(DISTINCT apex_session_id)                 AS distinct_sessions,
       SUM(CASE WHEN page_view_type = 'Error' THEN 1
                ELSE 0 END)                            AS error_views_15m
FROM   apex_workspace_activity_log
WHERE  view_date > SYSDATE - (15/1440)
```

| Column | Type | Purpose |
|---|---|---|
| `page_views_15m` | Number, Data | Volume — is anyone using it |
| `avg_elapsed_sec` | Number, Data | The one that ties back to RAC performance work |
| `distinct_sessions` | Number, Data | Concurrency |
| `error_views_15m` | Number, **Alert** | Warning > 0, Critical > 10 |

> **`apex_workspace_activity_log` shows only what the current schema can see.**
> It is filtered by workspace security context, so a `dbsnmp` login may return
> zero rows even when APEX is busy. If it does, either grant `dbsnmp` the APEX
> administrator role, or point the ME at
> `APEX_XXXXXX.WWV_FLOW_ACTIVITY_LOG` directly with a credential that can read it.
> **Test this in §20.3 before publishing** — a metric that silently returns zero
> is worse than no metric, and it is the same silent-failure shape as the empty
> Liquid variables in `known-risks.md` #157b.

### 20.3 Test it — properly

**Actions → Test**, pick `apexdb`, **Run Test**.

Do not accept "the test succeeded". **Generate real traffic first** — open a few
NestWise pages, or run the Swingbench workload from
[`../nestwise-app/loadtest/swingbench/`](../nestwise-app/loadtest/swingbench/README-swingbench.md)
— then run the test and confirm the numbers are non-zero and plausible. A query
that returns zero rows tests as a pass.

📸 *Screenshot: `7c-20a-me-apex-sql-definition.png` — the SQL adapter and query.*

📸 *Screenshot: `7c-20b-me-apex-test-results.png` — a test run returning real, non-zero values.*

---

## 21. ME 2 — ORDS health, OS Command on `oradbserv04`

### 21.1 Definition

| Field | Value |
|---|---|
| Target Type | `Host` |
| Name | `ME$ORDS_HEALTH` |
| Display Name | `ORDS Listener Health` |
| Adapter | `OS Command — Multiple Columns` |
| Delimiter | `\|` |
| Collection Schedule | every 5 minutes |

### 21.2 The command

```bash
/bin/bash -c '
PORT=8080
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost:${PORT}/ords/ 2>/dev/null)
MS=$(curl -s -o /dev/null -w "%{time_total}" --max-time 10 http://localhost:${PORT}/ords/ 2>/dev/null)
UP=$(systemctl is-active ords >/dev/null 2>&1 && echo 1 || echo 0)
RSS=$(ps -o rss= -C java --sort=-rss 2>/dev/null | head -1 | tr -d " ")
echo "${CODE:-0}|${MS:-0}|${UP}|${RSS:-0}"
'
```

| Column | Type | Notes |
|---|---|---|
| `http_code` | Number, **Alert** | **302 is healthy.** `/ords/` redirects to `/ords/_/landing` — the ORDS install doc records exactly this. Critical when the value is `0` (nothing listening) or ≥ 500 |
| `response_ms` | Number, Data | `curl`'s `time_total`, in seconds |
| `service_up` | Number, **Alert** | Critical when 0 |
| `java_rss_kb` | Number, Data | Resident memory of the largest Java process |

> **Do not alert on "not 200".** The single most likely way to get this wrong is
> to treat 302 as a failure — which would mean a permanently critical metric
> against a perfectly healthy listener, and a week later nobody looks at ORDS
> alerts at all. Alert on `0` and on `5xx`.

> **`ps -C java` is imprecise if anything else on the host runs Java.** Today
> nothing does. If that changes, match on the ORDS process specifically rather
> than on the runtime — the same lesson as the `ps` traps in
> `known-risks.md` #151, where matching too loosely produced a confident wrong
> answer.

📸 *Screenshot: `7c-21a-me-ords-command.png` — the OS Command adapter with the script.*

📸 *Screenshot: `7c-21b-me-ords-test.png` — a test returning `302|0.0xx|1|nnnnnn`.*

---

## 22. ME 3 — the NestWise Node proxy

The proxy is the path every MongoDB-sourced APEX region goes through. If it is
down, the Neighborhood Detail page loses its listings, weather and movies while
Oracle-sourced content keeps working — a partial failure that is easy to miss.

### 22.1 Definition

| Field | Value |
|---|---|
| Target Type | `Host` |
| Name | `ME$NESTWISE_PROXY` |
| Display Name | `NestWise Node Proxy` |
| Adapter | `OS Command — Multiple Columns` |
| Delimiter | `\|` |
| Collection Schedule | every 5 minutes |

### 22.2 The command

```bash
/bin/bash -c '
PORT=4000
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost:${PORT}/api/weather/current 2>/dev/null)
MS=$(curl -s -o /dev/null -w "%{time_total}" --max-time 10 http://localhost:${PORT}/api/weather/current 2>/dev/null)
UP=$(systemctl is-active nestwise-proxy >/dev/null 2>&1 && echo 1 || echo 0)
echo "${CODE:-0}|${MS:-0}|${UP}"
'
```

`/api/weather/current` is chosen from the five read endpoints because it is the
cheapest and touches MongoDB — so a 200 here proves the whole proxy-to-Mongo path
works, not just that Node is listening.

| Column | Type | Notes |
|---|---|---|
| `http_code` | Number, **Alert** | Critical when not 200 |
| `response_ms` | Number, Data | |
| `service_up` | Number, **Alert** | Critical when 0 |

> **`POST /api/admin/reload` is never called from here.** It is the only
> write endpoint, it requires `NESTWISE_ADMIN_TOKEN`, and a monitoring check has
> no business mutating application state. The token stays in
> `/etc/nestwise-proxy.env` (mode 640, `root:nestwise`) and is not referenced by
> any Metric Extension.

📸 *Screenshot: `7c-22-me-proxy-test.png` — a test returning `200|0.0xx|1`.*

---

## 23. ME 4 — MongoDB 6.0

### 23.1 Definition

| Field | Value |
|---|---|
| Target Type | `Host` |
| Name | `ME$MONGODB_STATUS` |
| Display Name | `MongoDB Server Status` |
| Adapter | `OS Command — Multiple Columns` |
| Delimiter | `\|` |
| Collection Schedule | every 5 minutes |
| Credentials | `NC_MONGO_MONITOR` |

### 23.2 The command

```bash
/bin/bash -c '
UP=$(systemctl is-active mongod >/dev/null 2>&1 && echo 1 || echo 0)
if [ "$UP" -eq 0 ]; then echo "0|0|0|0|0"; exit 0; fi
OUT=$(mongosh --quiet \
  -u "%emUser%" -p "%emPassword%" --authenticationDatabase admin \
  --host 127.0.0.1 --port 27017 \
  --eval "
    var s = db.serverStatus();
    print([ s.connections.current,
            s.connections.available,
            s.opcounters.query,
            Math.round(s.uptime) ].join(\"|\"));
  " 2>/dev/null)
echo "${UP}|${OUT:-0|0|0|0}"
'
```

`%emUser%` and `%emPassword%` are substituted by the agent from
`NC_MONGO_MONITOR` at collection time. **They never appear in a process listing
or a log**, which is the reason for using the credential substitution rather than
embedding a password in the script.

| Column | Type | Notes |
|---|---|---|
| `service_up` | Number, **Alert** | Critical when 0 |
| `conn_current` | Number, Data | |
| `conn_available` | Number, **Alert** | Warning below 100 |
| `queries_total` | Number, Data | Cumulative since start — rate, not level, is the interesting part |
| `uptime_sec` | Number, Data | A falling value means an unlogged restart |

### 23.3 The two things that will break this

**`mongosh` must be on the agent's PATH.** The agent runs as `oracle` with a
minimal environment, not as your interactive shell. If the test fails with
nothing useful, use the absolute path — typically `/usr/bin/mongosh` — rather
than assuming.

**`oracle` must be allowed to run it.** The install doc keeps `mongod`,
`nestwise` and the app accounts deliberately separate. Connecting to
`127.0.0.1:27017` as `em_monitor` needs no special OS privilege, but confirm by
running the exact command as `oracle` on the host before building the ME:

```bash
sudo -u oracle mongosh --quiet -u em_monitor -p --authenticationDatabase admin \
  --host 127.0.0.1 --port 27017 --eval 'db.serverStatus().connections.current'
```

**Verify by hand first, then build the ME.** This is the same order Phase 7a used
for every unfamiliar command, and it is why that phase's failures were all in the
automation rather than in the Oracle work.

📸 *Screenshot: `7c-23a-mongosh-manual-as-oracle.png` — the command working as the agent's OS user, before any ME exists.*

📸 *Screenshot: `7c-23b-me-mongodb-test.png` — the ME test returning real connection counts.*

---

## Publish and deploy — all four

Once each ME tests clean:

1. **Actions → Save as Deployable Draft**
2. **Actions → Publish Metric Extension**
3. **Actions → Deploy To Targets** — `apexdb` for ME 1, `oradbserv04` for MEs 2-4

Then add the published extensions to the **`TC_DEVELOPMENT`** template collection
from [Part 2 §10](phase-7b-part2-admin-groups.md#10-create-and-associate-template-collections),
so any future Development target gets them without a manual deploy.

```bash
emcli list_metric_extension_on_target -target="oradbserv04.usat.com:host"
```

📸 *Screenshot: `7c-24a-me-published-list.png` — all four published.*

📸 *Screenshot: `7c-24b-me-deployed-to-targets.png` — deployment status per target.*

📸 *Screenshot: `7c-24c-metrics-charting.png` — the metrics collecting real values on the target's All Metrics page.*

---

## 24. Screenshot checklist and naming convention

```
screenshots/
├── 7c-01a-emcli-get-targets-baseline.png
├── 7c-01b-agent-status-per-host.png
├── 7c-02-prereq-checks-oradbserv04.png
├── 7c-03a1-oem-login-page.png
├── 7c-03a2-oem-Setup-name-credentials.png
├── 7c-03a3-oem-Setup-name-credentials_create_edit.png
├── 7c-03a4-named-credentials-create.png
├── 7c-03b1-named-credential-test-ok.png
├── 7c-03b2-named-credential-test-ok.png
├── 7c-04a1-add-host-targets-hostnames.png
├── 7c-04a2-add-host-targets-hostnames.png
├── 7c-04a3-add-host-targets-hostnames.png
├── 7c-04a-add-host-targets-hostnames.png
├── 7c-04b1-installation-details.png
├── 7c-04b2-installation-details.png
├── 7c-04c-prerequisite-check-results.png
├── 7c-04d-deployment-in-progress.png
├── 7c-04e-agent-status-uploading.png
├── 7c-05-agentdeploy-silent-output.png
├── 7c-07a-all-targets-multiselect-properties.png
├── 7c-07b-lifecycle-status-set.png
├── 7c-07c-property-readback.png
├── 7c-08a-hierarchy-levels.png
├── 7c-08b-hierarchy-created.png
├── 7c-08c-production-group-members.png
├── 7c-09a-template-create-metric-thresholds.png
├── 7c-09b-monitoring-templates-list.png
├── 7c-10a-template-collection-members.png
├── 7c-10b-associations.png
├── 7c-10c-apply-in-progress.png
├── 7c-11a-apply-status.png
├── 7c-11b-prod-threshold-applied.png
├── 7c-11c-dev-threshold-differs.png
├── 7c-11d-automatic-membership.png
├── 7c-12a-full-estate-targets.png
├── 7c-12b-cluster-templates-added.png
├── 7c-12c-target-count.png
├── 7c-13a1-reference-agent-plugins.png
├── 7c-13a2-reference-agent-plugins.png
├── 7c-14a-create-gold-agent-image.png
├── 7c-14b-create-image-version.png
├── 7c-14c-image-plugin-selection.png
├── 7c-14d-version-set-current.png
├── 7c-15a-add-host-from-gold-image.png
├── 7c-15b-provision-progress.png
├── 7c-15c-provisioned-agent-matches-image.png
├── 7c-15d-full-estate-targets.png
├── 7c-16a-subscribe-agents.png
├── 7c-16b-subscription-status.png
├── 7c-16c-blackout-active-before-update.png
├── 7c-16d-stage-operation.png
├── 7c-16e-update-complete.png
├── 7c-17a-all-agents-current.png
├── 7c-17b-agent-status-post-update.png
├── 7c-19-named-credential-mongo.png
├── 7c-20a-me-apex-sql-definition.png
├── 7c-20b-me-apex-test-results.png
├── 7c-21a-me-ords-command.png
├── 7c-21b-me-ords-test.png
├── 7c-22-me-proxy-test.png
├── 7c-23a-mongosh-manual-as-oracle.png
├── 7c-23b-me-mongodb-test.png
├── 7c-24a-me-published-list.png
├── 7c-24b-me-deployed-to-targets.png
└── 7c-24c-metrics-charting.png
```

Numbered to the section they illustrate, across all four parts — the same
convention as `installation/`'s Section 15 and Phase 7a's `03a-`/`16b-` series.
The `7c-` prefix keeps them distinct from Phase 7a's screenshots in this same
directory.

**Two standing procedures carry their own screenshot sets**, named for the
procedure rather than for a phase section, because they are run from more than one
place and by phases after this one:

| Set | Page |
|---|---|
| `discover-01` … `discover-09` | [Discovering and Promoting Targets](oem-discover-and-promote-targets.md) — run once per host, from Part 2 §12 |
| `blackout-01` … `blackout-09` | [Creating a Blackout](oem-create-blackout.md) — needed before Part 3 §16's agent restarts |

Capture each of those once, on the first host that exercises the step, rather
than repeating the set per host.

**Minimum set before calling this phase showcase-ready:** the discovery results
(`7c-06a`), the post-discovery target count (`7c-06d`), the hierarchy with
members (`7c-08c`), the two thresholds that differ by tier (`7c-11b` and
`7c-11c` — this is the pair that proves the whole administration-group exercise
worked), the estate on one image (`7c-17a`), and the metrics charting real values
(`7c-24c`).

**Where a step is not captured, say so and say why**, rather than leaving a gap
in the numbering — the same handling as
[Phase 7a Part 3 §19](phase-7a-part3-verification.md#19-screenshot-checklist-and-naming-convention)
gives the uncaptured `opatch apply` step.

---

Back to **[Part 3 — Agent golden image](phase-7b-part3-golden-image.md)**.
Back to the **[index](phase-7b-extending-coverage.md)**.
