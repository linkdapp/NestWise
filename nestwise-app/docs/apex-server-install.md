# Oracle APEX 26.1 install — oradbserv04

Companion to [`ords-server-install.md`](ords-server-install.md) (the ORDS standalone build this
depends on) and [`install.md`](install.md) (the app-layer steps that assume this is already done)
— this doc covers installing Oracle APEX 26.1 itself into the `apexdb_rw` PDB and wiring it up to
the ORDS standalone instance already running on `oradbserv04`. Written up the same way as the
other install docs in this project — real commands, real output, and the mistakes hit along the
way.

## Contents

1. [Prerequisites and decisions](#1-prerequisites-and-decisions)
2. [Get the software onto oradbserv04](#2-get-the-software-onto-oradbserv04)
3. [Install a SQL client — SQLcl, not a full Oracle client](#3-install-a-sql-client--sqlcl-not-a-full-oracle-client)
4. [Dedicated tablespace, not SYSAUX](#4-dedicated-tablespace-not-sysaux)
5. [Run apexins.sql](#5-run-apexinssql)
6. [Post-install: instance administrator, APEX_PUBLIC_USER, ORDS/APEX REST bridge](#6-post-install-instance-administrator-apex_public_user-ordsapex-rest-bridge)
7. [Point ORDS at the APEX images and restart](#7-point-ords-at-the-apex-images-and-restart)
7a. [Enable the PL/SQL Gateway on the pool](#7a-enable-the-plsql-gateway-on-the-pool--the-step-that-actually-makes-the-apex-ui-reachable)
8. [Verification](#8-verification)
9. [What went wrong along the way](#9-what-went-wrong-along-the-way)

## 1. Prerequisites and decisions

| Decision | Value | Why |
|---|---|---|
| Where to install from | `oradbserv04` (the same host running ORDS standalone), not a RAC DB node or a workstation | APEX's static images have to be served by the same ORDS instance that serves the app — installing from the same host means the `images/` folder never has to be copied across hosts afterward |
| ORDS | Already installed and running (26.2) — see `ords-server-install.md` | As of APEX 26.1, Oracle's own recommendation is ORDS before APEX; this project already had that order by circumstance |
| SQL client | SQLcl 23.3, not a full Oracle Instant Client / `sqlplus` | `sqlplus` was never installed on `oradbserv04` (it's an app-tier host, not a DB node) — SQLcl is a small, Java-only tool, and `oradbserv04` already has the JDK 21 the ORDS install provides, so no extra runtime was needed |
| APEX tablespace | Dedicated `apex_ts`, not the `SYSAUX` default many quick-start guides use | Oracle's own installation guidance treats a dedicated tablespace as the better practice — keeps APEX's own growth (application data, uploaded files) separate from a tablespace Oracle itself relies on for the dictionary/AWR. Matches this project's existing discipline of separate tablespaces/mount points for everything else (`nestwise`, Mongo data/journal) |
| Software source | `/media/sf_eoracle/tools/sqlcl-latest.zip` (already present in an existing VirtualBox shared folder) and `/media/sf_doracle/software/apex/apex-latest.zip` (APEX 26.1, transferred in via a second shared folder) | Reused what was already staged rather than re-downloading |

## 2. Get the software onto oradbserv04

**Who:** you, from your workstation — **What:** copy the extracted (or zipped) APEX software into
the VirtualBox shared folder already mounted on `oradbserv04` — **Where:** the shared-folder mount
on your workstation

The APEX zip landed at `/media/sf_doracle/software/apex/apex-latest.zip` on `oradbserv04` via this
route. Extracted to a proper OFA-style location rather than run directly out of the shared folder
(permission/locking risk running installers against a shared-folder mount):

**Who:** `ords` — **Where:** `oradbserv04`

```bash
mkdir -p /u01/app/apex
cd /u01/app/apex
unzip -q /media/sf_doracle/software/apex/apex-latest.zip
ls apex/apexins.sql
```

## 3. Install a SQL client — SQLcl, not a full Oracle client

`sqlplus` doesn't exist on this host — confirmed with `which sqlplus` (`command not found`) before
looking for alternatives. Rather than install a full Oracle Instant Client just to run four SQL
scripts, checked first whether SQLcl was already staged anywhere on the shared folders:

```bash
find / -iname "sqlcl*" -o -iname "sql.sh" 2>/dev/null | grep -v proc
```

Found `/media/sf_eoracle/tools/sqlcl-latest.zip` already present. Extracted the same OFA-style way:

**Who:** `root` for the extract/chown, `ords` for everything after — **Where:** `oradbserv04`

```bash
mkdir -p /u01/app/sqlcl
cd /u01/app/sqlcl
unzip -q /media/sf_eoracle/tools/sqlcl-latest.zip
chown -R ords:ords /u01/app/sqlcl
/u01/app/sqlcl/sqlcl/bin/sql -v
# SQLcl: Release 23.3.0.0 Production Build: 23.3.0.270.1251
```

Added to `ords`'s profile so `sql` and `$APEX_HOME` are always available:

```bash
cat >> ~/.bash_profile << 'EOF'
# custom — SQLcl + APEX software locations
export APEX_HOME=/u01/app/apex/apex
export PATH=/u01/app/sqlcl/sqlcl/bin:$PATH
alias sql='/u01/app/sqlcl/sqlcl/bin/sql'
EOF
source ~/.bash_profile
```

No `ORACLE_HOME`/`TNS_ADMIN` needed — every connection uses the full easy-connect string
(`//scan-usatclust1.usat.com:1521/apexdb_rw`), the same pattern used everywhere else in this
project, so SQLcl never needs a local Oracle client install at all.

## 4. Dedicated tablespace, not SYSAUX

**Who:** `sys`/`sysdba` — **Where:** DB, via `scan-usatclust1`, before running `apexins.sql`

```sql
CREATE TABLESPACE apex_ts
  DATAFILE '+DATA' SIZE 500M AUTOEXTEND ON NEXT 100M MAXSIZE 4G;
```

## 5. Run apexins.sql

**Who:** `sys`/`sysdba` — **What:** installs the full APEX development environment — **Where:**
`oradbserv04`, from inside `$APEX_HOME` (the script calls other `.sql` files by relative path)

```bash
cd $APEX_HOME
sql -l sys/<sys_password>@//scan-usatclust1.usat.com:1521/apexdb_rw as sysdba
```
```sql
SET DEFINE OFF
SPOOL /u01/app/apex/apexins_install.log
@apexins.sql apex_ts apex_ts TEMP /i/
SPOOL OFF
```

Real, confirmed output at the end:

```
timing for: Validating Installation
Elapsed:    0.03
#
# Actions in Phase 3:
#
    ok 1 - BEGIN                                                        |   0.00
    ...
    ok 20 - Validating Installation                                     |   0.03
ok 3 - 20 actions passed, 0 actions failed                              |   0.47

Thank you for installing Oracle APEX 26.1.0

Oracle APEX is installed in the APEX_260100 schema.

The structure of the link to the Oracle APEX Administration Services is as follows:
http://host:port/ords/apex_admin

The structure of the link to the Oracle APEX development environment is as follows:
http://host:port/ords/apex

timing for: Phase 3 (Switch)
Elapsed:    0.47

timing for: Complete Installation
Elapsed:   12.33
```

## 6. Post-install: instance administrator, APEX_PUBLIC_USER, ORDS/APEX REST bridge

**Who:** same `sys`/`sysdba` session — **Where:** `oradbserv04`, `$APEX_HOME`

**Instance Administrator account** (real gotcha here — see §9):

```sql
@apxchpwd.sql
```
Prompts for username (`ADMIN`), email (optional), password (twice).

**APEX_PUBLIC_USER** — this is the account ORDS's `default` pool proxies through for APEX page
rendering:

```sql
ALTER USER apex_public_user IDENTIFIED BY "<password>" ACCOUNT UNLOCK;
ALTER PROFILE DEFAULT LIMIT PASSWORD_LIFE_TIME UNLIMITED;
SET SERVEROUTPUT ON
EXEC sys.validate_apex;
```
Real confirmed output: `Setting DBMS Registry for APEX to valid`.

**APEX/ORDS REST bridge** — creates `APEX_LISTENER`/`APEX_REST_PUBLIC_USER` and wires the proxy
grants the existing `default` ORDS pool (`ORDS_PUBLIC_USER`) needs to reach APEX at all:

```sql
@apex_rest_config.sql
```
Prompts twice for passwords (`APEX_LISTENER`, `APEX_REST_PUBLIC_USER`). Real confirmed output
included the two lines that actually matter for this project's existing ORDS `default` pool setup
(`ords-server-install.md` §6):

```
INFO: Made APEX_PUBLIC_USER proxiable from ORDS_PUBLIC_USER
INFO: Made APEX_REST_PUBLIC_USER proxiable from ORDS_PUBLIC_USER
```

**Network ACL** — needed for `APEX_WEB_SERVICE`, which the Admin page's "Reload MongoDB Seed Data"
button (`apex/page_plan.md`, page 12) calls:

```sql
BEGIN
    DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
        host => '*',
        ace => xs$ace_type(privilege_list => xs$name_list('connect'),
                           principal_name => APEX_APPLICATION.g_flow_schema_owner,
                           principal_type => xs_acl.ptype_db));
END;
/
```

## 7. Point ORDS at the APEX images and restart

**Who:** `ords` — **Where:** `oradbserv04`

```bash
ords --config /u01/app/ords/config config set standalone.static.path $APEX_HOME/images
sudo systemctl restart ords
```

## 7a. Enable the PL/SQL Gateway on the pool — the step that actually makes the APEX UI reachable

**This step is easy to miss and this project missed it the first time — see §9.** Everything
above (`apexins.sql`, `apex_rest_config.sql`, static images) makes APEX *installed*, but the
`default` ORDS pool this project already had (`ords-server-install.md` §6) was configured before
APEX existed, so it was never told to actually serve APEX's PL/SQL Gateway routes
(`/ords/apex`, `/ords/apex_admin`, and every application URL APEX itself generates).

**Who:** `ords` — **Where:** `oradbserv04`

```bash
ords --config /u01/app/ords/config config --db-pool default set plsql.gateway.mode proxied
sudo systemctl restart ords
```

`proxied` mode uses the `PLSQL_GATEWAY_CONFIG` view (populated by `apex_rest_config.sql` in §6) to
determine which database user to proxy each Gateway request to — the correct mode for APEX,
confirmed against Oracle's own ORDS documentation before setting it, not guessed.

## 8. Verification

**Use a real `GET`, not `HEAD`** — `curl -I` sends `HEAD`, and this project's own first pass at
verification used `-I` and got a false-positive `200` on `/ords/apex_admin` and `/ords/apex` while
the actual `GET` route (and every browser request) was a genuine `404` — see §9. `curl -I` is fine
for confirming a static asset like `favicon.ico`, but not for confirming an APEX/PL-SQL-Gateway
route resolves.

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/ords/apex_admin   # 302 (redirect to the sign-in page — correct)
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/ords/apex          # 302
curl -sI http://localhost:8080/i/favicon.ico | head -1                            # HTTP/1.1 200 OK — proves static.path is real, not a fallback
```

Confirmed end to end against this lab's own live server, including a real browser load (not just
`curl`): `http://<oradbserv04-ip>:8080/ords/apex_admin` redirects to
`.../r/apex/workspace-sign-in/administration-sign-in?session=...` and renders the real Oracle APEX
Administration Services sign-in page. Log in with workspace `internal`, username `ADMIN`, the
password set in §6.

## 9. What went wrong along the way

1. **`sqlplus` doesn't exist on `oradbserv04`.** Expected in hindsight — it's an app-tier host that
   only ever had ORDS (a JDBC-based Java tool) installed on it, never a full Oracle client. Fixed
   by using SQLcl instead of installing a full client just to run four scripts (§3).
2. **`apxchpwd.sql` rejected the first password attempt**: `ORA-20001: Password validation failed.
   * Password must not contain username.` The chosen password contained the literal string
   `ADMIN`, tripping APEX's own default password-complexity policy. Fixed by re-running
   `apxchpwd.sql` with a password that doesn't contain the username — not a bug, working as
   designed, but worth flagging since the error message doesn't say which rule specifically failed
   until you read the "Password does not conform to this site's password complexity rules" block
   above it.
3. **`SYSAUX` is the technically-simplest default for `apexins.sql`, but not what was used here.**
   Deliberately created a dedicated `apex_ts` tablespace instead (§4) — this was a decision made
   during install, not a mistake fixed afterward, but worth recording since most quick-start guides
   (including the one this project's steps were cross-checked against) default straight to
   `SYSAUX` without mentioning the tradeoff.
4. **`/ords/apex_admin` and `/ords/apex` returned a genuine `404` on first real test — from a real
   browser, and from a local `curl` `GET`.** The first verification pass (originally written into
   §8 of this doc) used `curl -sI`, which sends `HEAD`, and got a false-positive `200` — `ss
   -tlnp` confirmed ORDS was listening correctly on all interfaces the whole time, ruling out a
   network/bind problem (the same class of bug this project already hit once with MongoDB's
   `bindIp`), and a real `GET` against `localhost` 404'd identically to the browser, ruling out
   anything network-specific at all. Root cause, confirmed against Oracle's own ORDS
   documentation, not guessed: the `default` pool's `plsql.gateway.mode` was never set, because
   that pool was configured (`ords-server-install.md` §6) before APEX existed in this database —
   without it, ORDS never routes PL/SQL Gateway requests (which is what every APEX URL is) to
   APEX at all, regardless of how correctly `apexins.sql`/`apex_rest_config.sql` ran. Fixed in §7a
   with `ords config --db-pool default set plsql.gateway.mode proxied`, confirmed working via a
   real browser login to the Administration Services sign-in page.
