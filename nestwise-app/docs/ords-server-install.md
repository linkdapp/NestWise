# ORDS install — oradbserv04

Companion to [`mongodb-server-install.md`](mongodb-server-install.md) (same host, app tier) and
[`install.md`](install.md) (the NestWise schema/app steps that assume ORDS is already installed
and working). Covers installing ORDS itself — the piece `install.md` explicitly assumes exists
and doesn't cover. Written up the same way as every other install doc in this project: real
commands, real output, including where it's currently stuck — not a cleaned-up version of what
should have happened.

**Status: 🟩 Confirmed — ORDS installed (clean, complete install — see §9), running under systemd
on :8080, pool VALID, and `ORDS.ENABLE_SCHEMA` verified working against a real app schema
(NestWise's `nestwise` user).** This upgrade to Oracle Database 19c ([`maintenance/`](../../maintenance/))
was done specifically to clear ORDS/APEX 26's documented 19c-or-newer requirement — confirmed
against Oracle's own APEX 26.1 install docs: APEX 26.1 requires ORDS 26.1.1+, and ORDS/APEX 26.1
requires Oracle Database 19c with RU 19.18 (January 2023) or newer. `apexdb` is on
19.32.0.0.260721 (`maintenance/part1-dbms-rolling-plan-to-switchover.md`), well above that floor.

The first install attempt (§5) hit a real `ORA-24344` compiling `oauth_internal.plb` — see §6 for
the root cause, confirmed rather than assumed: the object was left INVALID by that failed attempt,
then swept up and recompiled to VALID by the 19c upgrade's own automatic invalid-object recompile
pass (the same mechanism `utlrp.sql` provides, run as part of AutoUpgrade's post-upgrade actions)
— coincidental timing, not a retried install. The install step itself was never actually completed
until re-run in §7 — and even then, as §9 found days later, "re-run" wasn't the same as "actually
finished": the schema was left in a permanently half-installed state (`ords_metadata.ords_version`
stuck at `STATUS=INSTALLING`) that a full uninstall + reinstall was ultimately needed to fix.

## Contents

1. [Prerequisites and decisions](#1-prerequisites-and-decisions)
2. [Install Java 21](#2-install-java-21)
3. [Create the `ords` OS user](#3-create-the-ords-os-user)
4. [Download and unzip ORDS 26.2.2](#4-download-and-unzip-ords-2622)
5. [First install attempt — hits ORA-24344](#5-first-install-attempt--hits-ora-24344)
6. [Root cause — coincidental recompile, not a fix](#6-root-cause--coincidental-recompile-not-a-fix)
7. [Re-run install, then start the server](#7-re-run-install-then-start-the-server)
8. [Run under systemd](#8-run-under-systemd)
9. [Addendum — the ORA-01403 stuck-INSTALLING status](#9-addendum--the-ora-01403-stuck-installing-status)

## 1. Prerequisites and decisions

| Decision | Value | Why |
|---|---|---|
| Host | `oradbserv04.usat.com` | Same app-tier host as MongoDB and the Node proxy (`mongodb-server-install.md`) — one app server in front of both data tiers, per `docs/architecture.md` |
| ORDS version | 26.2.2 (build `r2041619`) | Current release at build time; requires an Oracle Database 19c-or-newer target — see status note above |
| Java version | 21 (Oracle JDK, LTS) | ORDS 26.x's own supported Java versions are 17 and 21 (Oracle Java or GraalVM EE) — 21 chosen as the newer LTS of the two |
| ORDS OS user | `ords`, home `/u01/app/ords` | Same one-account-per-piece-of-software separation-of-duties convention as `oracle`/`grid`/`mongod`/`nestwise` elsewhere in this lab |
| DB connection type | Custom URL (two-cluster descriptor) | Same reasoning as every other standing connection in this project (Swingbench, the Node proxy, ORDS's own runtime pool later in `install.md` §6a) — a connection pointed at a single cluster's SCAN breaks permanently on a real Data Guard switchover (`high-availability/part3-post-checks.md` §16, `known-risks.md` #139). Used here even for the one-time interactive installer, not just the runtime pool, so the *install* itself doesn't have to be re-run pointed at a different cluster if a switchover happens to land mid-install |
| Install target | `apexdb_rw` (role-based service) | Follows whichever cluster is currently primary automatically |

## 2. Install Java 21

```bash
~$ curl -O https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.tar.gz
~$ tar -xvzf jdk-21_linux-x64_bin.tar.gz
[root@oradbserv04 nestwise]# mkdir -p /usr/lib/jvm
[root@oradbserv04 nestwise]# mv /var/lib/mongo/jdk-21.0.12.1 /usr/lib/jvm/
[root@oradbserv04 nestwise]# chown -R root:root /usr/lib/jvm/jdk-21.0.12.1

[root@oradbserv04 ~]# alternatives --install /usr/bin/java java /usr/lib/jvm/jdk-21.0.12.1/bin/java 2100
[root@oradbserv04 ~]# alternatives --install /usr/bin/javac javac /usr/lib/jvm/jdk-21.0.12.1/bin/javac 2100
[root@oradbserv04 ~]# alternatives --config java
There are 3 programs which provide 'java'.
  Selection    Command
-----------------------------------------------
   1           java-1.7.0-openjdk.x86_64 (/usr/lib/jvm/java-1.7.0-openjdk-1.7.0.261-2.6.22.2.0.1.el7_8.x86_64/jre/bin/java)
*+ 2           java-1.8.0-openjdk.x86_64 (/usr/lib/jvm/java-1.8.0-openjdk-1.8.0.432.b06-1.0.1.el7_9.x86_64/jre/bin/java)
   3           /usr/lib/jvm/jdk-21.0.12.1/bin/java
Enter to keep the current selection[+], or type selection number: 3

[root@oradbserv04 ~]# java -version
java version "21.0.12.1" 2026-08-18 LTS
Java(TM) SE Runtime Environment (build 21.0.12.1+1-LTS-4)
Java HotSpot(TM) 64-Bit Server VM (build 21.0.12.1+1-LTS-4, mixed mode, sharing)
```

`oradbserv04` shipped with two older OpenJDK builds already registered under `alternatives`
(1.7 and 1.8, both pre-existing) — `alternatives --config java` is what actually switches the
active `java` on `PATH` to the new JDK 21, not just having it unpacked under `/usr/lib/jvm/`.

## 3. Create the `ords` OS user

```bash
[root@oradbserv04 ~]# useradd -m -d /u01/app/ords -c "ords" -s /bin/bash ords
[root@oradbserv04 ~]# passwd ords
[root@oradbserv04 ~]# su - ords
[ords@oradbserv04 ~]$ ls -ld /u01/app/ords
drwx------. 4 ords ords 4096 Aug 20 21:50 /u01/app/ords
```

Same pattern as `mongodb-server-install.md` §7 — a dedicated service account, not root and not
piggybacked on the `oracle` or `nestwise` accounts.

## 4. Download and unzip ORDS 26.2.2

```bash
[ords@oradbserv04 ~]$ cd /u01/app/ords
[ords@oradbserv04 ~]$ curl -O https://download.oracle.com/otn_software/java/ords/ords-26.2.2.204.1619.zip
[ords@oradbserv04 ~]$ mkdir ords-home
[ords@oradbserv04 ~]$ cd ords-home/
[ords@oradbserv04 ords-home]$ unzip -q ../ords-26.2.2.204.1619.zip
```

## 5. First install attempt — hits ORA-24344

```bash
oradbserv04:ords:~/ords-home$ mkdir -p /u01/app/ords/config
oradbserv04:ords:~/ords-home$ ords --config /u01/app/ords/config install
ORDS: Release 26.2 Production on Fri Aug 21 02:17:22 2026
Copyright (c) 2010, 2026, Oracle.
Configuration:
  /u01/app/ords/config
The configuration folder /u01/app/ords/config does not contain any configuration files.
Oracle REST Data Services - Interactive Install
  Enter a number to select the database connection type to use
    [1] Basic (host name, port, service name)
    [2] TNS (TNS alias, TNS directory)
    [3] Custom database URL
  Choose [1]: 3
  Enter the Custom database URL:    jdbc:oracle:thin:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=scan-usatclust1.usat.com)(PORT=1521))(ADDRESS=(PROTOCOL=TCP)(HOST=scan-usatclust2.usat.com)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=apexdb_rw)))
  Provide database user name with administrator privileges.
    Enter the administrator username: sys as sysdba
  Enter the database password for sys as sysdba:
Retrieving information.
ORDS is not installed in the database. ORDS installation is required.
  Enter a number to update the value or select option A to Accept and Continue
    [1] Connection Type: Custom URL
    [2] Custom URL Connection: CUSTOM_URL=jdbc:oracle:thin:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=scan-usatclust1.usat.com)(PORT=1521))(ADDRESS=(PROTOCOL=TCP)(HOST=scan-usatclust2.usat.com)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=apexdb_rw)))
           Administrator User: sys as sysdba
    [3] Database password for ORDS runtime user (ORDS_PUBLIC_USER): <generate>
    [4] ORDS runtime user and schema tablespaces:  Default: SYSAUX Temporary TEMP
    [5] Additional Feature: Database Actions
    [6] Configure and start ORDS in Standalone Mode: Yes
    [7]    Protocol: HTTP
    [8]       HTTP Port: 8080
    [A] Accept and Continue - Create configuration and Install ORDS in the database
    [Q] Quit - Do not proceed. No changes
  Choose [A]:
The setting named: db.connectionType was set to: customurl in configuration: default
The setting named: db.customURL was set to: jdbc:oracle:thin:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=scan-usatclust1.usat.com)(PORT=1521))(ADDRESS=(PROTOCOL=TCP)(HOST=scan-usatclust2.usat.com)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=apexdb_rw))) in configuration: default
The setting named: db.username was set to: ORDS_PUBLIC_USER in configuration: default
The setting named: db.password was set to: ****** in configuration: default
The setting named: feature.sdw was set to: true in configuration: default
The global setting named: database.api.enabled was set to: true
The setting named: restEnabledSql.active was set to: true in configuration: default
The global setting named: standalone.http.port was set to: 8080
The global setting named: standalone.doc.root was set to: /u01/app/ords/config/global/doc_root
The setting named: security.requestValidationFunction was set to: ords_util.authorize_plsql_gateway in configuration: default
2026-08-21T02:18:42.429Z INFO        Created folder /u01/app/ords/ords-home/logs
2026-08-21T02:18:42.430Z INFO        The log file is defaulted to the current working directory located at /u01/app/ords/ords-home/logs

**Read this before ever creating a second `--db-pool` on this server.** The `default` pool above already has the two-cluster JDBC descriptor, `db.username=ORDS_PUBLIC_USER`, and `restEnabledSql.active=true` — everything needed to serve schema-alias-routed REST requests (`/ords/<schema-alias>/...`) for any self-enabled schema in this database, `nestwise` included. A later step in this project (`nestwise-app/docs/install.md` §6a) mistakenly created a *second*, separately-named pool to "point ORDS at the two-cluster descriptor" without checking this section first — since that pool's name collided with the `nestwise` schema's own REST URL alias, it silently shadowed this already-correct `default` pool and broke every REST request for hours of real troubleshooting before the root cause was found. Full writeup: `nestwise-app/docs/install.md` §6a. The lesson generalizes: before configuring any `--db-pool` on this ORDS instance, check `ords --config /u01/app/ords/config config --db-pool default list` first — it is very likely already correct.
2026-08-21T02:18:42.850Z INFO        Installing Oracle REST Data Services version 26.2.2.r2041619 in NON_CDB
2026-08-21T02:18:43.354Z INFO        Cannot invoke "java.lang.CharSequence.length()" because "this.text" is null
2026-08-21T02:18:44.308Z INFO        ... Verified database prerequisites
2026-08-21T02:18:44.803Z INFO        ... Created Oracle REST Data Services proxy user
2026-08-21T02:18:45.919Z INFO        ... Created Oracle REST Data Services schema
2026-08-21T02:18:48.099Z INFO        ... Granted privileges to Oracle REST Data Services
2026-08-21T02:19:31.318Z INFO        ... Created Oracle REST Data Services database objects
Error executing script: oauth_internal.plb Error: ORA-24344: success with compilation error
ORA-06512: at line 25
ORA-06512: at "SYS.DBMS_SQL", line 1343
ORA-06512: at line 19
Help: https://docs.oracle.com/error-help/db/ora-24344/
 Refer to log file /u01/app/ords/ords-home/logs/ords_install_2026-08-21_021842_43107.log for details
```

`apexdb` is confirmed a NON_CDB database (the installer says so directly — matches
`phase-01-foundation-2node-rac-12cR2/README.md`'s own "General Purpose, non-CDB" design decision),
so ORDS's NON_CDB install path is the expected one here, not a mismatch.

## 6. Root cause — coincidental recompile, not a fix

The installer got through creating the ORDS proxy user, the ORDS schema, and granting privileges
— it failed specifically while creating ORDS's own database objects, on one package:
`oauth_internal.plb`. `ORA-24344: success with compilation error` means the `CREATE OR REPLACE`
for that package technically succeeded as a DDL statement, but the resulting object was left
INVALID — a real compile error the installer's own error stack didn't print (it only showed the
`DBMS_SQL` call that surfaced the problem, not the underlying PL/SQL error text).

First diagnostic attempt came up empty:

```sql
SELECT line, position, text
FROM dba_errors
WHERE name = 'OAUTH_INTERNAL'
ORDER BY sequence;

no rows selected
```

That told us something useful on its own — the object wasn't sitting there invalid waiting to be
inspected. Broadened the search to confirm where it actually was:

```sql
SELECT owner, object_name, object_type, status, last_ddl_time
FROM dba_objects
WHERE object_name LIKE '%OAUTH%'
ORDER BY last_ddl_time DESC;

OWNER            OBJECT_NAME       OBJECT_TYPE    STATUS  LAST_DDL_
---------------- ----------------- -------------- ------- ---------
ORDS_METADATA    OAUTH_INTERNAL    PACKAGE BODY   VALID   22-AUG-26
ORDS_METADATA    OAUTH_INTERNAL    PACKAGE        VALID   22-AUG-26
... (48 rows total, every OAUTH_* object in ORDS_METADATA, all VALID, all 20/22-AUG-26)
```

`VALID`, dated `22-AUG-26` — two days after the failed `21-AUG` install attempt, and confirmed
*not* the result of anyone re-running the ORDS installer in between (nothing was re-run). The
19c rolling upgrade's own post-upgrade work landed in that same window and includes exactly the
kind of database-wide invalid-object recompile pass (`utlrp.sql`-equivalent, run automatically as
part of AutoUpgrade's post-upgrade actions) that would sweep up ANY invalid object in the
database — including one left behind by an unrelated, already-failed ORDS install, with no idea
it belonged to ORDS at all. That's the most likely explanation the evidence supports; it wasn't
independently isolated further than that, since the practical outcome (re-running the ORDS
installer, §7) settled the question either way.

The stray Java-side null pointer logged right after the install started
(`Cannot invoke "java.lang.CharSequence.length()" because "this.text" is null`, logged at `INFO`
rather than crashing the installer) never got explained either — no public match found for it
against ORDS 26.2 specifically. Didn't block anything on the re-run in §7, so left as an open,
non-blocking oddity rather than chased further.

## 7. Re-run install, then start the server

With the underlying invalid object now valid, re-running the same install command took a
different path than the first attempt — it recognized the existing `default` pool and
`ORDS_METADATA` schema instead of starting a fresh interactive install from scratch:

```bash
oradbserv04:ords:~$ ords --config /u01/app/ords/config install
ORDS: Release 26.2 Production on Mon Aug 24 21:56:35 2026
Copyright (c) 2010, 2026, Oracle.
Configuration:
  /u01/app/ords/config
Oracle REST Data Services - Interactive Install
  Enter a number to select the database pool to upgrade ORDS or create an additional database pool
    [1] default      jdbc:oracle:thin:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HO...
    [C] Create an additional database pool
  Choose [1]:
  Provide database user name with administrator privileges.
    Enter the administrator username: sys
  Enter the database password for SYS AS SYSDBA:
Retrieving information.
Connecting to database user: ORDS_PUBLIC_USER url: jdbc:oracle:thin:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=scan-usatclust1.usat.com)(PORT=1521))(ADDRESS=(PROTOCOL=TCP)(HOST=scan-usatclust2.usat.com)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=apexdb_rw)))
2026-08-24T21:56:45.209Z INFO        Oracle REST Data Services schema version 26.2.2.r2041619 is installed.
```

No error this time — confirms §6's theory: the schema really was already fully valid, nothing
needed fixing at the database level. This path is the "verify/upgrade existing schema" flow, not
the fresh-install flow, so it doesn't start the standalone server on its own — it just confirms
the schema version and exits. The first attempt (§5) never got far enough to reach that step
either (it died on `oauth_internal.plb` before ever getting to standalone-mode startup), which is
exactly why nothing was listening on :8080 up to this point.

Starting the server directly confirms the rest works:

```bash
oradbserv04:ords:~$ ords --config /u01/app/ords/config serve
ORDS: Release 26.2 Production on Mon Aug 24 21:58:19 2026
Copyright (c) 2010, 2026, Oracle.
Configuration:
  /u01/app/ords/config
2026-08-24T21:58:19.789Z INFO        HTTP and HTTP/2 cleartext listening on host: 0.0.0.0 port: 8080
2026-08-24T21:58:19.841Z INFO        Disabling document root because the specified folder does not exist: /u01/app/ords/config/global/doc_root
2026-08-24T21:58:19.842Z INFO        Default forwarding from / to contextRoot configured.
2026-08-24T21:58:24.121Z INFO        Configuration properties for: |default|lo|
...
2026-08-24T21:58:24.123Z WARNING     *** jdbc.MaxLimit in configuration |default|lo| is using a value of 10, this setting may not be sized adequately for a production environment ***
2026-08-24T21:58:24.489Z INFO        Created Pool: |default|lo|-2026-08-24T21-58-23.350406243Z at: 2026-08-24T21:58:23.350406243Z
2026-08-24T21:58:24.562Z INFO
Mapped local pools from /u01/app/ords/config/databases:
  /ords/                              => default                        => VALID
2026-08-24T21:58:24.579Z INFO        Oracle REST Data Services initialized
Oracle REST Data Services version : 26.2.2.r2041619
Oracle REST Data Services server info: jetty/12.0.34
Oracle REST Data Services java info: Java HotSpot(TM) 64-Bit Server VM  (build 21.0.12.1+1-LTS-4 mixed mode, sharing)
```

Confirmed from a second session:

```bash
oradbserv04:ords:~$ curl -i http://localhost:8080/ords/
HTTP/1.1 302 Found
Location: http://localhost:8080/ords/_/landing
Transfer-Encoding: chunked
```

`302` to `/ords/_/landing` is the expected, correct response — ORDS is up, the `default` pool is
`VALID`, and it's actually serving. Two things worth flagging for later, not blocking: the
`jdbc.MaxLimit=10` warning above (fine for this lab's scale, worth revisiting if load testing this
tier the way `loadtest/swingbench/` does the RAC side), and the missing
`/u01/app/ords/config/global/doc_root` folder (harmless — ORDS just disables static doc serving
without it, not needed for the REST-only role ORDS plays here).

## 8. Run under systemd

`ords serve` above is running in the foreground of an interactive shell — it dies the moment that
session ends. Same "survive a reboot/logout" requirement as the Node proxy
(`mongodb-server-install.md` §10), same fix: a systemd unit, run as the dedicated `ords` account
rather than root. Unlike the proxy, `ords` isn't a sudoer by default on this host, and creating a
unit under `/etc/systemd/system/` needs root privilege one way or another — two real gotchas hit
getting there, both below.

**Gotcha 1 — `ords` had no sudo rights.** `usermod -aG wheel ords` (as root) plus `sudo -l` (as
`ords`) still failed with "ords is not in the sudoers file" — not a sudoers config problem, a
stale-session problem. The `ords` shell had been open since before the group change, and group
membership is only read at login; `sudo` was still checking the old group list. `newgrp wheel` (or
a fresh login) picked up the new membership without needing to drop the SSH session.

**Who:** `root`
```bash
usermod -aG wheel ords
```
**Who:** `ords`
```bash
newgrp wheel
sudo -l
```

**Gotcha 2 — `sudo cat > file` doesn't actually write as root.** The `>` redirect is opened by the
calling shell *before* `sudo` ever runs, so it's still an unprivileged write against
`/etc/systemd/system/`. `sudo tee` avoids this — `tee` itself runs as root and does the writing:

**Who:** `ords` (via `sudo`)
```bash
sudo tee /etc/systemd/system/ords.service > /dev/null << 'EOF'
[Unit]
Description=Oracle REST Data Services (ORDS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ords
Group=ords
WorkingDirectory=/u01/app/ords
ExecStart=/usr/bin/java -jar /u01/app/ords/ords-home/ords.war --config /u01/app/ords/config serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now ords
```

`ExecStart` calls `java -jar ords.war` directly rather than the `ords` shell wrapper on `PATH` —
systemd units don't source `ords`'s user profile (where `alternatives`-selected `java` and any
shell-level `PATH` additions live), so the full, explicit interpreter + jar path avoids a unit
that only works when launched from an interactive shell.

**Gotcha 3 — first `systemctl status` showed `inactive (dead)`, exit 0, with `Could not start
Standalone Mode because the listen port: 8080 is already in use`.** Not a systemd unit bug — the
manual, interactive `ords serve` session from §7 was still running in another terminal, still
holding port 8080 (and still the process that had been answering the `curl`/`journalctl` checks up
to that point). Found and closed it, then restarted the unit:

**Who:** `ords` (via `sudo`)
```bash
sudo ss -tlnp | grep 8080
# LISTEN 0  50  *:8080  *:*  users:(("java",pid=3256,fd=8))   <- the old manual session
```
Killed that session, then:
```bash
sudo systemctl restart ords
sudo systemctl status ords
```

**Confirmed working**, real output:

```
● ords.service - Oracle REST Data Services (ORDS)
   Loaded: loaded (/etc/systemd/system/ords.service; enabled; vendor preset: disabled)
   Active: active (running) since Mon 2026-08-24 21:31:08 EDT; 7s ago
 Main PID: 11412 (java)
   CGroup: /system.slice/ords.service
           └─11412 /usr/bin/java -jar /u01/app/ords/ords-home/ords.war --config /u01/app/ords/config serve
...
Mapped local pools from /u01/app/ords/config/databases:
  /ords/                              => default                        => VALID
Oracle REST Data Services initialized
Oracle REST Data Services version : 26.2.2.r2041619
```

```bash
oradbserv04:ords:~$ curl -i http://localhost:8080/ords/
HTTP/1.1 302 Found
Location: http://localhost:8080/ords/_/landing
Transfer-Encoding: chunked
```

ORDS is now durable — survives logout, and `Restart=on-failure` brings it back if the process
dies. Still open, non-blocking, same as §7: the `jdbc.MaxLimit=10` sizing warning, and the missing
`doc_root` folder.

## 9. Addendum — the ORA-01403 stuck-INSTALLING status

Written up after §1-§8 above looked finished — days later, standing up the NestWise app schema (`install.md` step 1) exposed a real gap none of the earlier checks (all-VALID objects, working synonym, `ords serve` genuinely up and returning `302`) had caught.

**What happened.** After clearing two other real, unrelated errors on the same `ORDS.ENABLE_SCHEMA` call (`ORA-06598` INHERIT PRIVILEGES, and `ORA-20011` from a leftover `DBMS_ROLLING` plan — see `maintenance/part2-finish-plan-and-troubleshooting.md` §13), the exact same call still failed:

```
ORA-01403: no data found
ORA-06512: at "ORDS_METADATA.ORDS", line 183
ORA-06512: at "ORDS_METADATA.ORDS_SERVICES_INTERNAL", line 2649
ORA-06512: at "ORDS_METADATA.ORDS_INTERNAL", line 458
```

**Root cause, found by querying the metadata directly rather than guessing:**

```sql
SELECT version, status FROM ords_metadata.ords_version;
-- 26.2.2.r2041619   INSTALLING

SELECT COUNT(*) FROM ords_metadata.ords_schemas;   -- 0
SELECT COUNT(*) FROM ords_metadata.ords_modules;   -- 0
SELECT COUNT(*) FROM ords_metadata.ords_handlers;  -- 0
```

`STATUS=INSTALLING`, not any completed value — and zero rows in every metadata table that would hold real registrations. The chain: the original `21-AUG` install (§5) died on `oauth_internal.plb` before it ever reached whatever internal step marks that version row finished. The 19c-upgrade's automatic recompile (§6) fixed the *PL/SQL object* validity — every package showed `VALID` — but never touched that separate bookkeeping row, because it's an installer-progress marker, not a compile artifact. The `24-AUG` re-run (§7) then saw valid objects and an existing version row and took ORDS's "verify/upgrade existing schema" shortcut path instead of a genuine install — and that path, it turns out, doesn't finalize the status either. Net result: `ORDS_METADATA` looked installed by every check that mattered at the time (valid objects, a version row present, the server itself running and serving `302`s) while never having actually completed its own install.

`dba_source` on `ORDS_METADATA.ORDS_INTERNAL`/`ORDS_SERVICES_INTERNAL` came back empty — those packages are wrapped, as expected for Oracle-shipped code, so the exact failing `SELECT INTO` couldn't be read directly; the `ords_version.STATUS` finding was conclusive enough on its own to not need it.

**Fix — clean uninstall + reinstall**, Oracle's own documented remedy for an incomplete/corrupt ORDS metadata schema. Safe here specifically because `ords_schemas`/`ords_modules`/`ords_handlers` were all still 0 — nothing had ever been successfully registered to lose:

```bash
sudo systemctl stop ords
ords --config /u01/app/ords/config uninstall
```
Uninstall log, real output — clean, no errors:
```
Uninstalling Oracle REST Data Services in NON_CDB
Update schema status to UNINSTALLING
drop user ORDS_METADATA
drop user ORDS_PUBLIC_USER
Commit complete.
Completed uninstall for Oracle REST Data Services. Elapsed time: 00:00:09.630
```
```bash
ords --config /u01/app/ords/config install
sudo systemctl start ords
sudo systemctl status ords   # Active: active (running), pool VALID
curl -i http://localhost:8080/ords/   # HTTP/1.1 302 Found
```

**Confirmed working end to end** — after the reinstall, the NestWise schema-creation script (synonym, grants, `INHERIT PRIVILEGES`) was re-run against the fresh `ORDS_METADATA`, and:

```sql
BEGIN
    ORDS.ENABLE_SCHEMA(
        p_enabled             => TRUE,
        p_schema              => 'NESTWISE',
        p_url_mapping_type    => 'BASE_PATH',
        p_url_mapping_pattern => 'nestwise',
        p_auto_rest_auth      => FALSE
    );
    COMMIT;
END;
/
-- PL/SQL procedure successfully completed.
```

**Worth remembering for next time:** "all objects VALID" and "server starts and responds" are necessary checks, not sufficient ones, for an ORDS install — the actual completion marker is `ords_metadata.ords_version.STATUS`, and it's worth checking that explicitly any time an install attempt was interrupted partway, even if a later step (a DB upgrade's recompile pass, in this case) makes everything else downstream look fine.
