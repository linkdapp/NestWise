# MongoDB server + Node proxy install — oradbserv04

Companion to [`installation/README.md`](../../installation/README.md) (the Oracle RAC build) and
[`install.md`](install.md) (the app-layer steps that assume this is already done) — this doc
covers the app tier build on `oradbserv04` end to end: OS-level prep, the MongoDB package install,
storage layout, the service-account and access-control model, the auth bootstrap, Node.js, and
the Node/Express proxy that fronts MongoDB for APEX. Written up the same way as the Oracle install
doc — real commands, real output, and the mistakes hit along the way, not a cleaned-up version of
what should have happened. Every section was independently re-verified against the live server on
2026-08-20 (Section 11) before this was written up as final.

## Contents

1. [Prerequisites and decisions](#1-prerequisites-and-decisions)
2. [Network configuration](#2-network-configuration)
3. [Disk layout](#3-disk-layout)
4. [Install MongoDB 6.0](#4-install-mongodb-60)
5. [Storage layout — separating data and journal](#5-storage-layout--separating-data-and-journal)
6. [First start and verification](#6-first-start-and-verification)
7. [Access model — personal login, scoped sudo, no shared root](#7-access-model--personal-login-scoped-sudo-no-shared-root)
8. [Auth bootstrap](#8-auth-bootstrap)
9. [Install Node.js](#9-install-nodejs)
10. [Deploy and run the Node/Express proxy](#10-deploy-and-run-the-nodeexpress-proxy)
11. [Final end-to-end verification](#11-final-end-to-end-verification)
12. [What went wrong along the way](#12-what-went-wrong-along-the-way)

## 1. Prerequisites and decisions

| Decision | Value | Why |
|---|---|---|
| Host | `oradbserv04.usat.com`, 192.168.56.186 | Already-built OL7 VM, earmarked for a future second FSFO Observer role — repurposed as the NestWise app tier for now |
| OS | Oracle Linux 7 | Existing lab VM — this constrains the next two decisions |
| MongoDB version | 6.0 | MongoDB dropped OL7/RHEL7 support starting at 7.0 — 6.0 is the last major version this host can run |
| Node.js version | 16.x, via NodeSource (`nodejs-16.20.2-1nodesource`) | The `mongodb` Node driver v6.x the proxy depends on requires Node ≥16.20.1. Oracle's own `ol7_developer_nodejs16` repo does provide this — confirmed for real on `yum.oracle.com` — but the locally installed `oracle-nodejs-release-el7` release package was an older build that only defined repo stanzas up through Node 10. Rather than chase an `oracle-nodejs-release-el7` update, NodeSource's `setup_16.x` script was used instead and installed clean on the first try — see Section 9 |
| App tier layout | `nestwise` (app user) and `mongod` (db user) kept as two separate service accounts | Same separation-of-duties principle as `oracle`/`grid` on the RAC nodes — one account per piece of software, not one shared account doing everything |
| Disk layout | `/u01` app, `/u02` Mongo data, `/u03` Mongo journal — 3 mount points, 3 separate physical disks | OFA-influenced, same as every other host in this lab; splitting journal onto its own disk avoids WAL writes competing with data-file I/O |

## 2. Network configuration

`oradbserv04` has two NICs, same NAT+Host-Only pattern as the RAC nodes, but with modern
predictable interface names (`enp0s3`/`enp0s8`) instead of the RAC nodes' classic `eth0`/`eth1` —
don't assume the naming matches without checking `nmcli con show` first.

| Interface | Role | Config |
|---|---|---|
| `enp0s3` | NAT (admin/internet) | DHCP |
| `enp0s8` | Host-Only, public lab network | Static `192.168.56.186`, netmask `255.255.255.0`, gateway `192.168.56.1`, search domain `usat.com` |

DNS resolves cross-cluster names (`scan-usatclust1`, `scan-usatclust2`) via `/etc/hosts`, matching
this lab's deliberate independent-BIND-per-cluster design
(`phase-01-foundation-2node-rac-12cR2/docs/known-risks.md` #59) — `oradbserv04` isn't a member of
either cluster's zone, so it was never going to resolve those names via DNS at all.

```bash
nmcli con mod enp0s8 ipv4.addresses 192.168.56.186/24
nmcli con mod enp0s8 ipv4.gateway 192.168.56.1
nmcli con mod enp0s8 ipv4.dns "192.168.56.181 192.168.56.182"
nmcli con mod enp0s8 ipv4.dns-search usat.com
nmcli con mod enp0s8 ipv4.method manual
nmcli con up enp0s8
```

NetworkManager kept regenerating `/etc/resolv.conf` from the DHCP-sourced `enp0s3` connection's
DNS (an ISP resolver), overriding the static config above. Fixed with the same override already
documented for the RAC nodes (`known-risks.md` #58):

```bash
# /etc/NetworkManager/NetworkManager.conf
[main]
dns=none
```
```bash
systemctl restart NetworkManager
```
Then write `/etc/resolv.conf` directly with the real nameservers and `search usat.com`, and verify
with `getent hosts` (not `nslookup`/`dig` — those bypass `/etc/hosts` entirely and query the
nameserver directly, which is the wrong tool for confirming hosts-file-based resolution).

## 3. Disk layout

```bash
# As root — partition, format, mount each disk. Repeat per mount point (/u01, /u02, /u03),
# each backed by its own physical disk on the host.
parted /dev/sdX mklabel gpt
parted /dev/sdX mkpart primary 0% 100%
mkfs.xfs /dev/sdX1
mkdir -p /u02
blkid /dev/sdX1   # get the UUID for fstab
```
Add to `/etc/fstab` by UUID, not device name:
```
UUID=<uuid-of-sdX1>  /u02  xfs  defaults  0  0
```
```bash
mount -a
df -h | grep /u0
```

## 4. Install MongoDB 6.0

```bash
cat > /etc/yum.repos.d/mongodb-org-6.0.repo << 'EOF'
[mongodb-org-6.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/7/mongodb-org/6.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-6.0.asc
EOF

yum install -y mongodb-org
```
This is what creates the `mongod` OS account — a system account with no login password, home
`/var/lib/mongo`. Confirm it exists before touching anything that depends on it:
```bash
id mongod
```

## 5. Storage layout — separating data and journal

MongoDB has no config parameter to relocate the WiredTiger journal onto a different disk — the
documented technique is symlinking `<dbPath>/journal` to the target disk **before mongod's first
start**, since `mongod` creates the real `journal/` directory itself on first boot if the symlink
isn't already there.

```bash
mkdir -p /u02/mongodb/data
mkdir -p /u03/mongodb/journal
ln -s /u03/mongodb/journal /u02/mongodb/data/journal
chown -R mongod:mongod /u02/mongodb /u03/mongodb
```

`/etc/mongod.conf` — full file as deployed:
```yaml
# mongod.conf
# for documentation of all options, see:
#   http://docs.mongodb.org/manual/reference/configuration-options/

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

storage:
  dbPath: /u02/mongodb/data
  journal:
    enabled: true

processManagement:
  timeZoneInfo: /usr/share/zoneinfo

net:
  port: 27017
  bindIp: 127.0.0.1

security:
  authorization: enabled
```

`bindIp: 127.0.0.1` is the package default and was deliberately left as-is — the Node proxy that
talks to Mongo runs on this same host, so there's no legitimate reason to expose port 27017
beyond localhost. This is one of the most consequential MongoDB defaults to get right; leaving a
Mongo instance bound to `0.0.0.0` with auth disabled is a well-documented, recurring cause of
real-world data breaches.

## 6. First start and verification

```bash
systemctl enable mongod
systemctl start mongod
systemctl status mongod
journalctl -u mongod --no-pager | tail -30
```
Confirm the storage layout actually took:
```bash
ls -la /u02/mongodb/data       # WiredTiger files + a "journal" symlink pointing at /u03
ls -la /u03/mongodb/journal    # real WiredTigerLog.*/WiredTigerPreplog.* files, ~100MB each
```
```bash
mongosh --eval 'db.runCommand({ connectionStatus: 1 })'
mongosh --eval 'db.serverStatus().storageEngine'
```
At this point `authenticatedUsers` is empty and every connection is unauthenticated —
expected, since auth isn't enabled yet (Section 8 fixes that).

## 7. Access model — personal login, scoped sudo, no shared root

The design goal: nobody administers this box, or MongoDB itself, by sharing the `root` password
or logging in directly as `mongod`. Same principle as `oracle`/`grid` on the RAC nodes — a named
personal account, elevated only through narrowly-scoped `sudo` grants, with every privileged
action attributable to a real person in `/var/log/secure`.

**Create the personal account** (as `root`):
```bash
useradd -m -c "mongodba - DBA" mongodba
passwd mongodba
```

**Give `mongod` a real shell.** The package default (`/bin/false`) actively blocks the exact
workflow this section sets up — see [gotcha #6](#9-what-went-wrong-along-the-way). Changed to
match how `oracle`/`grid` are already configured in this lab:
```bash
usermod -s /bin/bash mongod
```

**Two separate, narrow sudo grants** (as `root`, via `visudo` — never hand-edit files under
`/etc/sudoers.d/`, since a syntax error there can lock out sudo entirely and `visudo` validates
before saving):
```bash
visudo -f /etc/sudoers.d/mongod-admin
```
```
# mongodba may run commands as the mongod service account only —
# no path to root, no other runas target.
mongodba ALL=(mongod) NOPASSWD: ALL

# mongodba may control exactly the mongod systemd unit as root — nothing broader.
Cmnd_Alias MONGOD_SVC = /bin/systemctl start mongod, /bin/systemctl stop mongod, /bin/systemctl restart mongod, /bin/systemctl status mongod
mongodba ALL=(root) NOPASSWD: MONGOD_SVC
```
Deployed initially with `PASSWD:` — requiring `mongodba` to re-enter their own password on every
use, the more realistic enterprise default — then deliberately switched to `NOPASSWD:` for
lab-scale convenience. Either is defensible: `PASSWD:` forces re-authentication per action (worth
it in a real multi-person shop); `NOPASSWD:` removes the friction while keeping the same scoping
in place. What actually matters for the audit trail either way is the *Runas* restriction, not the
password prompt — every invocation still lands in `/var/log/secure` under `mongodba`'s name, and
`sudo systemctl restart sshd` is still refused regardless of which mode is set, since the scope is
enforced by the `(mongod)`/`(root) MONGOD_SVC` restriction, not by the password requirement.

**Give the `mongod` account a working profile** — the RPM install doesn't populate one from
`/etc/skel`, so login shells default to a bare `-bash-4.2$` prompt with no host/user/path
context:
```bash
# as mongod, via: sudo -iu mongod
cat > ~/.bash_profile << 'EOF'
export PS1="\h:\u:\w\$ "
EOF
source ~/.bash_profile
```

**Test:**
```bash
# as mongodba
sudo -iu mongod
whoami                       # → mongod
exit
sudo systemctl status mongod # → succeeds
sudo systemctl restart sshd  # → refused — proves the scope actually holds
```

## 8. Auth bootstrap

MongoDB ships with authorization disabled by default — anyone who can reach port 27017 has
unrestricted read/write access until this step. Order matters: create the first admin user
*while auth is still off*, then enable it, or the account gets locked out with no way back in
short of restarting without auth to fix it.

**As `mongodba` (or `mongod` — either works; this is a database-layer login, not tied to OS
identity), in `mongosh`, auth still disabled:**
```javascript
use admin
db.createUser({
  user: "dbadmin",
  pwd: passwordPrompt(),
  roles: [ { role: "userAdminAnyDatabase", db: "admin" }, "readWriteAnyDatabase" ]
})
```

**Enable authorization** (as `root`, edit `/etc/mongod.conf` — already shown in full in Section 5)
then:
```bash
systemctl restart mongod
```

**Verify it's actually enforced:**
```bash
mongosh --eval 'db.runCommand({ connectionStatus: 1 })'   # succeeds, authenticatedUsers: []
mongosh --eval 'db.adminCommand({listDatabases:1})'        # fails — "requires authentication"
```

**Create the scoped application user** the Node proxy will actually use — never `dbadmin`:
```bash
mongosh -u dbadmin -p --authenticationDatabase admin
```
```javascript
use nestwise
db.createUser({
  user: "nestwise_app",
  pwd: passwordPrompt(),
  roles: [ { role: "readWrite", db: "nestwise" } ]
})
```
Confirm with `db.getUsers()` that `_id` reads `nestwise.nestwise_app` — see
[gotcha #9](#9-what-went-wrong-along-the-way) for what it looks like when this goes wrong.

## 9. Install Node.js

**Who:** `root` — package installs are OS/infra-layer, same reasoning as the MongoDB package
install itself
**Where:** Linux shell

The proxy's `mongodb` driver (`package.json`: `^6.8.0`) requires Node ≥16.20.1. Oracle Linux 7's
own `ol7_developer_nodejs16` repo genuinely provides this (confirmed directly against
`yum.oracle.com` — `nodejs-16.20.2-1.0.1.el7.x86_64.rpm` is really there), but don't assume the
locally installed `oracle-nodejs-release-el7` package knows about it — it's versioned separately
from Node itself, and an older build of that release RPM only defines repo stanzas through Node
10:

```bash
yum install -y oracle-nodejs-release-el7
yum repolist all | grep -i node   # check what actually got defined before trusting the name
```

If `ol7_developer_nodejs16` isn't in that list, either update the release package
(`yum update -y oracle-nodejs-release-el7`, per Oracle's own documented fallback) or use
NodeSource's setup script directly — what actually got used here, after the Oracle-repo route
didn't pan out on the first pass:

```bash
curl -sL https://rpm.nodesource.com/setup_16.x | bash -
yum install -y nodejs
node -v      # v16.20.2
npm -v       # 8.19.4
```

## 10. Deploy and run the Node/Express proxy

**Who:** `root` for the initial pull and ownership; `nestwise` for everything after
**Where:** `/u01/app/nestwise` — the `nestwise` service account created earlier for the app
tier, kept separate from `mongod` (same separation-of-duties principle as `oracle`/`grid`)

```bash
cd /u01/app/nestwise
git clone https://github.com/linkdapp/NestWise.git
chown -R nestwise:nestwise /u01/app/nestwise/NestWise
```

`nestwise` hit the exact same problem `mongod` did in Section 7 — created with `/sbin/nologin` as
its shell, so `su - nestwise` failed with "This account is currently not available." Same fix,
same reasoning:

```bash
usermod -s /bin/bash nestwise
```

**As `nestwise`:**
```bash
cd /u01/app/nestwise/NestWise/nestwise-app/proxy
npm install
```

**Credentials — kept out of the shell, the unit file, and the app's own logs.** `db.js` reads
`NESTWISE_MONGO_URL` and defaults `NESTWISE_MONGO_DB` to `nestwise` already; `server.js` reads
`PORT` (default `4000`) and `NESTWISE_ADMIN_TOKEN`. Rather than `export` these in a shell (lands
in `~/.bash_history`) or hardcode them into the systemd unit file (world-readable at `0644` by
default), they live in a restricted-permission file systemd loads directly:

**Who:** `root`
```bash
cat > /etc/nestwise-proxy.env << 'EOF'
NESTWISE_MONGO_URL=mongodb://nestwise_app:<password>@localhost:27017/nestwise?authSource=nestwise
NESTWISE_ADMIN_TOKEN=<pick-a-real-secret>
PORT=4000
EOF
chown root:nestwise /etc/nestwise-proxy.env
chmod 640 /etc/nestwise-proxy.env
```
Note the `?authSource=nestwise` on the connection string — `nestwise_app` was created *inside* the
`nestwise` database (Section 8), not `admin`, so the driver needs to be told explicitly where to
authenticate or it defaults to `admin` and fails.

**The app's own logging leaked the credential.** `db.js` originally logged the raw `MONGO_URL`
directly — printing the full connection string, password included, straight into the systemd
journal on every connect. Fixed in the code itself, not just the deployment:
```javascript
const redactedUrl = MONGO_URL.replace(/\/\/([^:]+):([^@]+)@/, '//$1:***@');
console.log(`[nestwise-proxy] connected to MongoDB at ${redactedUrl}, db "${DB_NAME}"`);
```

**Systemd unit** — supervises the process, restarts on failure, and won't start before `mongod` is
actually up (matters at boot, when both would otherwise race):

**Who:** `root`
```bash
cat > /etc/systemd/system/nestwise-proxy.service << 'EOF'
[Unit]
Description=NestWise MongoDB Proxy
After=network-online.target mongod.service
Wants=network-online.target
Requires=mongod.service

[Service]
Type=simple
User=nestwise
Group=nestwise
WorkingDirectory=/u01/app/nestwise/NestWise/nestwise-app/proxy
EnvironmentFile=/etc/nestwise-proxy.env
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now nestwise-proxy
systemctl status nestwise-proxy
```

```bash
curl http://localhost:4000/health
curl "http://localhost:4000/api/listings?neighborhood_id=1"
journalctl -u nestwise-proxy --no-pager | tail -5
```
The `journalctl` line should show `mongodb://nestwise_app:***@...` — password masked, connection
otherwise real.

**Known, deliberate gap:** the redaction fix above was applied directly on `oradbserv04` for
immediate effect, before it was committed back to the `nestwise-app/proxy/db.js` in this repo.
Until that commit happens, the deployed copy on the server and the source of truth in GitHub are
out of sync — worth remembering generally: editing a file in the repo doesn't touch a server
that already cloned it, a deploy step (`git pull`, or equivalent) is always required separately.

## 11. Final end-to-end verification

Run as a single pass after everything above, confirming live state rather than trusting memory of
what should have happened:

```bash
# root — network, disk, service accounts
nmcli con show; cat /etc/resolv.conf
getent hosts scan-usatclust1.usat.com scan-usatclust2.usat.com
df -h | grep /u0; grep -E 'mongod|nestwise' /etc/passwd

# root — MongoDB service, storage, access control
systemctl status mongod; cat /etc/mongod.conf
ls -la /u02/mongodb/data /u03/mongodb/journal
cat /etc/sudoers.d/mongod-admin

# any account — auth actually enforced, both users present in the right databases
mongosh --eval 'db.adminCommand({listDatabases:1})'                 # must fail, unauthenticated
mongosh -u dbadmin -p --authenticationDatabase admin --eval 'use admin; db.getUsers()'
mongosh -u dbadmin -p --authenticationDatabase admin --eval 'use nestwise; db.getUsers()'

# root — Node.js and the proxy
node -v; npm -v
systemctl status nestwise-proxy
curl http://localhost:4000/health
journalctl -u nestwise-proxy --no-pager | tail -5
```

Run this exact checklist against `oradbserv04` on 2026-08-20: every check passed — correct DNS,
correct disk layout on three separate physical disks, all three service accounts with working
shells, `mongod.conf` matching spec with auth enabled, unauthenticated `listDatabases` correctly
refused, `dbadmin` and `nestwise_app` both present in their correct databases with correct roles,
Node `v16.20.2`, the proxy `active (running)` under systemd, and the connection log showing the
password redacted.

One lesson from this pass worth carrying forward: `mongosh --eval` with multiple
semicolon-separated statements only prints the *last* statement's return value — an earlier
attempt to check both `admin` and `nestwise` users in one `--eval` call silently showed only the
second result, and would have passed as "verified" if not re-run as two separate calls.

## 12. What went wrong along the way

Kept honest and specific, same standard as `known-risks.md` — these are real mistakes made
during this exact build, not a hypothetical list.

1. **Created the service account before its home directory's disk was mounted.** `useradd -r -m
   -d /u01/app/nestwise ...` failed with `cannot create directory` because `/u01` didn't exist
   yet. Fix: partition/format/mount always comes before account creation.
2. **Bundled the package install and the storage chown/symlink commands into one block.** The
   chown commands reference `mongod`, which doesn't exist until `yum install mongodb-org`
   finishes — ran them as one step and hit "no such user." Fix: checkpoint after the install
   (`id mongod`) before touching anything owned by that account.
3. **Assumed classic `eth0`/`eth1` naming from the RAC nodes' docs.** `oradbserv04` actually uses
   `enp0s3`/`enp0s8` (modern predictable naming) — every `nmcli con mod eth1 ...` command failed
   with "unknown connection" until checked against real `nmcli con show` output.
4. **`/etc/resolv.conf` kept reverting to an ISP resolver** despite correct static DNS config on
   `enp0s8`, because NetworkManager was regenerating it from the DHCP-sourced NAT connection.
   Fixed with `dns=none` in `NetworkManager.conf` (Section 2).
5. **`scan-usatclust2.usat.com` doesn't resolve from `oradbserv04`, or even from `usatclust1`'s
   own nodes** — initially looked like a bug, but traced back to this lab's own deliberate,
   already-documented decision (`known-risks.md` #59) to run fully independent BIND pairs per
   cluster. Expected behavior, not a regression.
6. **`sudo -iu mongod` silently did nothing** — no error, just an instant return to the calling
   prompt. Root cause: `mongod`'s package-default shell is `/bin/false`, which execs and exits
   immediately when invoked as a login shell, with zero output. Fixed with `usermod -s /bin/bash
   mongod` (Section 7) — matches how `oracle`/`grid` are already set up in this lab for exactly
   this reason.
7. **The `mongod`-runas sudo rule didn't cover `systemctl restart mongod`.** Becoming `mongod`
   and controlling the `mongod` *systemd unit* are different privilege levels — the latter is
   root-level regardless of which non-root account attempts it. Needed a second, separately
   scoped `(root)` grant limited to four literal `systemctl ... mongod` invocations, not a
   `systemctl` wildcard (verified by confirming `sudo systemctl restart sshd` is refused).
8. **`db.createUser()` calls went silently missing — three separate times** — because the
   multi-line JS block was pasted into `mongosh` bundled together with an adjacent command
   (`use <db>`, or a trailing `exit`). The interactive `Enter password` prompt from
   `passwordPrompt()` either never rendered or got consumed by the rest of the paste, and the
   session moved on with no error and no confirmation. Fix: paste `createUser()` blocks in
   complete isolation, and don't type or paste anything else until `{ ok: 1 }` actually appears.
9. **`nestwise_app` got created with `test` as its authentication database** instead of
   `nestwise`, because the `mongosh` session had reconnected between commands (defaulting back to
   `test`) and `use nestwise` was never re-run before `createUser()`. Caught by checking
   `db.getUsers()` output (`_id: 'test.nestwise_app'` instead of `'nestwise.nestwise_app'`) —
   dropped and recreated after confirming the prompt actually read `nestwise>` first.
10. **A stray, self-referential symlink** (`/u03/mongodb/journal/journal → /u03/mongodb/journal`)
    was left behind from the `ln -s` step being run twice with slightly different arguments.
    Harmless — `mongod` only ever looks at `/u02/mongodb/data/journal` — but confusing clutter,
    removed once noticed and confirmed gone in the Section 11 verification pass.
11. **The locally installed Node.js release RPM was stale.** `oracle-nodejs-release-el7` was
    already installed, but an older build of it — `yum repolist all` showed repo stanzas only
    through Node 10, with no `ol7_developer_nodejs16` entry at all, even though that repo
    genuinely exists on Oracle's yum server. Worked around with NodeSource's setup script instead
    of chasing a release-package update.
12. **`nestwise` hit the identical `/sbin/nologin` trap `mongod` had already hit in Section 7** —
    `su - nestwise` failed with "This account is currently not available," for the exact same
    reason, fixed the exact same way (`usermod -s /bin/bash nestwise`). Worth calling out as a
    repeated miss, not a new one: the account should have been created with a real shell from the
    start, matching the `oracle`/`grid` precedent already established in this lab, instead of
    defaulting to the generic "lock down service accounts" instinct and only catching it in the
    moment — twice.
13. **The proxy's own code logged its database credential in plaintext** — `db.js` printed the
    full `MONGO_URL`, password included, to the systemd journal on every connection. Fixed by
    redacting the password before logging (Section 10), but the fix was applied directly on the
    server before being committed to the repo, leaving the deployed copy and the GitHub source
    temporarily out of sync — a reminder that a local code edit never reaches a server that
    already cloned the repo without an explicit deploy step.
14. **A verification command silently under-reported.** Checking that both `dbadmin` (in `admin`)
    and `nestwise_app` (in `nestwise`) existed was attempted as one `mongosh --eval` call with two
    semicolon-separated statements — only the second statement's result actually printed, so the
    first check looked skipped even though nothing was wrong. Re-run as two separate `--eval`
    calls to get a real answer for both.
