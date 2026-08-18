# High Availability — Part 1: Setting Up Active Data Guard

**SOP: Data Guard Standby (`usatclust2`) — 2-Node Physical Standby for `apexdb`, on Oracle Linux 7**

Part 1 of 3 in this Data Guard series: **Part 1 (this page)** covers the host build through
role-based services — everything needed for a working Active Data Guard standby. [Part 2](part2-broker-fsfo-observer.md)
covers the Data Guard Broker, a real switchover test, and Fast-Start Failover with the
Observer. [Part 3](part3-post-checks.md) covers post-standby validation. Start here.

Status: 🟨 In progress — Section 10 (RMAN duplicate) done by hand against the live lab, not
yet confirmed to reproduce cleanly on a second, unattended run.

| # | Section | Status |
|---|---|---|
| 1 | Prerequisites and decisions | reference — n/a |
| 2 | Host-side VM and storage | 🟩 Confirmed (built by hand, per James) |
| 3 | OS baseline on oradbserv09/10 | 🟩 Confirmed |
| 4 | DNS for usatclust2 | 🟩 Confirmed |
| 5 | Time sync (chrony) | 🟩 Confirmed |
| 6 | ASMLib — mark shared disks | 🟩 Confirmed |
| 7 | SSH equivalence | 🟩 Confirmed |
| 8 | Clone GI + DB Oracle Homes | 🟩 Confirmed |
| 9 | Configure the usatclust2 cluster | 🟩 Confirmed |
| 10 | Create the standby database (RMAN duplicate) | 🟨 Done by hand, not yet clean |
| 11 | Remove the multiplexed standby redo log member | 🟩 Confirmed |
| 12 | Convert the standby to RAC | 🟩 Confirmed |
| 13 | Role-based services (`apexdb_rw`/`apexdb_ro`) | 🟩 Confirmed |

**Sections 1-9** are built and confirmed against real runs — Section 9 (cluster
configuration) required several real fixes along the way (response-file rendering
bugs, an ASM label/ownership migration, a removed `DATA02` diskgroup that was never
actually real — see
[`known-risks.md`](../phase-01-foundation-2node-rac-12cR2/docs/known-risks.md)
#46-#54, #65-#75) and is now live: `crsctl check crs` reports all 4 CRS-46xx
components online, `DATA01` (NORMAL, 3 voting files) and `RECO01` (NORMAL, matching
DATA01 — see #110) are both `MOUNTED`, OCR is healthy.

**Section 10** (the RMAN-duplicate standby build, 8 SOP phases) is where the one
genuinely open item lives. Phase 1 (prepare the primary database) and Phase 2
(Oracle Net configuration) are fully green, all 4 nodes, real passwords confirmed
(#81-#91); Phase 3 (prepare the standby host) is fully green, `apexdb1` started
`NOMOUNT` on `oradbserv09` (#93-#100); Phase 4 (RMAN `DUPLICATE ... FOR STANDBY FROM
ACTIVE DATABASE`) **completed against the real lab, but not cleanly** — 8 more real
bugs (#106-#113) had to be found and fixed along the way, and getting `apexdb_stby`
to a genuinely stable, fully-caught-up standby took manual intervention beyond what
the `dataguard_duplicate` role automates end to end. Treat Phase 4 as "done once, by
hand, with the automation mostly but not entirely keeping up" — **not yet confirmed
to reproduce cleanly on a second, unattended run.** See the honesty note at the top
of Phase 4's write-up below before relying on this for a rebuild.

**Sections 11 and 12** (Phases 5 and 6 of the same SOP) are both now confirmed
clean. Phase 5 (remove the multiplexed standby redo log member — James's own
request, run only after the standby is confirmed working, i.e. after Phase 4) is
confirmed clean — all six SRL groups single-member after two real-run bug fixes
(`known-risks.md` #121-#122). Phase 6 (convert the standby to RAC) is also confirmed
clean end-to-end — both `apexdb1` and `apexdb2` up via `srvctl` in `MOUNT`, managed
recovery restarted (`known-risks.md` #123-#133).

**Section 13** (Phase 8, role-based services `apexdb_rw`/`apexdb_ro`) is
**confirmed clean** after four real runs. First found and fixed missing
`tab off`, `OPEN READ ONLY` only touching one standby instance, and an
`ORA-44304` failure starting `apexdb_ro` on the standby. Second found a
hang (a leftover single-node script write) and the actual root cause
behind `ORA-44304`: opening a standby read only kills whatever
managed-recovery process was running, so restarting apply *before* the
open never survives it — fixed to open first, then restart apply. Third
confirmed that reordering worked, but a too-narrow SQL*Plus column made
the role's own check word-wrap and fail anyway, and separately found the
services were created on the primary but never *started* — `srvctl add
service` alone doesn't write the `dba_services` row — fixed as a
mandatory, idempotent step before any standby work. Fourth run: clean end
to end, no manual intervention — `apexdb_rw` running on `apexdb`,
`apexdb_ro` running on `apexdb_stby` (both instances), nothing else. See
`known-risks.md` #136's updates. Built ahead of Phase 7 (Broker) on
purpose since the `srvctl` commands are self-contained; see
`known-risks.md` #136 for how that ordering was determined and what
Phase 7 adds on top (automatic role-flip on a live switchover — covered in
[Part 2](part2-broker-fsfo-observer.md), confirmed via a real
`SWITCHOVER TO apexdb_stby` — see `known-risks.md` #137).

This page follows the same format as
[`../installation/README.md`](../installation/README.md); update each section to 🟩
Built with real commands/output as it actually gets run.

**Section order matches `installation/README.md`'s own proven sequence, not the order
these were originally built in** — every OS-level prerequisite (DNS, chrony, ASMLib,
SSH equivalence) lands before anything Oracle-software-related touches the node,
exactly like a freshly built primary node, independent of whether the software
arrives via a fresh install or a clone. See
[`known-risks.md`](../phase-01-foundation-2node-rac-12cR2/docs/known-risks.md) #57
for why this got reordered after the fact.

Screenshots referenced below go in [`screenshots/`](screenshots/) once captured — same
naming convention as `installation/`'s Section 15.

---

## Contents

1. [Prerequisites and decisions](#1-prerequisites-and-decisions)
2. [🟩 Confirmed — Host-side VM and storage (built by hand, per James)](#2-confirmed--host-side-vm-and-storage-built-by-hand-per-james)
3. [🟩 Confirmed — OS baseline on oradbserv09/10](#3-confirmed--os-baseline-on-oradbserv0910)
4. [🟩 Confirmed — DNS for usatclust2](#4-confirmed--dns-for-usatclust2)
5. [🟩 Confirmed — Time sync (chrony)](#5-confirmed--time-sync-chrony)
6. [🟩 Confirmed — ASMLib — mark oradbserv09/10's own shared disks](#6-confirmed--asmlib--mark-oradbserv0910s-own-shared-disks)
7. [🟩 Confirmed — SSH equivalence for grid/oracle across usatclust2](#7-confirmed--ssh-equivalence-for-gridoracle-across-usatclust2)
8. [🟩 Confirmed — Clone GI + DB Oracle Homes from oradbserv05](#8-confirmed--clone-gi--db-oracle-homes-from-oradbserv05)
9. [🟩 Confirmed — Configure the usatclust2 cluster](#9-confirmed--configure-the-usatclust2-cluster)
10. [🟨 Done by hand, not yet clean — Create the standby database (RMAN duplicate)](#10-done-by-hand-not-yet-clean--create-the-standby-database-rman-duplicate)
11. [🟩 Confirmed — Remove the multiplexed standby redo log member](#11-confirmed--remove-the-multiplexed-standby-redo-log-member)
12. [🟩 Confirmed — Convert the standby to RAC](#12-confirmed--convert-the-standby-to-rac)
13. [🟩 Confirmed — Role-based services](#13-confirmed--role-based-services-apexdb_rwapexdb_ro)

Continue to **[Part 2 — Broker, Fast-Start Failover, and Observer](part2-broker-fsfo-observer.md)**.

---

## 1. Prerequisites and decisions

| Item | Value |
|---|---|
| Target | 2-node physical standby cluster `usatclust2` for `apexdb` (primary: `usatclust1`, [`installation/README.md`](../installation/README.md)) — Active Data Guard, MAA pattern |
| Nodes | `oradbserv09.usat.com`, `oradbserv10.usat.com` — replace the old `07`/`08` inventory placeholders |
| Build method | GI 19c + DB 12.2.0.1 Oracle Homes **cloned** from the already-patched `oradbserv05` (tar/deploy, not a fresh silent install + RU/OJVM cycle) — see [`known-risks.md`](../phase-01-foundation-2node-rac-12cR2/docs/known-risks.md) #46 |
| Clone-time outage | **Clusterware is stopped on `oradbserv05` before cloning** (`crsctl stop crs`, manual — James's decision), accepting a brief `apexdb` outage rather than tarring a live GI home; brought back up (`crsctl start crs`) once the tarballs are captured — see Section 8 and `known-risks.md` #46 |
| Storage | Standby's own separate `.vdi` ASM disks — already created by James, not shared with `usatclust1`'s |
| OCR/voting | Fully separate from `usatclust1`'s — `usatclust2` is a genuinely independent cluster, not an extension of the primary's |
| Observer | `oemserver01` hosts the Data Guard Broker Observer initially; a second observer on `oradbserv04` (the future APEX/ORDS app server) is planned for later |
| Standby DB creation | RMAN `DUPLICATE ... FOR STANDBY FROM ACTIVE DATABASE` — **not** DBCA (DBCA creates new databases, not standbys) |
| Ansible control | Same control node/account as `installation/README.md` Section 5 — nothing new to set up there |

Before starting, read
[`known-risks.md`](../phase-01-foundation-2node-rac-12cR2/docs/known-risks.md) for my reasoning,

[`group_vars/all.yml`](../phase-01-foundation-2node-rac-12cR2/ansible/group_vars/all.yml)'s
`standby_nodes`/`standby_cluster_name`/`standby_scan_name`/`standby_scan_ips` match
your real addressing (already pre-populated in this repo).

---

## 2. 🟩 Confirmed — Host-side VM and storage (built by hand, per James)

VMs `oradbserv09`/`oradbserv10` and their own shared ASM `.vdi` disks already exist —
built directly, not through this repo's `vm-tuning-vboxmanage.ps1` script (that script
targets `usatclust1`'s node names only today; extending it to `usatclust2` is not yet
done). Confirm both VMs are registered and reachable before Section 3:

```powershell
"c:\Program Files\Oracle\VirtualBox\VBoxManage" list vms
```

📸 *Screenshot: list_vms.png.*

```bash
ansible -i inventory/hosts.ini oradbserv09,oradbserv10 -m raw -a "echo pong"
```
**What it does, in order:**

1. Uses the `raw` module, not `command`/`shell` — runs over SSH directly,
   no dependency on Python being present yet.
2. Confirms both new nodes are up, SSH-key-reachable, and resolve under
   their inventory names, before any real role runs against them.

📸 *Screenshot: echo_pong.png.*

---

## 3. 🟩 Confirmed — OS baseline on oradbserv09/10

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags standby_os_prep
ansible-playbook -i inventory/hosts.ini site.yml --tags standby_verify_baseline
```
**What it does, in order:**

`os_prep` (idempotent, check-then-act throughout):
1. Pushes `/etc/hosts`, sets the hostname.
2. Installs the 19c/12.2 preinstall RPMs plus every required/optional OL7
   package — checks what's already there first, installs only the gaps.
3. Creates the `grid`/`oracle` OS users and groups.
4. Lays out the OFA directory structure; partitions and mounts `/u01`.
5. Applies kernel/`sysctl`/`tuned` tuning, sets the I/O scheduler.
6. Disables SELinux/firewalld/NOZEROCONF; confirms chrony/swap are in
   order.

`verify_baseline`:
1. Re-checks every one of those items independently — not just "did the
   task report changed."
2. Fails loudly with a full gap list if anything's missing, rather than
   trusting `os_prep` reported success.

```bash
passwd grid
passwd Oracle
```
Same manual spot-checks as [`installation/README.md` Section 6](../installation/README.md#6-run-the-os-baseline-verify-clone-to-oradbserv06-personalize-verify-again)
apply here — `id grid; id oracle`, `df -h /u01`, etc. — just run against `oradbserv09`/
`oradbserv10` instead. Don't proceed until `verify_baseline` passes on both nodes.

📸 *Screenshot: Manual_spot_check.png.*

---

## 4. 🟩 Confirmed — DNS for usatclust2

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags standby_dns_bind
```
**What it does, in order:**

1. Installs BIND.
2. Renders `named.conf` plus forward/reverse zone files (primary on
   `oradbserv09`, secondary on `oradbserv10`).
3. Opens firewalld for DNS, only if firewalld is actually running.
4. Enables and starts `named`.
5. Points both nodes' `resolv.conf` at `usatclust2`'s own two nameservers
   and protects it from NetworkManager overwriting it.
6. Verifies the SCAN name round-robins across all 3 IPs.


**Verify** (from `oradbserv09`/`10` — `usatclust2`'s own resolvers, now real DNS
servers, not `/etc/hosts`-only clients):
```bash
cat /etc/resolv.conf                    # both nameserver lines should be 09/10, not 05/06
nslookup scan-usatclust2.usat.com
getent hosts scan-usatclust2.usat.com
```

📸 *Screenshot: nsloookup_usatclust2.png.*

---

## 5. 🟩 Confirmed — Time sync (chrony)

Same `chrony` role as `usatclust1`, unmodified — its client branch already
generalizes to any node that isn't `oemserver01` (the fixed external time master),
`oradbserv09`/`10` included, so this needed nothing beyond a new play:

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags standby_chrony
```
**What it does, in order:**

1. Installs chrony; disables/masks legacy `ntpd` if present.
2. Renders `chrony.conf` pointing every `usatclust2` node at `oemserver01`
   as its time source.
3. Adds a systemd drop-in so `chronyd` waits for the network before
   starting.
4. Enables and starts the service; shows `chronyc sources` for
   confirmation.

**Verify:**
```bash
chronyc sources     # expect ^* oemserver01.usat.com ...
chronyc tracking
```

📸 *Screenshot: chrony_tracking_sources.png.*

---

## 6. 🟩 Confirmed — ASMLib — mark oradbserv09/10's own shared disks
see `known-risks.md` #54.

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags standby_asmlib_disks
```
**What it does, in order:**

1. Configures `oracleasm` (non-interactive); initializes the driver and
   enables it at boot.
2. Confirms the real ASM device paths exist and are genuinely unused
   (`blkid`, not a filesystem/partition already on them).
3. Partitions each raw disk (single whole-disk GPT partition).
4. On `oradbserv09` only, labels each partition for ASMLib
   (`oracleasm createdisk`).
5. On both nodes, scans for and lists the discovered ASM disks — fails if
   `oradbserv10` doesn't see everything `oradbserv09` marked.

📸 *Screenshot: standby_asmlib_disks.png.*

📸 *Screenshot: standby_asmlib_disks_lists.png.*

---

## 7. 🟩 Confirmed — SSH equivalence for grid/oracle across usatclust2

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags standby_ssh_equivalence
```
**What it does, in order:**

1. Pre-populates the system-wide `known_hosts` (short name + FQDN for
   every `usatclust2` node — not IP, see `known-risks.md` #62), so the
   first real SSH connection doesn't hang on a host-key prompt.
2. Disables `CheckHostIP` — root cause of a spurious "host key differs"
   error on this network (#64).
3. Sets up passwordless SSH equivalence separately for the `grid` and
   `oracle` users, across both nodes — the actual prerequisite Section 8's
   clone and Section 9's `gridSetup.sh` propagation both depend on.

📸 *Screenshot: not yet captured.*

---

## 8. 🟩 Confirmed — Clone GI + DB Oracle Homes from oradbserv05

Role: [`gi_db_home_clone`](../phase-01-foundation-2node-rac-12cR2/ansible/roles/gi_db_home_clone/tasks/main.yml).
Full reasoning in the role's header comment and [`known-risks.md`](../phase-01-foundation-2node-rac-12cR2/docs/known-risks.md) #46/#66.

**Manual step required first — `crsctl stop crs` stop Clusterware on BOTH nodes, with the right
command:** James's decision, overriding this role's earlier "leave it live" approach —
accepts a brief `apexdb` outage in exchange for tarring a fully quiesced GI home
rather than arguing the risk away.

**`crsctl stop cluster -all` is not enough — it only stops CRSD-managed resources
(ASM, listeners, the database) and deliberately leaves Oracle High Availability
Services (OHASD) running.** Use `crsctl stop crs` instead — requires root/sudo, takes
no `-all` flag (it's local-node-only by design), so run it once on **each** node:

```bash
# On oradbserv05, as root:
sudo $GRID_HOME/bin/crsctl stop crs
# Then on oradbserv06, as root:
sudo $GRID_HOME/bin/crsctl stop crs

# Confirm fully down on oradbserv05 before proceeding — every CRS-46xx line should
# say "is not online" or a communication failure, not "is online":
sudo $GRID_HOME/bin/crsctl check crs
```

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags gi_db_home_clone
```

**What it does, in order:**

1. Preflights that Clusterware is genuinely stopped on `oradbserv05`
   (fails hard otherwise — won't tar a live home) and that `os_prep`
   already ran on the target nodes.
2. Tars the GI and DB homes on `oradbserv05` separately (Oracle's
   documented cloning exclusion list — node-specific/runtime files left
   out).
3. Copies both tarballs to the control node via `scp`, then out to
   `oradbserv09` only — deliberately not `oradbserv10`, since
   `gridSetup.sh`/`runInstaller` do their own node-to-node propagation
   later.
4. Extracts both on `oradbserv09`.
5. Re-asserts the setuid bit on `{{ db_home }}/bin/oracle`, which
   `unarchive` doesn't reliably preserve (`known-risks.md` #107).

```bash
# Once the role completes (both tarballs captured), on oradbserv05 then oradbserv06, as root:
sudo $GRID_HOME/bin/crsctl start crs
```

📸 *Screenshot: gi_db_home_clone.png.*

---

## 9. 🟩 Confirmed — Configure the usatclust2 cluster

Same two-phase `gridSetup.sh`/`config.sh` pattern as
[`installation/README.md` Section 11](../installation/README.md#11-silent-grid-infrastructure-install)
— same role (`grid_silent_install`), same response-file templates, pointed at a new
`usatclust2`-specific response file (`standby_cluster_name`/`standby_scan_name`/
`standby_scan_ips` already defined in `group_vars/all.yml`, redirected via
`group_vars/standby_nodes.yml`) — run against the Oracle Home Section 8 already
deployed, not a fresh install from media. This is also where the GI home actually
gets registered in each node's central inventory (deliberately left unregistered by
`gi_db_home_clone` — see Section 8's own note and `known-risks.md` #46/#65).

Confirmed against Oracle's current 19c Clusterware Administration and Deployment
Guide's own [Cloning Oracle Clusterware
chapter](https://docs.oracle.com/en/database/oracle/oracle-database/19/cwadd/cloning-oracle-clusterware.html):
for standing up a NEW cluster from a clone (this project's exact scenario), the
documented step is to run `gridSetup.sh` normally against the already-deployed
home — no `clone.pl` (deprecated as of 19c), no separate registration mechanism.

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags standby_grid_infrastructure
```
**What it does, in order:**

1. Resolves node1/node2 for whichever cluster is actually running
   (cluster-agnostic `nodes` redirection).
2. Phase A — `gridSetup.sh` installs and registers the GI software
   (`CRS_SWONLY`) on the already-cloned home; pauses for the root scripts.
3. Phase B — `config.sh` configures the actual cluster (`DATA01`
   diskgroup, OCR/voting, GIMR, SCAN/network); pauses for its own root
   scripts.
4. A separate storage step creates `RECO01` via `asmca`, once the cluster
   is already up.

Same two-pause, re-run-the-same-command pattern as the primary cluster's
own install.

Two real differences from Section 11's fresh-media flow, both handled automatically
by `gi_apply_ru: false` (`group_vars/standby_nodes.yml` — see `known-risks.md` #65
for the full reasoning):

- **No `-applyRU`** — the cloned home is already at the patched level (tarred from
  `oradbserv05` post-RU), so Phase A's `gridSetup.sh` call omits the flag entirely.
- **No OPatch update** — skipped outright; there's no RU/OPatch zip staged on
  `oradbserv09`/`10`, and none is needed.

Everything else — Phase A software registration + root scripts, Phase B cluster
configuration (`DATA01`, OCR/voting) + root scripts, then storage (`RECO01` via
`asmca`) — follows the exact same manual-root-script, re-run-the-same-command
pattern as Section 11. Watch for the same pauses (cluvfy review, then the two
root.sh stops) and follow them the same way, on `oradbserv09` first, then
`oradbserv10`.

**Verify** (run from `oradbserv09`):

```bash
crsctl stat res -t
asmcmd lsdg               # expect DATA01 and RECO01 only, both MOUNTED — no DATA02
ocrcheck                  # expect +DATA01 as Device/File Name
crsctl query css votedisk # expect 3 voting files, all in DATA01
srvctl config asm -detail

oradbserv09-grid-+ASM1$
oradbserv09-grid-+ASM1$ crsctl check crs
CRS-4638: Oracle High Availability Services is online
CRS-4537: Cluster Ready Services is online
CRS-4529: Cluster Synchronization Services is online
CRS-4533: Event Manager is online
oradbserv09-grid-+ASM1$
oradbserv09-grid-+ASM1$ asmcmd lsdg

State    Type    Rebal  Sector  Logical_Sector  Block       AU  Total_MB  Free_MB  Req_mir_free_MB  Usable_file_MB  Offline_disks  Voting_files  Name
MOUNTED  NORMAL  N         512             512   4096  4194304    149988   149072            49996           49538              0             Y  DATA01/
MOUNTED  EXTERN  N         512             512   4096  1048576    149994   149890                0          149890              0             N  RECO01/
oradbserv09-grid-+ASM1$
oradbserv09-grid-+ASM1$
oradbserv09-grid-+ASM1$ crsctl query css votedisk
##  STATE    File Universal Id                File Name Disk group
--  -----    -----------------                --------- ---------
 1. ONLINE   d1d61c6588ea4f54bf8b5c8f3425231b (/dev/oracleasm/disks/SASMDISK3) [DATA01]
 2. ONLINE   dcf2c9b1776b4f71bf16eed520e01737 (/dev/oracleasm/disks/SASMDISK1) [DATA01]
 3. ONLINE   2057ca5af4d84f45bf58a5517bde64de (/dev/oracleasm/disks/SASMDISK2) [DATA01]
Located 3 voting disk(s).
oradbserv09-grid-+ASM1$
oradbserv09-grid-+ASM1$ ocrcheck
Status of Oracle Cluster Registry is as follows :
         Version                  :          4
         Total space (kbytes)     :     491684
         Used space (kbytes)      :      84224
         Available space (kbytes) :     407460
         ID                       : 1453488698
         Device/File Name         :    +DATA01
                                    Device/File integrity check succeeded

                                    Device/File not configured

                                    Device/File not configured

                                    Device/File not configured

                                    Device/File not configured

         Cluster registry integrity check succeeded

         Logical corruption check bypassed due to non-privileged user

oradbserv09-grid-+ASM1$
oradbserv09-grid-+ASM1$ srvctl config asm -detail
ASM home: <CRS home>
Password file: +DATA01/orapwASM
Backup of Password file: +DATA01/orapwASM_backup
ASM listener: LISTENER
ASM is enabled.
ASM is individually enabled on nodes:
ASM is individually disabled on nodes:
ASM instance count: 3
Cluster ASM listener: ASMNET1LSNR_ASM
oradbserv09-grid-+ASM1$
oradbserv09-grid-+ASM1$
oradbserv09-grid-+ASM1$
oradbserv09-grid-+ASM1$ crsctl stat res -t
--------------------------------------------------------------------------------
Name           Target  State        Server                   State details
--------------------------------------------------------------------------------
Local Resources
--------------------------------------------------------------------------------
ora.LISTENER.lsnr
               ONLINE  ONLINE       oradbserv09              STABLE
               ONLINE  ONLINE       oradbserv10              STABLE
ora.chad
               ONLINE  ONLINE       oradbserv09              STABLE
               ONLINE  ONLINE       oradbserv10              STABLE
ora.net1.network
               ONLINE  ONLINE       oradbserv09              STABLE
               ONLINE  ONLINE       oradbserv10              STABLE
ora.ons
               ONLINE  ONLINE       oradbserv09              STABLE
               ONLINE  ONLINE       oradbserv10              STABLE
--------------------------------------------------------------------------------
Cluster Resources
--------------------------------------------------------------------------------
ora.ASMNET1LSNR_ASM.lsnr(ora.asmgroup)
      1        ONLINE  ONLINE       oradbserv09              STABLE
      2        ONLINE  ONLINE       oradbserv10              STABLE
      3        OFFLINE OFFLINE                               STABLE
ora.DATA01.dg(ora.asmgroup)
      1        ONLINE  ONLINE       oradbserv09              STABLE
      2        ONLINE  ONLINE       oradbserv10              STABLE
      3        OFFLINE OFFLINE                               STABLE
ora.LISTENER_SCAN1.lsnr
      1        ONLINE  ONLINE       oradbserv10              STABLE
ora.LISTENER_SCAN2.lsnr
      1        ONLINE  ONLINE       oradbserv09              STABLE
ora.LISTENER_SCAN3.lsnr
      1        ONLINE  ONLINE       oradbserv09              STABLE
ora.RECO01.dg(ora.asmgroup)
      1        ONLINE  ONLINE       oradbserv09              STABLE
      2        ONLINE  ONLINE       oradbserv10              STABLE
      3        ONLINE  OFFLINE                               STABLE
ora.asm(ora.asmgroup)
      1        ONLINE  ONLINE       oradbserv09              Started,STABLE
      2        ONLINE  ONLINE       oradbserv10              Started,STABLE
      3        OFFLINE OFFLINE                               STABLE
ora.asmnet1.asmnetwork(ora.asmgroup)
      1        ONLINE  ONLINE       oradbserv09              STABLE
      2        ONLINE  ONLINE       oradbserv10              STABLE
      3        OFFLINE OFFLINE                               STABLE
ora.cvu
      1        ONLINE  ONLINE       oradbserv09              STABLE
ora.oradbserv09.vip
      1        ONLINE  ONLINE       oradbserv09              STABLE
ora.oradbserv10.vip
      1        ONLINE  ONLINE       oradbserv10              STABLE
ora.qosmserver
      1        ONLINE  ONLINE       oradbserv09              STABLE
ora.scan1.vip
      1        ONLINE  ONLINE       oradbserv10              STABLE
ora.scan2.vip
      1        ONLINE  ONLINE       oradbserv09              STABLE
ora.scan3.vip
      1        ONLINE  ONLINE       oradbserv09              STABLE
--------------------------------------------------------------------------------
oradbserv09-grid-+ASM1$
oradbserv09-grid-+ASM1$

```

📸 *Screenshot: standby_grid_infrastructure.png.*

---

## 10. 🟨 Done by hand, not yet clean — Create the standby database (RMAN duplicate)

Built from a real, MAA-grounded SOP James provided
(`standby_dataguard_creation.txt`): `RMAN DUPLICATE ... FOR STANDBY FROM ACTIVE
DATABASE`, run from an `oradbserv09` instance against `apexdb` on `oradbserv05`
over `Net*`— see `known-risks.md` #76.

**Phase 1 — Prepare the primary database:**
role [`dataguard_primary_prep`](../phase-01-foundation-2node-rac-12cR2/ansible/roles/dataguard_primary_prep/tasks/main.yml),
run from `oradbserv05` (`rac_node1`) against the live `apexdb` primary:

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags dataguard_primary_prep
```
**What it does, in order:** 11 steps against the live primary, each its own
task, full detail and real output below.

1. Read-only config check.
2. Back up the current spfile.
3. Check/enable `FORCE LOGGING`.
4. Check/enable Flashback Database.
5. Set `STANDBY_FILE_MANAGEMENT=MANUAL`.
6. Add the 6 missing standby redo log groups (skips any that already
   exist).
7. Set `STANDBY_FILE_MANAGEMENT` back to `AUTO`.
8. Confirm the SRL layout.
9. Check the ASM broker-config directories exist.
10. Set every role-aware Data Guard parameter — broker file locations
    *before* `dg_broker_start=true`, order matters (#81).
11. Check whether a password file is already registered (check only,
    never auto-fixes).

Every SQL step below now runs as `sqlplus / as sysdba @<script>.sql`
against a real `.sql` file the role writes to
`/u01/app/oracle/staging/sql/` first — see `known-risks.md` #82.


**1. Verify current primary configuration (read-only)**

```sql
set echo on heading on feedback off linesize 200 tab off pagesize 100
column thread# format 999
column group# format 999
column size_mb format 9999
column members format 999
column status format a16
select name, db_unique_name, database_role, open_mode, force_logging, flashback_on, log_mode from v$database;
select thread#, group#, bytes/1024/1024 size_mb, members, status from v$log order by 1,2;
select group#, thread#, bytes/1024/1024 size_mb, status from v$standby_log order by 1;
exit;
```
📸 *Screenshot: Show_current_primary_configuration.png.*

Read-only sanity check before touching anything — this task has run
cleanly every time (`changed_when: false`, never fails), but its specific
output wasn't captured in what got pasted back during debugging. Will
paste the real transcript here once the next run captures it end-to-end
with the script-file echo fix.

**2. Back up the current spfile** (safety net, before any `alter system`/`alter database` below)

```sql
set echo on
create pfile='/u01/app/oracle/staging/backups/spfile_apexdb_<epoch>.ora' from spfile;
exit;
```

📸 *Screenshot: Show_spfile_backup_output.png.*
```
SQL*Plus: Release 12.2.0.1.0 Production on Sat Aug 15 01:47:13 2026
Connected to:
Oracle Database 12c Enterprise Edition Release 12.2.0.1.0 - 64bit Production

File created.

Disconnected from Oracle Database 12c Enterprise Edition Release 12.2.0.1.0 - 64bit Production
```

**3. Check / enable `FORCE LOGGING`** (idempotent)

```sql
set echo on heading off feedback off
select force_logging from v$database;
exit;
```

📸 *Screenshot: Show_current_FORCE_LOGGING_state.png.*


Already `YES` on this run — the `alter database force logging;` task and
its output task both reported `skipping`, correctly, since it was already on.

**4. Check / enable Flashback Database** (idempotent, 24h retention target)

```sql
set echo on heading off feedback off
select flashback_on from v$database;
exit;
```

📸 *Screenshot: Show_current_Flashback_Database_state.png.*

Same result: already `YES`, so `alter system set db_flashback_retention_target=1440 scope=both sid='*'; alter database flashback on;` was skipped
— which turned out to hide a real gap (`known-risks.md` #115): because
flashback was already on, retention was never re-checked either, so when
James later raised the target to 3 days (4320 minutes) by hand, a re-run of
this role wouldn't have picked that change up — the enable-flashback and
set-retention logic were both gated on the same "is flashback off" check.
Split into its own independent check-then-act pair now, and
`dg_flashback_retention_minutes` (4320) in `group_vars/all.yml` is the
current target on both the primary and standby.

**5. Set `STANDBY_FILE_MANAGEMENT=MANUAL`** (required before manually adding standby redo logs)

```sql
set echo on
alter system set standby_file_management=manual scope=both sid='*';
exit;
```

📸 *Screenshot: Show_STANDBY_FILE_MANAGEMENT.png.*

**6. Add the missing standby redo log groups** — MAA formula `(max ORL groups/thread + 1) × threads` = groups 11-16, 128MB single-member, all on `+RECO01`, thread 1 for 11-13 and thread 2 for 14-16. A PL/SQL loop checks `v$standby_log` per group# first, so a partial or repeat run only adds what's actually missing:

```sql
set echo on serveroutput on
DECLARE
  v_cnt NUMBER;
BEGIN
  FOR i IN 11..16 LOOP
    SELECT COUNT(*) INTO v_cnt FROM v$standby_log WHERE group# = i;
    IF v_cnt = 0 THEN
      EXECUTE IMMEDIATE 'ALTER DATABASE ADD STANDBY LOGFILE THREAD ' ||
        CASE WHEN i < 14 THEN '1' ELSE '2' END ||
        ' GROUP ' || i || ' (''+RECO01'') SIZE 128M';
      DBMS_OUTPUT.PUT_LINE('Added standby logfile group ' || i);
    ELSE
      DBMS_OUTPUT.PUT_LINE('Standby logfile group ' || i || ' already exists — skipped');
    END IF;
  END LOOP;
END;
/
exit;
```

📸 *Screenshot: Show_standby_redolog_creation.png.*


**7. Set `STANDBY_FILE_MANAGEMENT` back to `AUTO`**

```sql
set echo on
alter system set standby_file_management=auto scope=both sid='*';
exit;
```

📸 *Screenshot: Show_STANDBY_FILE_MANAGE_auto.png.*


**8. Confirm the standby redo log layout**

```sql
column group# format 999
column thread# format 999
column size_mb format 9999
column status format a12
column member format a60
set echo on heading on feedback off linesize 200 tab off pagesize 100
select sl.group#, sl.thread#, sl.bytes/1024/1024 size_mb, sl.status, lf.member
from v$standby_log sl, v$logfile lf where sl.group#=lf.group# order by sl.thread#, sl.group#;
exit;
```

📸 *Screenshot: Show_STANDBY_FILE_MANAGE_auto.png.*

**9. Check the ASM directory each broker config file will live under**

```bash
asmcmd ls +DATA01/apexdb
asmcmd ls +RECO01/apexdb
```

```
+DATA01/apexdb → CONTROLFILE/ DATAFILE/ ONLINELOG/ PARAMETERFILE/ PASSWORD/ TEMPFILE/
+RECO01/apexdb → ARCHIVELOG/ AUTOBACKUP/ CONTROLFILE/ FLASHBACK/ ONLINELOG/
```

Both directories already existed (DBCA created them when `apexdb` was
first built), so the `asmcmd mkdir` step that only runs where the check
finds nothing was correctly skipped on both diskgroups.

**10. Set the primary's role-aware Data Guard parameters** — the step that
previously hit `ORA-02097`/`ORA-16573` (see `known-risks.md` #81: broker
config file locations have to be set *before* `dg_broker_start=true`, not
after, because `dg_broker_start` takes effect immediately and DMON locks
whatever file paths it finds at that moment):

```sql
set echo on
alter system set log_archive_config='dg_config=(apexdb,apexdb_stby)' scope=both sid='*';
alter system set log_archive_dest_1='location=use_db_recovery_file_dest valid_for=(all_logfiles,all_roles) db_unique_name=apexdb' scope=both sid='*';
alter system set log_archive_dest_2='service=apexdb_stby_dg async valid_for=(online_logfiles,primary_role) db_unique_name=apexdb_stby' scope=both sid='*';
alter system set log_archive_dest_state_1=enable scope=both sid='*';
alter system set log_archive_dest_state_2=enable scope=both sid='*';
alter system set fal_server='apexdb_stby' scope=both sid='*';
alter system set standby_file_management=auto scope=both sid='*';
alter system set dg_broker_start=false scope=both sid='*';
alter system set dg_broker_config_file1='+DATA01/apexdb/dr1apexdb.dat' scope=both sid='*';
alter system set dg_broker_config_file2='+RECO01/apexdb/dr2apexdb.dat' scope=both sid='*';
alter system set dg_broker_start=true scope=both sid='*';
exit;
```


All 11 statements succeeded once the file-location-before-broker-start
reorder was in place — confirms the #81 fix.

**Updated since this capture.** `log_archive_dest_2` above uses
`service=apexdb_stby_dg` — James later changed this to the plain
`service=apexdb_stby` (`known-risks.md` #115, tested working), once
`apexdb_stby` itself started carrying `(UR=A)` too and the `_dg`-suffixed
alias stopped being the only one that could connect pre-open. The role now
generates `service=apexdb_stby` directly. Also not shown here: flashback
retention was later raised from 24h to 3 days (`db_flashback_retention_
target=4320`) — see step 4 below and #115.

**11. Check whether a password file is already registered** (check only —
this task never runs `orapwd`; a missing password file gets investigated
by hand, not auto-fixed, since `orapwd ... force=y` would overwrite a
working file):

```bash
srvctl config database -d apexdb
```
📸 *Screenshot: Show_full_srvctl_config_db.png.*

First run surfaced a second real bug: the check came back as
`****ORACLE_HOME environment variable is not set` instead of real
`srvctl` output — the `command` module doesn't source a shell environment
the way the `shell` tasks elsewhere in this role do, so `ORACLE_HOME`/
`ORACLE_SID` never reached `srvctl`. Fixed by adding an explicit
`environment:` block to that task (see `known-risks.md` #83). Re-running
next to get a real answer on the password file before moving to Phase 2.

**Phase 2 — Oracle Net configuration (built, first real run hit and fixed one bug):**
role [`dataguard_net_config`](../phase-01-foundation-2node-rac-12cR2/ansible/roles/dataguard_net_config/tasks/main.yml),
the only Data Guard role that touches both clusters in the same play — every
DB node needs the same `tnsnames.ora` (both clusters' SCAN aliases), and each
node needs its own static listener entry (plain service only — no
`_DGMGRL` yet, see `known-risks.md` #135). Runs against a new
`dg_db_nodes` inventory group (`rac_nodes` + `standby_nodes` together):

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags dataguard_net_config
```
**What it does, in order:** three sub-steps, all against `dg_db_nodes`
(both clusters together).

1. **6.1** — renders `tnsnames.ora`'s Data Guard aliases (detail below).
2. **6.2** — adds each node's static plain-service listener entry, so
   RMAN can connect before an instance is open (no `_DGMGRL` entry yet —
   `known-risks.md` #135).
3. **6.3** — proves connectivity: `tnsping` and a real authenticated
   `sqlplus` login for every alias, from every node — not just one, not
   just `run_once`.

**6.1 — TNS aliases for redo transport.** Adds 4 entries to
`{{ db_home }}/network/admin/tnsnames.ora` on all 4 nodes, leaving
NetCA/DBCA's own pre-existing `APEXDB` entry above them untouched: `apexdb`
and `apexdb_stby` (plain connect aliases), plus `apexdb_dg`/`apexdb_stby_dg`
(`UR=A` so Broker/RMAN can connect before the database is open).

**What it does, in order:**
1. Checks whether `apexdb_stby` is CRS-registered yet (`srvctl config
   database -d apexdb_stby`, delegated to the standby's own node1 — only
   usatclust2's own CRS/OCR can answer this, the primary nodes are a
   separate cluster). Reports the result before writing anything.
2. Picks the standby aliases' target from that check: the standby's own
   node1 hostname (`oradbserv09.usat.com`) if not yet registered, SCAN
   (`scan-usatclust2.usat.com`) if it is.
3. Writes the primary aliases (`apexdb`, `apexdb_dg`, always SCAN — the
   primary's been a real, CRS-registered RAC database since Phase 0) into
   their own marked block.
4. Writes the standby aliases (`apexdb_stby`, `apexdb_stby_dg`, target
   from step 2) into a **separate** marked block, so it can be
   regenerated on its own later without touching the primary block.
5. Shows the full rendered file and each block's backup path.

Real output from `oradbserv05`, from a run against a fresh, not-yet-RAC
standby (Phase 6 not yet run — the state Phase 2 is actually designed for):

```
# tnsnames.ora Network Configuration File: /u01/app/oracle/product/12.2.0/db_1/network/admin/tnsnames.ora
# Generated by Oracle configuration tools.

# BEGIN Primary DB - Data Guard TNS aliases
apexdb =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = scan-usatclust1.usat.com)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = apexdb)
    )
  )

apexdb_dg =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = scan-usatclust1.usat.com)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = apexdb)
      (UR = A)
    )
  )
# END Primary DB - Data Guard TNS aliases

# BEGIN Standby DB - Data Guard TNS aliases
apexdb_stby =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oradbserv09.usat.com)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = apexdb_stby)
      (UR = A)
    )
  )

apexdb_stby_dg =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oradbserv09.usat.com)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = apexdb_stby)
      (UR = A)
    )
  )
# END Standby DB - Data Guard TNS aliases
```

This is the target output Phase 2 should always produce when it runs
**before** Phase 6 — node hostname, not SCAN, because SCAN dynamic
registration genuinely doesn't resolve a not-yet-CRS-registered
`apexdb_stby` at this point, and using the node hostname here is exactly
what avoids downstream TNS resolution failures during Phase 3/4 (RMAN's
`AUXILIARY` connection).

Landed identically on all 4 nodes (`oradbserv05`, `oradbserv06`,
`oradbserv09`, `oradbserv10` all showed the same two managed blocks — the
two standby nodes' files didn't have the pre-existing `APEXDB` entry, since
NetCA never ran there, but the managed blocks themselves matched exactly).

**The standby block doesn't stay this way forever — see `known-risks.md`
#134.** Once Phase 6 (`dataguard_convert_rac`) has actually run and
`apexdb_stby` is a genuine, CRS-registered, dynamically-PMON-registered
2-node RAC database. Then it will be updated to use scan.


**6.2 — Static listener entry, plain service only.**

**What it does, in order:**

1. Greps the target `listener.ora` for any *pre-existing*
   `SID_LIST_LISTENER` stanza — fails loudly if one exists that isn't this
   role's own managed block.
2. Writes the single-`SID_DESC` block (plain service, no `_DGMGRL` —
   `known-risks.md` #135).
3. Reloads the listener, only if the file actually changed.
4. Verifies via `lsnrctl services` that the plain service is registered.

Real output, all 4 nodes, confirming the cluster-agnostic `nodes`-index SID
resolution and the `dg_local_db_unique_name` group_vars redirection
(`grid_silent_install`/`dataguard_primary_prep`'s same pattern) both worked
correctly, GI's own agent-managed lines left untouched above the block:

```
oradbserv05: SID_DESC (GLOBAL_DBNAME = apexdb,      ORACLE_HOME = .../db_1, SID_NAME = apexdb1)
oradbserv06: SID_DESC (GLOBAL_DBNAME = apexdb,      ORACLE_HOME = .../db_1, SID_NAME = apexdb2)
oradbserv09: SID_DESC (GLOBAL_DBNAME = apexdb_stby, ORACLE_HOME = .../db_1, SID_NAME = apexdb1)
oradbserv10: SID_DESC (GLOBAL_DBNAME = apexdb_stby, ORACLE_HOME = .../db_1, SID_NAME = apexdb2)
```

**6.3 — Connectivity test.** Originally only ran `tnsping` + the `sqlplus`
login `run_once`, from whichever node happened to run first
(`oradbserv05`)

📸 *Screenshot: tnsping05_dataguard_net_config.png.*
📸 *Screenshot: tnsping06_dataguard_net_config.png.*
📸 *Screenshot: tnsping09_dataguard_net_config.png.*
📸 *Screenshot: tnsping10_dataguard_net_config.png.*

**Confirmed with the real password** (`-e sys_password='<redacted>'`): all 4 nodes
(`oradbserv05`, `06`, `09`, `10`) connected successfully through both
`apexdb` and `apexdb_dg`

📸 *Screenshot: dataguard_net_config.png.*

**Phase 3 — Prepare the standby host (built, run for real, fully green):**
role [`dataguard_standby_prep`](../phase-01-foundation-2node-rac-12cR2/ansible/roles/dataguard_standby_prep/tasks/main.yml),
SOP section 7 — everything RMAN `DUPLICATE ... FOR STANDBY FROM ACTIVE
DATABASE` (Phase 4) needs to connect to `oradbserv09` as its `AUXILIARY`
target: a pfile derived from the primary's own spfile, the primary's real
password file copied into the $ORACLE_HOME/dbs/orapw$ORACLE_SID, and the `apexdb1` auxiliary
instance started there in `NOMOUNT`. 

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags dataguard_standby_prep
```
**What it does, in order:**

1. **7.1** — creates a pfile from the primary's spfile, strips
   RAC/primary-instance-specific parameters, sets `db_unique_name` and
   the broker file paths, then pauses for review before touching
   `oradbserv09`.
2. **7.2** — copies the primary's real password file into
   `$ORACLE_HOME/dbs/orapw$ORACLE_SID` on the standby (`orapwd` kept as
   an explicit fallback).
3. **7.3** — starts the `apexdb1` auxiliary instance on `oradbserv09` in
   `NOMOUNT`, idempotency-checked first (`ORA-01034` means not started
   yet, proceed).

**7.1 — Create and edit the pfile.** `create pfile='.../initapexdb.ora'
from spfile` against the primary (`oradbserv05`), real output:

```
SQL> create pfile='/u01/app/oracle/staging/standby/initapexdb.ora' from spfile;

File created.
```
Real final pfile,
confirmed via the role's own review dump before the pause below:

```
*.audit_file_dest='/u01/app/oracle/admin/apexdb/adump'
*.cluster_database=false
*.control_files='+DATA01/APEXDB/CONTROLFILE/current.266.1241123475','+RECO01/APEXDB/CONTROLFILE/current.256.1241123475'
*.db_name='apexdb'
*.db_unique_name=apexdb_stby
*.dg_broker_config_file1='+DATA01/apexdb/DG/dr1apexdb.dat'
*.dg_broker_config_file2='+RECO01/apexdb/DG/dr2apexdb.dat'
*.dg_broker_start=TRUE
*.fal_server='apexdb_stby'
*.log_archive_config='dg_config=(apexdb,apexdb_stby)'
*.log_archive_dest_1='location=use_db_recovery_file_dest valid_for=(all_logfiles,all_roles) db_unique_name=apexdb'
*.log_archive_dest_2='service=apexdb_stby_dg async valid_for=(online_logfiles,primary_role) db_unique_name=apexdb_stby'
*.remote_login_passwordfile='exclusive'
*.standby_file_management='AUTO'
```

Then an interactive **pause for review** (Ansible's own `pause:` module,
mid-run, not a separate manual step) — this is the first real database
instance ever started on `usatclust2`, worth a look before it happens:


Review the edited pfile above (RAC/primary-instance-specific parameters
stripped, cluster_database=false forced, db_unique_name set to
apexdb_stby, dg_broker_config_file1/2 set to +DATA01/apexdb/DG and
+RECO01/apexdb/DG). Press Enter to continue: copy it + the primary's
password file to oradbserv09 and start the apexdb1 auxiliary instance
there in NOMOUNT. Ctrl+C then A aborts this run instead.


**7.2 — Password file.** Copy the primary's ASM password file to $ORACLE_HOME/dbs/orapw$ORACLE_SID.


Confirmed: `select * from v$pwfile_users;` populated immediately.

```bash
# On oradbserv05 (primary), as grid:
asmcmd pwget --dbuniquename apexdb
asmcmd pwcopy +DATA01/APEXDB/PASSWORD/pwdapexdb.261.1241123369 /u01/app/oracle/staging/standby/orapwdapexdb

# scp to the standby, same orapw$ORACLE_SID path as before, then fix ownership:
scp /u01/app/oracle/staging/standby/orapwdapexdb oradbserv09:/u01/app/oracle/product/12.2.0/db_1/dbs/orapwapexdb1
chown oracle:oinstall /u01/app/oracle/product/12.2.0/db_1/dbs/orapwapexdb1
```

`orapwd` is kept, not deleted — an explicit fallback, selectable via
`ansible-playbook -i inventory/hosts.ini site.yml --tags -e dg_pwfile_method=orapwd`, in case the copy approach can't run in some
environment. 

```
orapwd file=/u01/app/oracle/product/12.2.0/db_1/dbs/orapwapexdb1 password=<sys_password> entries=10 format=12
```

**7.3 — Start the auxiliary instance in `NOMOUNT`.** Idempotency check
first (`v$instance.status`; `ORA-01034` means not started, proceed) —
real output confirmed a clean starting point:

Then `startup nomount pfile='.../initapexdb.ora'`, real output:

```
SQL> startup nomount pfile='/u01/app/oracle/staging/standby/initapexdb.ora';
ORACLE instance started.

Total System Global Area 3674210304 bytes
Fixed Size                  8627152 bytes
Variable Size             838863920 bytes
Database Buffers         2818572288 bytes
Redo Buffers                8146944 bytes
```

Final confirmation, `v$instance.status = STARTED` — `apexdb1` is up on
`oradbserv09`, `NOMOUNT`, ready for Phase 4 to connect to as its
`AUXILIARY` target.


Full real run, both `PLAY RECAP`s clean:
`localhost ok=36 changed=11 failed=0 skipped=3`,
`oradbserv05/06/09/10 ok=3 changed=0 failed=0` each.

📸 *Screenshot: dataguard_standby_prep.png.*

**Phase 4 — RMAN `DUPLICATE ... FOR STANDBY FROM ACTIVE DATABASE` (built
from the SOP's section 8, run for real — completed, but not cleanly):**
role
[`dataguard_duplicate`](../phase-01-foundation-2node-rac-12cR2/ansible/roles/dataguard_duplicate/tasks/main.yml),
runs entirely on `oradbserv09` — RMAN connects `TARGET`/`AUXILIARY` outbound
over the `apexdb`/`apexdb_stby` TNS aliases Phase 2 already built, so no
cross-host file staging is needed the way Phase 3 needed it.

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags dataguard_duplicate -e sys_password='...'
```
**What it does, in order:**

1. Writes the RMAN cmdfile below; pauses for review.
2. Runs `DUPLICATE ... FOR STANDBY FROM ACTIVE DATABASE` (TARGET =
   primary, AUXILIARY = the `NOMOUNT` instance Phase 3 started).
3. Confirms the standby's role/state (8.3.1).
4. Pauses again, then starts managed recovery (8.3.2).
5. Forces redo generation on the primary so there's something to ship
   (8.3.3).
6. Verifies transport/apply status on the standby (8.3.4).
7. Checks the primary's own archive-destination status (8.3.5) — real
   output and the gap that step originally exposed are below.

Real RMAN cmdfile (`{{ staging_dir }}/sql/dg_duplicate.rman` on
`oradbserv09`) — password redacted here and in the repo, per
`known-risks.md` #45:

```
connect target sys/****@apexdb
connect auxiliary sys/****@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=192.168.56.184)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SID=apexdb1)))
run {
  allocate channel c1 type disk;
  allocate channel c2 type disk;
  allocate auxiliary channel a1 type disk;
  allocate auxiliary channel a2 type disk;
  duplicate target database
    for standby
    from active database
    dorecover
    spfile
      set db_unique_name='apexdb_stby'
      set db_create_file_dest='+DATA01'
      set db_create_online_log_dest_1='+DATA01'
      set db_create_online_log_dest_2='+RECO01'
      set db_recovery_file_dest='+RECO01'
      set db_recovery_file_dest_size='7368m'
      set control_files='+DATA01','+RECO01'
      set cluster_database='false'
      set audit_file_dest='/u01/app/oracle/admin/apexdb/adump'
      set fal_server='apexdb'
      set log_archive_config='dg_config=(apexdb,apexdb_stby)'
      set log_archive_dest_1='location=use_db_recovery_file_dest valid_for=(all_logfiles,all_roles) db_unique_name=apexdb_stby'
      set log_archive_dest_2='service=apexdb_dg async valid_for=(online_logfiles,primary_role) db_unique_name=apexdb'
      set standby_file_management='auto'
      set dg_broker_start='true'
      set dg_broker_config_file1='+DATA01/apexdb/DG/dr1apexdb.dat'
      set dg_broker_config_file2='+RECO01/apexdb/DG/dr2apexdb.dat'
    nofilenamecheck;
}
```

**Two review pauses**, not one: before `DUPLICATE` itself runs (shown with
the real `run{}` block above, password redacted), and before managed
recovery starts (James's direct call, matching Phase 3's precedent). The SOP's
own closing note — only proceed to Phase 5 once transport/apply lag are
healthy — is left as a manual gate; the role prints the real numbers, not
an automated pass/fail.

📸 *Screenshot: dataguard_duplicate_completed.png.*

**8.3.1 — Confirm standby role/state**, real output right after `DUPLICATE`
finished:

```
SQL> select name, db_unique_name, database_role, open_mode, switchover_status from v$database;

NAME       DB_UNIQUE_NAME  DATABASE_ROLE     OPEN_MODE       SWITCHOVER_STATUS
---------- --------------- ----------------- --------------- --------------------
APEXDB     apexdb_stby     PHYSICAL STANDBY  MOUNTED         NOT ALLOWED

SQL> select process, status, thread#, sequence#, block#, blocks from v$managed_standby;

PROCESS  STATUS          THREAD#  SEQUENCE#     BLOCK#     BLOCKS
-------- ------------ ---------- ---------- ---------- ----------
ARCH     CONNECTED             0          0          0          0
DGRD     ALLOCATED             0          0          0          0
DGRD     ALLOCATED             0          0          0          0
ARCH     CONNECTED             0          0          0          0
ARCH     CONNECTED             0          0          0          0
ARCH     CONNECTED             0          0          0          0
```

`DATABASE_ROLE=PHYSICAL STANDBY`, `OPEN_MODE=MOUNTED` — DUPLICATE landed
correctly. No `MRP` process listed yet, expected: managed recovery hasn't
started.

**8.3.2 — Start managed recovery** (check first, then start):

```
SQL> select process, status from v$managed_standby where process like 'MRP%';

no rows selected

SQL> alter database recover managed standby database disconnect from session;

Database altered.

SQL> select process, status, thread#, sequence#, block#, blocks from v$managed_standby;

PROCESS   STATUS          THREAD#  SEQUENCE#     BLOCK#     BLOCKS
--------- ------------ ---------- ---------- ---------- ----------
ARCH      CONNECTED             0          0          0          0
DGRD      ALLOCATED             0          0          0          0
DGRD      ALLOCATED             0          0          0          0
ARCH      CONNECTED             0          0          0          0
ARCH      CONNECTED             0          0          0          0
ARCH      CONNECTED             0          0          0          0
MRP0      WAIT_FOR_LOG          2         28          0          0
RFS       IDLE                  0          0          0          0
RFS       IDLE                  1         54      20456          1
RFS       IDLE                  0          0          0          0
RFS       IDLE                  0          0          0          0

```

**8.3.3 — Force redo generation on the primary** (5 iterations, run from
`oradbserv05`):

```
SQL> alter system switch logfile;

System altered.

SQL> alter system archive log current;

System altered.
```

**8.3.4 — Verify transport/apply on the standby:**

```
SQL> select process, status, thread#, sequence#, block#, blocks from v$managed_standby order by process;

PROCESS  STATUS            THREAD#  SEQUENCE#     BLOCK#     BLOCKS
-------- -------------- ---------- ---------- ---------- ----------
ARCH     CONNECTED               0          0          0          0
ARCH     CONNECTED               0          0          0          0
ARCH     CONNECTED               0          0          0          0
ARCH     CONNECTED               0          0          0          0
DGRD     ALLOCATED               0          0          0          0
DGRD     ALLOCATED               0          0          0          0
MRP0     WAIT_FOR_LOG            1         31          0          0

SQL> select name, value, unit, time_computed from v$dataguard_stats where name in ('transport lag','apply lag','apply finish time');

NAME                 VALUE           UNIT                           TIME_COMPUTED
-------------------- --------------- ------------------------------ ------------------------------
transport lag                        day(2) to second(0) interval   08/16/2026 00:01:31
apply lag                            day(2) to second(0) interval   08/16/2026 00:01:31
apply finish time                    day(2) to second(3) interval   08/16/2026 00:01:31

SQL> select thread#, sequence#, applied, status from v$archived_log order by sequence# desc fetch first 10 rows only;

   THREAD#  SEQUENCE# APPLIED   STATUS
---------- ---------- --------- ----------
         1         30 YES       A
         1         29 YES       A
         1         28 YES       A
         1         27 NO        A
         2         27 NO        A
         2         26 YES       A
         2         25 YES       A
```

Read honestly, not glossed over: `transport lag`/`apply lag` came back with
a blank `VALUE` rather than a real interval, `MRP0` was sitting in
`WAIT_FOR_LOG` at sequence 31, and sequence 27 on both threads still showed
`APPLIED=NO` at the moment this was captured. Consistent with "just started,
hasn't fully caught up yet" — plausible right after `DUPLICATE`/MRP start,
but this was never re-checked later to confirm it actually settled clean.

**8.3.5 — Primary-side confirmation, and the gap that was left open here —


```
SQL> select dest_id, status, error, gap_status from v$archive_dest_status where dest_id = 2;

   DEST_ID STATUS    ERROR                                    GAP_STATUS
---------- --------- ---------------------------------------- ------------------------
         2 VALID
```

`STATUS=VALID`, no error — clean, re-checked after the fix below. This
step originally came back `STATUS=ERROR`, `ORA-12514`,
`GAP_STATUS=RESOLVABLE GAP` — the primary's `log_archive_dest_2` was
pointed at `apexdb_stby_dg`, which resolved to `scan-usatclust2.usat.com`,
and as #115 found, SCAN doesn't actually work for `apexdb_stby` at all yet:
nothing dynamically registers its service with usatclust2's SCAN listeners
until the database is CRS-registered (Phase 5, not yet run), so any
connection routed through SCAN for `apexdb_stby` was never going to
succeed regardless of timing. The original write-up here correctly
declined to guess at a root cause without evidence and flagged it as
"likely a registration delay, not confirmed" — the real cause turned out to
be more specific and more structural than that. James diagnosed and fixed
it directly: `apexdb_stby`/`apexdb_stby_dg` now connect via the standby's
own node hostname instead of SCAN, and `log_archive_dest_2` on both sides
now points at the plain `apexdb`/`apexdb_stby` aliases rather than the
`_dg`-suffixed ones. Managed recovery confirmed working end-to-end after
the fix.


## 11. 🟩 Confirmed — Remove the multiplexed standby redo log member

Rman duplicate will multiplex the SRLs. Drop them.

**This isn't just this project's own house style — it's Oracle's documented
MAA best practice, stated as a direct "do not," not a preference.** From
Oracle's MAA best-practices guidance on sizing redo log files and groups:

📸 *Screenshot: Show_baseline_SRL_members.png.*

> Best Practices for Sizing Redo Log Files and Groups
> - Use a minimum of three redo log groups: this helps prevent the log
>   writer process (LGWR) from waiting for a group to be available
>   following a log switch.
> - All online redo logs and standby redo logs are equal size.
> - Use redo log size = 4GB or redo log size >= peak redo rate x 20 minutes.
> - Locate redo logs on high performance disks.
> - Place log files in a high redundancy disk group, or multiplex log
>   files across different normal redundancy disk groups, if using ASM
>   redundancy.
>
> **Note: Do not multiplex the standby redo logs.**

*Oracle Data Guard
Concepts and Administration* on online/archived/standby redo log files;
and the MAA Best Practices area at `oracle.com/goto/maa` for the Exadata
Database Machine white paper this excerpt is drawn from.)

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags dataguard_srl_cleanup
```
**What it does, in order:**

1. Logs the current SRL member layout as a baseline.
2. Sets `standby_file_management=manual`; cancels managed recovery only
   if it's actually running, and confirms no MRP process remains before
   touching anything.
3. Generates the exact `alter database drop standby logfile member`
   statements for every `+DATA%` member (filenames are ASM-assigned,
   discovered at run time, not guessed); pauses for review.
4. Runs them, tolerating `ORA-00261` on any individual statement rather
   than stopping the whole batch; rechecks what's left.
5. If anything's still there (actively receiving redo), forces 3 log
   switches on **each** primary node (thread 1 and thread 2 land in
   different SRL groups) and retries once.
6. Restores `standby_file_management=auto` and restarts managed recovery
   either way — inside an `always:` block, so this step can't be skipped
   by an early failure.


Note: you will receive ORA-00261 error when dropping some standby redo log files because the
standby redo log on concern is being used by the transport service. To drop it, on the primary
database nodes, switch the current logfile by running the following command a few times in each
node

📸 *Screenshot: show_the_DROP_SRL_ORA-00261.png.*


---

## 12. 🟩 Confirmed — Convert the standby to RAC


```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags dataguard_convert_rac -e sys_password='...'
```

**What it does, in order:**

1. Stops managed recovery on `apexdb1`.
2. Sets `cluster_database=true` plus per-instance
   `thread`/`instance_number`/`undo_tablespace` for both `apexdb1` and
   `apexdb2` via `alter system ... scope=spfile` (both instances already
   exist physically — they came over with the primary's own datafiles/
   undo during Phase 4's `DUPLICATE`, so nothing new is created here,
   just pointed at correctly; `cluster_database` can't change without a
   restart).
3. Pauses for review — the only pause before this role commits;
   everything from here through ASM migration runs without stopping.
4. Shuts the manually-started `apexdb1` down.
5. Registers `apexdb_stby` with CRS for the first time — `srvctl add
   database -db apexdb_stby -oraclehome ... -dbname apexdb -role
   PHYSICAL_STANDBY -startoption MOUNT -policy MANUAL -diskgroup
   "DATA01,RECO01"`, plus both instances (`srvctl add instance`).
   `-dbname` matters — without it `srvctl` would default `DB_NAME` to
   `apexdb_stby` instead of the real `apexdb`; `-policy MANUAL` means CRS
   won't auto-start this database after a reboot, an operator has to
   (`known-risks.md` #119).
6. Migrates **both** the password file and the spfile into ASM as their
   own step, registered via `srvctl modify database -pwfile`/`-spfile`
   rather than passed to `add database`:
   - Password file: copies the already-verified local `orapwapexdb1`
     into `+DATA01/apexdb_stby/PASSWORD/pwdapexdb_stby`.
   - Spfile: copies the current local spfile (`asmcmd cp`, since `CREATE
     SPFILE` only supports `FROM PFILE`/`FROM MEMORY`, not `FROM
     SPFILE`) into `+DATA01/apexdb_stby/PARAMETERFILE/spfileapexdb.ora`
     (`known-risks.md` #126).
7. Creates the local `orapwapexdb2` password file on `oradbserv10` too,
   copied from the primary's own ASM — same `copy_from_primary` default
   Phase 3/4 use (`known-risks.md` #116), kept alongside the new ASM
   copy, not replacing it.
8. Runs `srvctl config database` and pauses for review before starting
   anything — this pause, and the instance-startup tasks themselves, are
   gated on *actual running state* (`srvctl status database`), not on
   CRS registration state, so a re-run still starts whichever instance
   is down even if registration already happened (`known-risks.md`
   #125).
9. Starts both instances in `MOUNT` via `srvctl` — CRS-managed from this
   point on, not manual `sqlplus startup`.
10. Restarts managed recovery; re-runs Phase 4's own 8.3.4 verification
    query so transport/apply status is confirmed with both instances up.

Static listener entries for `apexdb2` on `oradbserv10` already exist —
Phase 2's `dataguard_net_config` built one per node, both clusters, back
when Section 9's grid configuration first ran — so nothing new is needed
there. `audit_file_dest` on `oradbserv10` was also already created, by
Phase 3's own fix for `known-risks.md` #100 (that fix explicitly covered
both standby nodes, not just the one Phase 3 starts an instance on).

**Deliberately not using `rconfig`** — Oracle's documented `rconfig`
XML-based converter targets a plain single-instance *primary* database, not
a physical standby.


**Confirmed clean end-to-end**: both `apexdb1` and `apexdb2` start via
`srvctl` in `MOUNT`, managed recovery restarts and shows `MRP0
APPLYING_LOG` on both instances.


```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags dataguard_net_config
```
**What it does, in order:**

1. Detects `apexdb_stby`'s CRS registration.
2. Switches `apexdb_stby`/`apexdb_stby_dg` from the standby node1
   hostname to `scan-usatclust2.usat.com` on all 4 nodes, restoring
   genuine RAC-level redo-transport failover — without it, killing either
   standby node breaks redo shipping outright instead of failing over to
   the surviving node.

```
# BEGIN primary DB - Data Guard TNS aliases
apexdb =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = scan-usatclust1.usat.com)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = apexdb)
    )
  )

apexdb_dg =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = scan-usatclust1.usat.com)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = apexdb)
      (UR = A)
    )
  )

# End Primary DB  - Data Guard TNS aliases

# Begin Standby DB - Data Guard TNS aliases
apexdb_stby =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = scan-usatclust2.usat.com)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = apexdb_stby)
          (UR=A))
    )
  )

apexdb_stby_dg =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = scan-usatclust2.usat.com)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = apexdb_stby)
      (UR = A)
    )
  )

# End Standby DB - Data Guard TNS aliases
```

---

## 13. 🟩 Confirmed — Role-based services (`apexdb_rw`/`apexdb_ro`)
Phase 8 (see `known-risks.md` #136 for how that's determined)

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags dataguard_role_services
```

**What it does, in order:**

1. Preflights that both `apexdb` and `apexdb_stby` are registered and
   reachable via `srvctl`.
   ```
   # -- On Primary
   $ srvctl config database -d apexdb
   
   # -- On Standby
   $ srvctl config database -d apexdb_stby
   ```
2. Queries each database's **real, current role** via SQL — never
   assumed, so a re-run after a future switchover still gets this right.
   ```
   SQL> set echo on heading off feedback off linesize 200 pagesize 0 tab off
   SQL> select database_role from v$database;
   ```
3. Checks whether `apexdb_rw`/`apexdb_ro` are already registered on each
   database.
   ```
   SQL> SELECT name, network_name FROM dba_services WHERE name in ('apexdb_ro','apexdb_rw');
   ```
4. Reports the full plan (role, what's missing, what will start/stop) and
   pauses for review.
5. Adds `apexdb_rw` (`-role PRIMARY`) and `apexdb_ro`
   (`-role PHYSICAL_STANDBY`) wherever missing — `-preferred
   apexdb1,apexdb2 -policy AUTOMATIC -notification TRUE -clbgoal SHORT
   -rlbgoal SERVICE_TIME` on both.
   ```
   $ srvctl add service -db apexdb -service apexdb_rw -preferred apexdb1,apexdb2 -role PRIMARY -policy AUTOMATIC -notification TRUE -clbgoal SHORT -rlbgoal SERVICE_TIME
   $ srvctl add service -db apexdb -service apexdb_ro -preferred apexdb1,apexdb2 -role PHYSICAL_STANDBY -policy AUTOMATIC -notification TRUE -clbgoal SHORT -rlbgoal SERVICE_TIME
   ```
6. **Mandatory primary bootstrap:** `srvctl add service` only registers a
   CRS resource — it does *not* create the `dba_services` row, and
   `-policy AUTOMATIC` doesn't retroactively start a service against an
   already-running instance. So, before touching the standby at all: starts
   both `apexdb_rw` and `apexdb_ro` on the **primary**, verifies both now
   exist in `apexdb`'s `dba_services` (hard fail if not), then stops
   `apexdb_ro` again (`apexdb_rw` stays running). Gated on the
   `dba_services` check, so repeat runs skip straight past this once it's
   succeeded.
   ```
   $ srvctl start service -db apexdb -service apexdb_ro
   $ srvctl start service -db apexdb -service apexdb_rw
   $ srvctl stop service -db apexdb -service apexdb_ro
   ```
7. **Standby-only precondition, both instances:** checks `apexdb_stby`'s
   real `OPEN_MODE` (`gv$database`, all instances). If it isn't already
   `READ ONLY WITH APPLY` everywhere — cancels any current recovery, issues
   `ALTER DATABASE OPEN READ ONLY` **against each standby instance
   individually** (`oradbserv09`/`apexdb1` and `oradbserv10`/`apexdb2` —
   one instance opening can make the other's control-file row misleadingly
   *appear* open before it's actually completed its own transition), *then*
   restarts real-time apply (`USING CURRENT LOGFILE DISCONNECT FROM
   SESSION`) and verifies `MRP`/`RFS` (`gv$managed_standby`). Open must
   come before the apply restart, not after — opening a standby silently
   kills whatever managed-recovery process was running before it, so
   restarting apply first just gets thrown away the moment the open runs.
   Hard fail if it still isn't `READ ONLY WITH APPLY` on every instance
   afterward.
8. Starts whichever service matches each database's real role, stops the
   other — only where the current running state doesn't already match.
9. **ORA-44304 fallback, reactive:** if `apexdb_ro`'s start on the standby
   still fails (shouldn't normally, now that step 6 guarantees it exists on
   the primary), forces one more log-switch push on the primary and retries
   the standby's start up to 3 times, 20 seconds apart.
   ```
   SQL> set echo on heading off feedback off linesize 200 pagesize 0 tab off
   SQL> alter system archive log current;
   SQL> alter system switch logfile;
   ```
10. Shows final `srvctl config service` and `srvctl status service` output
    for both databases.
	```
	$ srvctl config service -d apexdb -s apexdb_rw
	$ srvctl config service -d apexdb -s apexdb_ro
	$ srvctl status service -d apexdb -s apexdb_rw
	$ srvctl status service -d apexdb -s apexdb_ro
	```

---

Continue to **[Part 2 — Broker, Fast-Start Failover, and Observer](part2-broker-fsfo-observer.md)**.
