# Known risks and gotchas — read before running anything

Written up front, deliberately, because a showcase post with no friction in it reads as
marketing rather than experience. These are the risks and non-obvious gotchas known at
design time for this Oracle Linux 7 build; the "what went wrong" section of each phase's
eventual showcase post should capture what actually happened on top of this.

## 1. Oracle Linux 7 is right for this phase and Phase 2 — but not for the 26ai upgrade later

Oracle Linux 7 is the deliberate OS choice here. Both halves of this phase's software
stack are natively certified on it: Grid Infrastructure 19c (19.3 base + RU 19.24) and
Oracle Database 12.2.0.1 have each been certified on Oracle Linux/RHEL 7.x since well
before OL8 existed, so there's no OS-detection workaround or version-mismatch tax to pay
here the way there would be on a newer platform.

**The gap to plan for, not solve now:** Oracle AI Database 26ai's Grid Infrastructure
Installation Guide lists only OL8, OL9, and OL10 (plus matching RHEL/SLES) as supported
x86-64 platforms — OL7 isn't on it at all. This phase and Phase 2 (Data Guard broker,
GoldenGate — still 12c/19c-era) run cleanly on OL7. Before the 19c→26ai upgrade phase
later in the roadmap, this project will need an OS migration for both RAC nodes (OL7 →
OL8, OL9, or OL10) — the same golden-image-and-clone mechanics already built here
(`docs/golden-image-and-cloning.md`) apply directly to that migration, it's just a
future run of the same playbook against new base images. Budget a dedicated step for
this before starting that phase; it isn't automated or scheduled yet.

## 2. Grid Infrastructure 19c + Database 12.2.0.1 — an intentional, independent-version design

The clusterware layer (GI) and the database layer (RDBMS) are installed at different,
independently-certified versions on purpose, not by accident or workaround. Oracle
explicitly supports running an older database home on newer clusterware — GI and DB
homes are fully independent; this is a documented, normal pattern, not a compatibility
hack.

**Why this project does it this way:** it front-loads the clusterware onto the release
line the roadmap ends up on anyway, while keeping the database layer at 12.2.0.1 for a
real, demoable 12c→19c *database* upgrade later (Phase 3), using `AutoUpgrade` /
`dbupgrade`. If GI were built at 12.2.0.1 too, the later "upgrade to 19c" phase would
need to upgrade both layers together instead of showcasing the database upgrade path on
its own.

`grid_home` (`/u01/app/grid/19.3.0`) and `db_home` (`/u01/app/oracle/product/12.2.0/db_1`)
are separate top-level paths — see #3 for why that separation also avoids an installer
directory-nesting check.

## 3. Shared `ORACLE_BASE`, separate `GRID_HOME` — a directory-layout decision worth understanding, not just copying

`grid` and `oracle` share the same `ORACLE_BASE` (`/u01/app/oracle`) — both are members
of `oinstall`; `os_prep` creates it `oracle:oinstall`, mode `2775` (setgid) so `grid` can
write into it too. `grid_home` (`/u01/app/grid/19.3.0`) is a **separate top-level path**,
not nested anywhere under that shared base. This matters because Oracle's installer
enforces a real prereq check — "Grid home must not be under an Oracle base directory"
(`INS-32022`/`INS-32026`) — that a nested layout would trip. Keeping `grid_home` outside
`oracle_base` entirely means that check simply doesn't apply here, by construction, not
as an accepted risk.

**Central inventory ownership:** whichever OS user performs the *first* Oracle software
install on a host owns `oraInventory` (Oracle's own documented behavior, not
project-specific). In this project's build order, GI installs before the database layer,
and `grid` is the user that runs `gridSetup.sh` first — so `inventory_loc`
(`/u01/app/oraInventory`) is owned `grid:oinstall`, mode `2775` (setgid, so `oracle`'s
later database install can still write into the same central inventory group-writably).
Getting this backwards produces `[INS-32039]` "Inappropriate file permissions for the
specified inventory location" partway through a real `gridSetup.sh` run.

## 4. ASMLib — classic v2 packages, and why ASM disk paths use `/dev/disk/by-label/`, not `/dev/oracleasm/disks/`

This project uses classic ASMLib v2 — a real `kmod-oracleasm` kernel module, a real
`oracleasmfs` mount at `/dev/oracleasm`, real `/dev/oracleasm/disks/<LABEL>` device
nodes. `kmod-oracleasm` and `oracleasm-support` are natively on OL7's public yum
channels; `oracleasmlib` is NOT reliably there — see #21 for the correction. Two
competing kernel-module packages exist in principle: `kmod-oracleasm` (for the UEK
kernel) vs. `kmod-redhat-oracleasm` (for the Red Hat Compatible Kernel) — installing
both conflicts. This project runs Oracle Linux's default UEK, so `kmod-oracleasm` is
the correct one.

**Even though `/dev/oracleasm/disks/<LABEL>` is available, `grid_install.rsp.j2` and
this project's `asmca` calls deliberately use `/dev/disk/by-label/<LABEL>` instead** —
a generic, ASMLib-version-agnostic udev mechanism. The reason: raw `/dev/sdX` device
letters for the same physical shared disk can genuinely differ between the two RAC
nodes at attach/clone time (VirtualBox doesn't guarantee identical enumeration order
across VMs) — confirmed directly on this project's own nodes, where the same
`ASMDISK02` label showed up as `/dev/sde1` on one node and `/dev/sdg1` on the other, at
the same moment. `by-label` resolves to the correct physical disk regardless of which
raw device name the kernel happened to assign it, on either node — a real problem
worth designing around from the start rather than hand-waved as unlikely.

## 5. ASM device list can collide with the `/u01` disk if the device list isn't confirmed against `lsblk` first

`oracleasm createdisk` writes a label directly onto a raw block device — the wrong
device here is data loss (the root disk, `/u01`), not just a failed task. The device
paths in `asmlib_disks` (`group_vars/all.yml`) are placeholders until confirmed on the
actual node — `/dev/sdX` letters depend on attach order at VM build/clone time (see #4).
Two independent guards run before anything destructive in the `asmlib_disks` role: the
path must exist, AND it must not already carry a partition table, filesystem, or
mountpoint. Confirm the real, free shared-disk device paths with `lsblk` before running
the disk-marking tag (`--tags asmlib_disk_marking`) on a new build — don't trust the
placeholder values in `group_vars/all.yml` as-is.

## 6. SSH equivalence for `grid`/`oracle` must exist BEFORE `cluvfy` or `gridSetup.sh` run — silent hang otherwise, not a clean error

Grid Infrastructure's `cluvfy` (and `gridSetup.sh`/`config.sh` themselves, which shell
out to `cluvfy` internally) require passwordless SSH between both software owner
accounts (`grid`, `oracle`) across both nodes, including to themselves, before any of
these commands are run. Without it, the command **hangs with zero output**, indefinitely
— it does not fail fast or print a clear error pointing at SSH. This is easy to miss
because everything up to this point (OS baseline, package installs, ASM disk marking)
succeeds normally; the hang only surfaces once GI verification actually starts.
`ssh_equivalence` must run, and be confirmed working in both directions for both users,
before touching `grid_infrastructure`.

## 7. `cluvfy` prereqs that don't come from any package install — `cvuqdisk` and `NOZEROCONF`

Two `cluvfy stage -pre crsinst` failures that a stock OS baseline won't satisfy on its
own, both worth automating rather than discovering live:

- **`cvuqdisk`** (`PRVG-11550` "Package cvuqdisk is missing") — cluvfy's own
  ASM-discovery helper package. It isn't part of any OS package list; it ships only
  inside the GI media itself, under `$GRID_HOME/cv/rpm/`, and has to be installed from
  there explicitly on both nodes.
- **`NOZEROCONF`** (`PRVE-10077` "NOZEROCONF parameter was not specified or was not set
  to 'yes'") — zeroconf's `169.254.0.0/16` link-local auto-addressing can collide with
  the address range Oracle Clusterware uses internally for its own link-local HAIP/
  interconnect addressing. `cluvfy` checks `/etc/sysconfig/network` for a literal
  `NOZEROCONF=yes` line directly — neither the line being absent nor set to `no`
  satisfies it.

## 8. Review the `cluvfy` result before letting the run continue into `-applyRU`/`gridSetup.sh`

`cluvfy stage -pre crsinst` commonly reports warnings (swap size, RPM version
suggestions) that don't actually block a real install — treating every non-zero exit as
fatal would stop working runs unnecessarily. But a genuine `PRVF`/`PRVG` **FAIL** falling
through silently into `gridSetup.sh` wastes a much more expensive, much less reversible
step. This project's `grid_silent_install` role pauses explicitly after every `cluvfy`
run — on both a clean pass and a real failure — so the actual result gets looked at
deliberately each time, not rubber-stamped. Worth keeping this habit even outside
Ansible: read the actual `PRVF`/`PRVG` codes and their `Severity` before proceeding, not
just the overall pass/fail line.

## 9. Voting disks and GIMR — redundancy is a single-diskgroup property, not something you can mix and match across diskgroups

Two things worth understanding before picking ASM redundancy levels, not after hitting a
confusing `crsctl` error:

- **OCR** can be multiplexed across multiple diskgroups (`ocrconfig -add +DATA02`, for
  example) — real redundancy, straightforward.
- **Voting disks work differently.** `crsctl replace votedisk` targets exactly ONE
  diskgroup at a time; the number of voting files Oracle creates is dictated entirely by
  that diskgroup's own redundancy (`EXTERNAL` = 1 file, `NORMAL` = 3 failure groups,
  `HIGH` = 5). There's no "vote #1 in DATA01, vote #2 in DATA02" configuration — Oracle
  doesn't support spanning voting files across separate diskgroups. Getting more than
  one voting file requires `NORMAL`/`HIGH` redundancy on a single diskgroup (which in
  turn requires that many disks in that one diskgroup), not "spanning."

This project's `DATA01` (the diskgroup created at GI install time, the only one that can
host voting files at that point) runs `NORMAL` redundancy across 3 disks/failure
groups — a deliberate choice to demonstrate the quorum mechanism for the certification
showcase, even on a single physical host where the underlying storage redundancy is
largely theoretical. `DATA02`/`RECO` (created afterward via `asmca`, once the cluster is
up) run `EXTERNAL` — no failure-group requirement, appropriate since neither hosts
voting files. GIMR (Grid Infrastructure Management Repository / `MGMTDB`) is disabled in
this build (`configure_gimr: false`) — a lab-scale resource tradeoff, not a technical
requirement either way.

## 10. `grid_install.rsp` — response-file fields worth getting right the first time

A handful of response-file fields are easy to get wrong in ways that don't fail until a
real `config.sh`/`gridSetup.sh` run, sometimes with error messages that don't obviously
point back at the field itself:

- **`oracle.install.crs.config.networkInterfaceList`** — each NIC entry needs a `type`
  value: `1=PUBLIC`, `2=PRIVATE`, `3=DO NOT USE`, `4=ASM`, `5=ASM & PRIVATE`. With
  `FLEX_ASM_STORAGE` (the default storage option for a fresh install) and no dedicated
  ASM network, the private interconnect NIC needs type `5`, not `2` — type `2` alone
  produces `[FATAL] [INS-41208]` "None of the available network subnets is marked for
  use by Oracle Automatic Storage Management (ASM)" at `config.sh` time, since nothing
  is marked for ASM at all.
- **`oracle.install.asm.diskGroup.disksWithFailureGroupNames`** — required (a flat,
  alternating `disk1,FGName1,disk2,FGName2,...` list) for `NORMAL`/`HIGH` redundancy;
  must be **omitted entirely** for `EXTERNAL`. This project derives one failure group
  per disk (`FG_<label>`) directly from the disk list, so there's no separate name list
  to keep in sync by hand.
- **`ORACLE_HOME`** — worth setting explicitly to `{{ grid_home }}` even though some
  response-file guidance treats it as implied; a real OUI-saved response file from a
  successful interactive run includes it explicitly.
- **ASM disk paths and `diskDiscoveryString`** — both should point at
  `/dev/disk/by-label/*`, not `/dev/oracleasm/disks/*` — see #4 for why.

## 11. Private interconnect needs the exact same VirtualBox internal network NAME string on both VMs

The private interconnect NIC uses a VirtualBox Internal Network (`intnet`) — this is a
**host-side VirtualBox setting** (`VBoxManage modifyvm --intnet3 "intnet"`), not
something the guest OS or Ansible controls. If the internal network name string doesn't
match *exactly* between both VMs (a typo, or a name picked independently when building
each VM rather than cloning), the private interconnect has **no connectivity at all**
between the nodes — not degraded, not slow, simply absent — while every other check
(public network, SSH, DNS) looks completely normal. Confirm with
`VBoxManage showvminfo <vm> --machinereadable | grep -E "nic3|intnet3|cableconnected3"`
on both VMs and diff the output before assuming the network layer is fine just because
`ping`/`ssh` work on the public NICs.

## 12. SCAN name resolution — `/etc/hosts` can silently shadow BIND's real round-robin answer

Two related gotchas worth knowing before troubleshooting a "SCAN only resolves to 1 IP"
symptom (`PRVG-11368`/`PRVG-11826`/`PRVF-4664`):

- Default `/etc/nsswitch.conf` order is `files` (`/etc/hosts`) before `dns`. If
  `/etc/hosts` has a SCAN entry at all, it wins over BIND's real 3-IP answer for
  **every** normal name resolution on that host (`cluvfy`, `gridSetup.sh`, `sqlnet`) —
  only a `dig`/`nslookup` run directly against the nameserver bypasses `/etc/hosts` and
  shows the correct 3-IP answer, which is exactly why this can look fine in isolation
  and only fail inside the actual installer. This project's `hosts.j2` template lists
  **all** `scan_ips` (not just one), templated from the same list `dns_bind` serves, so
  the two can't drift out of sync — but a hand-edited `/etc/hosts` with a single SCAN IP
  is a real, easy way to reintroduce this.
- Linux does **not** round-robin multiple `/etc/hosts` entries for the same name by
  default (glibc returns them in file order every time, unlike DNS). This matters less
  in practice than it sounds — SCAN's actual client load-balancing happens at the SCAN
  listener protocol layer once a connection reaches any of the 3 listeners, not purely
  from which IP a client's resolver happened to pick first.

Separately: BIND's own SCAN zone serial must increment on every real zone-file change,
not stay hardcoded — a static serial can cause a secondary/cached resolver to keep
serving stale VIP/SCAN data, surfacing as `[INS-40912]` "Virtual host name ... is
assigned to another system" on a later config run even though the actual assignment is
correct. This project derives the serial from `ansible_date_time.epoch` rather than a
hand-maintained number, specifically to avoid this.

## 13. `chrony` client config — `local stratum 10` is a safe fallback, not a bug to remove

A chrony client config with both a real upstream `server` line and `local stratum 10` is
a standard, safe pattern, not a contradiction — `local stratum 10` only takes effect when
nothing better is reachable; chrony's own source-selection logic always prefers a
genuinely reachable, synchronized external source over the local fallback. If
`chronyc sources` shows `Stratum 0`/`Reach 0` against the real master, look at actual
reachability (firewall, routing, whether the master's own chronyd is up) before touching
this directive — removing it doesn't fix a reachability problem and gives up a
legitimate fallback for no benefit.

## 14. Install/config/DBCA steps are expensive and not automatically safe to re-run — guarded explicitly, not assumed

`gridSetup.sh`, `config.sh`, `runInstaller`, and `dbca -createDatabase` are each
expensive, not trivially reversible, and not naturally idempotent — re-invoking one
against an already-completed target risks re-running root scripts, re-triggering
patching, or attempting to create a database that already exists. Every stage in this
project's roles checks a real, native signal before deciding whether to act — central
inventory (`inventory.xml`) for install stages, `crsctl check crs` for cluster
configuration, a direct DB-existence check for DBCA — rather than assuming a fresh run
is always safe. Worth the same discipline manually if running any of these commands by
hand outside Ansible: confirm the current state before re-issuing a command that assumes
a clean slate.

## 15. Extended support status of 12.2.0.1

12.2.0.1 has exited Premier Support and is in a limited error-correction / extended
patch window — the exact cutoff and the latest available Release Update number both need
to be checked against current My Oracle Support content at build time rather than
trusted from any doc (see `docs/patching-strategy.md`). Don't assume a patch number
referenced anywhere in this project's docs is still current without checking MOS first.

## 16. `gridSetup.sh`'s own SSH setup rejects ed25519 keys — RSA/PEM required, a different constraint than the system `ssh` binary

Oracle's `gridSetup.sh` (and `cluvfy`) use their own bundled Java SSH library for
node-to-node connectivity setup — a completely separate code path from the system
`ssh`/`sshd` binaries. This library fails to parse ed25519 keys, or modern
OpenSSH-format keys (the default `ssh-keygen` has produced since OpenSSH 7.8), even
though the system `ssh` client handles either fine for a manual `ssh grid@peer` test.
The failure surfaces as `[INS-06003]`/`PRCZ-2006`/`PRVG-11001` with a garbled
`"invalid privatekey: [B@<hash>"` message — a raw Java byte-array `toString()`,
meaning the library read *something* but couldn't decode it as a key. Generate the
`grid`/`oracle` SSH keys as RSA in legacy PEM encoding specifically
(`ssh-keygen -t rsa -b 2048 -m PEM`) rather than trusting `ssh-keygen`'s modern
defaults, even though a plain manual SSH test with a default-format key would look
completely fine.

## 17. `ansible -m ping` fails on a fresh OL7 node — `/usr/bin/python3` isn't there until something installs it

Oracle Linux 7's default system Python is 2.7 at `/usr/bin/python` — `python3` (3.6.8)
is available from the `ol7_latest` repo since OL7.7, but it is not part of a default
install. `inventory/hosts.ini` sets `ansible_python_interpreter=/usr/bin/python3` for
`rac_nodes`, so any normal Ansible module (including the ad-hoc `ping` module) fails
immediately on a brand-new node with `/bin/sh: /usr/bin/python3: No such file or
directory` — not a broken SSH/sudo setup, just a target that hasn't had `python3`
installed yet.

**Why point at `/usr/bin/python3` at all instead of just using the Python 2.7 that's
already there:** Python 2.7 has been EOL since January 2020, and recent `ansible-core`
releases have progressively dropped support for managing nodes over it — staying on
`/usr/bin/python` now is a dead end this project would have to migrate off of later
anyway, for no benefit today.

**The fix, automated:** `site.yml`'s first play (`tags: [always]`, so it runs ahead of
every other play regardless of which tags are passed) uses the `raw` module — which
executes a plain SSH command and needs no Python on the target at all — to check for
`/usr/bin/python3` and `yum install` it if missing, before any real module-based task
ever runs. This means the first real command against a fresh node should be a tagged
play (e.g. `--tags os_prep`), not a bare ad-hoc `-m ping` — the ad-hoc command has no
bootstrap play in front of it, so it still hits this on a genuinely fresh node. Use
`ansible ... -m raw -a "echo pong"` instead if a connectivity check is needed before
anything else has run.

## 18. The 19c preinstall RPM's name changed shape at 18c — it's `oracle-database-preinstall-19c`, not `oracle-database-server-19cR3-preinstall`

Oracle used `oracle-<product>-server-<version>-preinstall` (`oracle-rdbms-server-11gR2-
preinstall`, `oracle-database-server-12cR2-preinstall`) as its preinstall-RPM naming
convention through 12c — which is why the 12.2.0.1 DATABASE layer's preinstall
package (installed alongside this one, see `os_prep`) is still named that way. Starting
with 18c, Oracle switched to a flat `oracle-database-preinstall-<version>` name with no
"server" and no `RxCy` suffix — so the 19c GI layer's preinstall package is
`oracle-database-preinstall-19c`, confirmed against the actual RPM filename
(`oracle-database-preinstall-19c-1.0-3.el7.x86_64.rpm`) and natively available via yum
on OL7. Assuming the older naming pattern still applies at 18c/19c produces `No package
matching '...' found available, installed or updated` — the package genuinely doesn't
exist under that name, on any OS version, not just an OL7-specific gap.

## 19. The required/optional OL7 package lists had drifted from Oracle's actual 12.2 install-guide table

`os_prep`/`verify_baseline`'s package lists (beyond what the preinstall RPMs pull in
automatically) previously included `libnsl`, which isn't part of Oracle's 12.2
Installation Guide Table 2-4 for Oracle Linux 7 / RHEL 7 at all — `libnsl` is an
OL8/RHEL8-era requirement (glibc dropped built-in NIS/sunrpc support there); OL7's
glibc still has it built in, so there's no separate `libnsl` package on OL7 to
install, and `yum install libnsl` fails outright with `No package matching 'libnsl'
found`. The list also had plain `fontconfig` where Oracle's table actually specifies
`fontconfig-devel` (which pulls in `fontconfig` as a dependency anyway), and was
missing several required entries outright: `compat-libcap1`, `compat-libstdc++-33`,
`elfutils-libelf-devel`, `libaio-devel`, `libXrender-devel`, `libstdc++-devel`. The
optional-package list had a similar gap — `libnsl2-devel` isn't on Oracle's optional
table for OL7 either (same OL8/RHEL8-era mismatch); the real optional table is
`ipmiutil`, `libvirt-libs`, and the Oracle ACFS Remote set (`python`,
`python-configshell`, `python-rtslib`, `python-six`, `targetcli`) — `net-tools` and
`nfs-utils` are also on Oracle's optional table but this project treats them as
required (RAC/ACFS), checked separately.

Both roles' package lists are corrected to match Table 2-4 exactly now. Worth
re-verifying against the current Oracle 19c/12.2 Installation Guide before a real run
regardless — Oracle does revise these tables between guide editions, and a table
transcribed once, even carefully, is exactly the kind of fact that goes stale
silently.

## 20. Ansible's `selinux` module needs Python SELinux bindings that don't exist for Python 3 on OL7

The dedicated `selinux:` Ansible module imports the `selinux` Python library directly
on the target and fails hard (`ModuleNotFoundError: No module named 'selinux'`) if
it's missing — not a permissions or connectivity problem, the binding genuinely isn't
there. On Oracle Linux 7, those bindings only ship for Python 2, as `libselinux-python`
— there is no `python3-libselinux` (or equivalent) in OL7's base repos the way there is
on OL8/OL9. Since this project standardizes on `/usr/bin/python3` as the managed-node
interpreter (see #17), the dedicated module simply cannot run here without adding a
Python-2-only package for one task alone.

`os_prep` sets SELinux mode via `setenforce`/`/etc/selinux/config` directly instead —
plain `command`/`lineinfile`, no SELinux Python bindings required either way, and the
same mechanism Oracle's own install guides document by hand. (The target mode itself
started as permissive and later moved to fully disabled — see #26 for why; the
mechanism/module-choice reasoning here is unaffected by that later change.) Regular
file-managing modules (`copy`, `template`, `file`, `lineinfile`, etc.) don't have this
problem — they only use the SELinux bindings opportunistically to manage file context,
and degrade gracefully (skip that part, no error) when the bindings aren't importable;
it's only the dedicated `selinux` module that treats the import as mandatory.

## 21. `oracleasmlib` isn't reliably on OL7's public yum channels — and ASMLib packages now install at golden-image time, not post-clone

`kmod-oracleasm` and `oracleasm-support` are natively on OL7's public yum channels
(`ol7_latest`/UEK), but `oracleasmlib` genuinely is not — it's distributed via ULN
(needs an active support subscription) or a manual download from
oracle.com/linux/downloads, confirmed against a real `No package matching
'oracleasmlib' found` failure on a plain `yum install`. This project's earlier claim
that all three packages were natively available via yum was wrong for this one.

`os_prep`'s `install_local_oracleasmlib_rpm` (default `true`) installs it from
`oracleasmlib_local_rpm` — a path **on the managed node itself** (default
`/root/rpms/oracleasmlib-2.0.15-1.el7.x86_64.rpm`), not copied from the Ansible
control node, matching this project's actual workflow of staging manually-downloaded
RPMs under `/root/rpms` on each node before running `os_prep`. Update the path/filename
in `group_vars/all.yml` if a different build gets staged, or set the toggle `false` if
a specific environment's yum config genuinely does carry `oracleasmlib` (e.g. an
active ULN subscription channel).

**Also moved as part of this fix:** all three ASMLib packages now install in `os_prep`
(the golden image, built once on `oradbserv05` before cloning) instead of in
`asmlib_disks`. Only ASM's disk MARKING and service config genuinely have to wait for
both real nodes and the shared disks to exist (`asmlib_disks` still owns those,
unchanged) — package installation has no such dependency, so there's no reason to defer
it past the golden-image build. `verify_baseline`'s ASMLib package check is a real,
unconditional gap now rather than an expected-missing informational note.

## 22. `verify_baseline`'s 32-bit companion check contradicted its own stated intent — informational in name, but actually failing the play

The i686-companion check task is named and commented "informational" — this project
explicitly doesn't target 32-bit client support — but a previous version of the
follow-up task added every missing `.i686` package straight into `verify_failures`
anyway, so a node genuinely missing an optional 32-bit companion (common on a minimal
OL7 install without the multilib/optional channel enabled) would fail `verify_baseline`
over a package the project's own documentation says doesn't matter. Fixed to match the
OPTIONAL-package pattern used elsewhere in the same role: reported via `debug`, never
added to `verify_failures`. Also added `compat-libcap1` to the i686 check/best-effort
install list, matching Oracle's documented 12.2 package table (both architectures
where available).

## 23. `tuned`'s active profile fights the `vm.swappiness`/`vm.dirty_ratio` sysctl.d overrides — a plain sysctl.d file isn't enough on a VM

`tuned-adm recommend` picks `virtual-guest` on a VirtualBox VM by default, and that
profile sets `vm.swappiness=30` (and, via its `throughput-performance` parent,
`vm.dirty_ratio=30` too) — confirmed against a real run where `verify_baseline` caught
both values live at 30 even though `zz90-oracle-override.conf` had rendered correctly
and unchanged, targeting `5` and `40`. `tuned` actively re-applies its active profile's
own sysctl values (at service start, and Oracle's own tuned documentation describes
restarting the service specifically to re-sync "current system settings" back to the
profile) — a separate `/etc/sysctl.d` file can render correctly and still not "win" once
tuned reasserts.

**Fix:** a custom tuned profile (`/etc/tuned/oracle-db-vm/tuned.conf`) that inherits
`virtual-guest` via `include=` (keeping its readahead/other virtualization tuning) but
overrides just the `vm.*` keys this project cares about, activated via
`tuned-adm profile oracle-db-vm`. This makes tuned itself carry the target values
instead of fighting a plain file — durable across reboots and tuned restarts, unlike
relying on `sysctl.d` alone. The `sysctl.d` file keeps the same `vm.*` values too,
redundant by design (same numbers, not a conflict) as an immediate-at-boot value before
`tuned` finishes starting.

## 24. `cluvfy stage -pre crsinst` Node Connectivity failures confined to `eth0` (NAT) — not a real blocker, cause not fully isolated

A real run's Ansible-driven cluvfy call (`grid_silent_install`'s `grid_stage` block —
`runcluvfy.sh stage -pre crsinst -n <nodes> -verbose`, run as `grid` via Ansible
`become`, no `-method`/`-responseFile`) reported `Node Connectivity ...FAILED`
(`PRVG-11891`, `PRVG-11078`, `PRVG-1172`, `PRVG-11067`, `PRVG-11095`, `PRVG-11094`) —
every single one of them about `eth0` specifically: the NAT adapter's auto-assigned
IPv6 ULA address (`fd17:...`) failing TCP/ping connectivity between the two nodes, and
the NAT IPv4 address (`10.0.2.15`, identical on both VMs by VirtualBox NAT design —
each VM's NAT is host-isolated, this is normal, not an actual conflict) getting flagged
as "on multiple interfaces." `eth0` is NAT — admin/internet access only, explicitly
**not** part of this project's cluster network design (see `docs/network-and-hosts.md`
and `#11`); `grid_install.rsp`'s `networkInterfaceList` never includes it, so GI itself
will never attempt to use it for cluster communication regardless of what cluvfy
reports about it here.

A manual re-run roughly two minutes later (`runcluvfy.sh stage -pre crsinst
-responseFile grid_install_swonly.rsp -method root -verbose`) reported **zero**
connectivity failures — full clean pass. The response file used doesn't carry a
`networkInterfaceList` (it's the software-only Phase A file — see that template's own
comment), so that alone doesn't explain the difference; the two runs also differed in
privilege method (`-method root` vs. Ansible's `become_user: grid`, no explicit
`-method`) and in exact timing relative to network/interface startup. **Not fully
isolated which of these actually mattered** — flagged honestly rather than guessed at.
Best working theory: IPv6 SLAAC/Duplicate-Address-Detection settling time on the NAT
adapter's auto-assigned address, which would explain both the transience and why it's
scoped to exactly that one address.

**What to actually do about it:** this project's `grid_silent_install` role already
pauses unconditionally after every cluvfy run for exactly this kind of judgment call
(see #8) — if a future run reports failures confined to `eth0` the same way, it's safe
to proceed, since nothing about cluster formation depends on that interface. Worth a
second look only if a failure ever shows up against `eth1`/`eth2` (the real public/
private cluster subnets) instead — that would be a genuine blocker, not this.

**Separately — `-method sudo -user grid` fails outright, unrelated to the above:**
`PRCZ-2004 : File "/usr/local/bin/sudo" was not found` — cluvfy's `-method sudo` looks
for `sudo` at a hardcoded default path that isn't where OL7 actually installs it
(`/usr/bin/sudo`). Not a real prerequisite gap; `-method root` (prompts for the root
password directly) and Ansible's own grid-SSH-equivalence-based invocation (no
`-method` at all) both work fine without ever needing `-method sudo` specifically.

## 25. `gridSetup.sh`'s remote file-transfer mechanism opens random ephemeral TCP ports on the PUBLIC interface — a private-interconnect-only firewalld carve-out isn't enough

A real `gridSetup.sh` run (Phase A software install) failed with `PRCF-2087`/`PRCF-2001`
— `Connection to the remote nodes oradbserv06 refused` on a handful of high, ephemeral
ports (`14669`, `26577`, `59161`, `60039`, `45387`, `13347` — a different, essentially
random port each attempt). This is `gridSetup.sh`'s own remote-copy mechanism opening an
ad-hoc TCP listener and having the peer node connect back to it directly — over the
**public** interface (`eth1`), not just the private interconnect (`eth2`) — to transfer
GI software/files to the other node, separate from and in addition to the SSH-based
node-to-node propagation covered elsewhere in this doc.

This project's earlier `os_prep` only put `eth2` in firewalld's `trusted` zone, leaving
`eth1` filtered by the default zone's normal allowlist (`ssh`, `dhcpv6-client`, and
little else) — which silently blocks exactly this traffic, with no clear error pointing
back at firewalld specifically (`PRCF-2001` just says "refused," not "blocked by
firewall"). **Fix:** `os_prep` now disables `firewalld` entirely — a deliberate lab
convenience (same category of choice as `oracle`/`grid`'s passwordless sudo elsewhere in
this doc), not a scoped, production-appropriate rule set. Scoping to just the right
ephemeral port range on just `eth1` is possible but not worth the complexity on a
NAT-isolated single-host lab network with no other traffic to actually protect against.

If you hit this mid-run before re-applying this fix: `systemctl disable --now firewalld`
on **both** nodes, then re-run the failed step (`gridSetup.sh` directly, or
`--tags grid_infrastructure` if driving through Ansible) — no reboot needed.

## 26. SELinux moved from permissive to fully disabled — same PRCF-2087/PRCF-2001 incident as #25

The permissive-not-disabled framing this project used earlier (see #20's original task
comment) was a deliberate half-measure: permissive still labels every socket/file with
an SELinux context and logs denials, it just stops enforcing them. That turned out to be
one variable too many while chasing #25's `PRCF-2087`/`PRCF-2001` connection-refused
errors — with both SELinux and firewalld in the mix, it wasn't possible to tell from the
error alone which layer was actually refusing `gridSetup.sh`'s ephemeral-port file
transfer. Once firewalld turned out to be the real cause, the decision was made to take
SELinux out of the picture entirely too, rather than leave a second, harder-to-audit
network-facing unknown in place for the rest of this lab's build.

**Mechanics, and a caveat worth knowing:** the kernel can move from enforcing to
permissive at runtime (`setenforce 0`), but it cannot unload SELinux into a true
*Disabled* state without a reboot — that only happens as the kernel boots and reads
`/etc/selinux/config`. So `os_prep` does both: `setenforce 0` for immediate effect, and
persists `SELINUX=disabled` in `/etc/selinux/config` for the state that actually takes
hold on next reboot. Practically, this means `getenforce` will keep reporting
`Permissive`, not `Disabled`, on a node that's had `os_prep` run but hasn't rebooted
since — that's expected, not a bug. `verify_baseline` checks the persisted
`/etc/selinux/config` value rather than live `getenforce` for exactly this reason, and
separately notes (informationally, not as a failure) whether a reboot is still pending
to complete the transition.

**Why this is fine for this project specifically:** same reasoning as #25 — a
NAT-isolated, single-host VirtualBox lab with no other tenants or traffic to defend
against. This is a documented lab-convenience trade-off, not a pattern to carry into a
production build; a real deployment would keep SELinux enforcing (or at minimum
permissive with policy work to close the gaps) rather than disabling it outright.

## 27. `oracle`/`grid` login shells showed the generic `-bash-4.2$` prompt — `.bash_profile` templates never set `PS1`

Both `oracle-bash_profile.j2` and `grid-bash_profile.j2` set every Oracle environment
variable (`ORACLE_SID`, `ORACLE_HOME`, etc.) correctly, but neither ever set `PS1` — so
the shell fell back to bash's own built-in default prompt (`-bash-<version>$`), which
carries no hostname, user, or `ORACLE_SID` context. On a two-node RAC lab where it's easy
to lose track of which node/user a terminal is actually attached to, that's a real
footgun, not just cosmetic (e.g. running a `crsctl stop cluster -all` in the wrong
window).

**Fix:** both templates now set
`export PS1="\h-\u-\${ORACLE_SID}\$ "` right after the `ORACLE_SID` export, giving a
prompt like `oradbserv05-oracle-usat1$` or `oradbserv06-grid-+ASM2$`. Two details worth
knowing:
- `${ORACLE_SID}` is escaped (`\$`, not a bare `$`), so bash re-expands it fresh on every
  prompt draw rather than baking in whatever value was current when the file was
  sourced — this matters because `. oraenv` changes `$ORACLE_SID` mid-session without
  starting a new shell.
- The trailing `\$` is bash's own prompt-escape for "`#` if root, `$` otherwise" — kept
  even though `oracle`/`grid` are never root, for consistency with how most DBA prompts
  are written.

## 28. `crs/config/config.sh` run bare (no `-silent`/`-responseFile`) throws INS-42012 even though the home IS registered

After a clean Phase A (`gridSetup.sh -silent -applyRU ... CRS_SWONLY`) and both nodes'
`root.sh`, running `$GRID_HOME/crs/config/config.sh` with **no arguments** — to preview
the GUI before committing to a silent run — failed immediately with `INS-42012: The
current Grid home is not registered in the central inventory on this host`, despite
`/u01/app/oraInventory/ContentsXML/inventory.xml` showing the home correctly registered
(`OraGI19Home1` at `/u01/app/grid/19.3.0`, no `REMOVED` flag). A follow-up
`-attachHome` attempt then failed with `OUI-10197: ... Oracle Home already exists at
this location` — which is actually the reassuring half of this: it confirms the
inventory registration genuinely is intact; nothing needed re-attaching.

**Root cause:** starting at 12cR2, Oracle's configuration entry point moved from
`crs/config/config.sh` to `$GRID_HOME/gridSetup.sh` itself — this project's own
`root.sh` output already says so explicitly ("To configure Grid Infrastructure for a
Cluster execute the following command as grid user: `/u01/app/grid/19.3.0/gridSetup.sh`").
`crs/config/config.sh` still exists and is still a documented, working path for 19c, but
only when it's given everything explicitly — `-silent -responseFile <fully populated
CRS_CONFIG response file>` — which is exactly how this project's `grid_silent_install`
role invokes it (`--tags grid_configure_cluster`; see that role's `config.sh` task).
Invoked bare, with no response file and no `-silent`, OUI has to self-detect the
"current" home/session context launching the GUI wizard, and that auto-detect path is
fragile enough at 19c to throw INS-42012 even against a genuinely intact inventory.

**What to actually do:** don't run `config.sh` bare again. Either (a) let the Ansible
role's own `--tags grid_configure_cluster` step run it correctly
(`-silent -responseFile {{ staging_dir }}/response-files/grid_install.rsp`), or (b) if
you want to eyeball the wizard first, run `$GRID_HOME/gridSetup.sh` (no args, needs
X11/VNC) instead of `config.sh` — that's the actual supported GUI entry point at this
version, per root.sh's own printed instructions.

**Separately worth double-checking:** the diagnostic session also showed
`ls -lrt $GRID_HOME` (i.e. `/u01/app/grid/19.3.0`) returning **no output at all** —
which doesn't square with `root.sh` having already run successfully out of that same
tree minutes earlier. Confirm the home is actually populated
(`ls -la $GRID_HOME/bin/crsctl`) before proceeding to Phase B; if it genuinely comes up
empty, that's a bigger problem than INS-42012 and worth chasing down on its own before
retrying configuration.

## 29. Cluster-forming `root.sh` died at step 7 `CreateRootCert` (CLSRSC-147/CLSRSC-180) — don't just re-run it; deconfig first

On node 1 (`oradbserv05`), the **real** cluster-forming `root.sh` (the one config.sh
generates after Phase B configuration succeeds — 19-step `CLSRSC-594` sequence, not the
earlier Phase A software-registration `root.sh`) ran cleanly through steps 1-6
(`ValidateEnv`, `CheckFirstNode`, `GenSiteGUIDs`, `SetupOSD`, `CheckCRSConfig`,
`SetupLocalGPNP`) with no warnings, then died at step 7 `CreateRootCert`:
`Error: Can't open profile '$GRID_HOME/gpnp/oradbserv05/profiles/peer/profile.xml' for
read: file not found`, cascading into `CLSRSC-147` (twice) and then `CLSRSC-180` while
trying to *record* the failure itself — the checkpoint write
(`.../crsdata/@global/crsconfig/ckptGridHA_global.xml`) failed with `scp: ... set mode:
Operation not permitted`, and the script died in `crsutils.pm`.

**Not yet root-caused with confidence** — step 6 (`SetupLocalGPNP`) is the step that's
supposed to create that exact profile.xml, and it reported no error, so either it wrote
the file somewhere other than the path step 7 went looking for (host-name-keyed
directory naming, DNS/`/etc/hosts` inconsistency, or a permissions problem that silently
no-op'd the write), or something about `/u01/app/oracle/crsdata` ownership/permissions
made the write fail quietly. The secondary `scp ... set mode: Operation not permitted`
on the checkpoint file is consistent with a permissions problem somewhere under
`/u01/app/oracle/crsdata`, but that's circumstantial, not confirmed — genuinely worth
checking `ls -la $GRID_HOME/gpnp/` and `ls -la /u01/app/oracle/crsdata/@global/crsconfig/`
before assuming a specific cause.

**What matters more than the root cause right now:** Oracle's own documented guidance is
explicit that a failed `root.sh` should **not** just be re-run as-is — partial
GPnP/OLR/checkpoint state left behind by the failed attempt can make a second run fail
differently or worse. The documented recovery path, run as `root` on the node that
failed:

```
cd $GRID_HOME/crs/install
./rootcrs.sh -deconfig -force
```

No `-lastnode` here — that flag blanks OCR/voting and is only for the last node of an
*already-formed* cluster being fully deconfigured; nothing was actually formed yet
(the failure happened before OCR/voting were ever written), and `oradbserv06` hasn't
attempted its own cluster-forming `root.sh` yet, so nothing needs cleaning up there.
After deconfig completes cleanly on `oradbserv05`, re-run `root.sh` there — and pull the
two `ls -la` outputs above first if it fails the same way again, since that's the
evidence needed to actually pin this down rather than guess a second time.

**UPDATE — both loose ends resolved by the follow-up `ls -la` output and the deconfig
run itself:**

1. **The ownership anomaly, confirmed:** `/u01/app/oracle/crsdata/@global/crsconfig/ckptGridHA_global.xml`
   and `index.xml` are owned by `oracle:oinstall`, not `grid:oinstall` — even though the
   containing directory itself is `grid:oinstall`. This is the exact, confirmed
   explanation for the earlier `scp ... set mode: Operation not permitted`: `chmod()`
   only succeeds for a file's owner or for root; group-write permission (which `grid`
   does have here via the shared `oinstall` group) lets a non-owner edit *contents*, but
   not change *mode bits*. Something wrote those two files as `oracle` during the failed
   run — not yet confirmed *why* (a shared-`ORACLE_BASE` side effect per #3 is the
   leading theory, not confirmed) — but if the same `set mode: Operation not permitted`
   error recurs after a clean deconfig + retry, `chown -R grid:oinstall
   /u01/app/oracle/crsdata` before retrying again is the concrete fix.

2. **`CLSRSC-46`/"Unable to retrieve Oracle Clusterware home" during `-deconfig -force`
   is expected, benign noise on a node whose clusterware never actually started** — not
   a new failure. `rootcrs.sh -deconfig -force`'s early steps try to query the live
   cluster (e.g. `srvctl config nodeapps`) to figure out what to unwind; on a node where
   `root.sh` died before Clusterware ever came up, those queries have nothing to query
   and print `CLSRSC-46`/`CLSRSC-180`/`CRS-4047`/`CRS-4000` — all non-fatal — and the
   script continues on to actually deconfigure whatever partial state does exist,
   finishing with `CLSRSC-336: Successfully deconfigured Oracle Clusterware stack on
   this node` (sometimes phrased as `CLSRSC-557: ... There were some errors which can be
   ignored.`). Confirmed against a real 12.2/19c deconfig transcript showing the
   identical `CLSRSC-46` → `CLSRSC-180`/`CRS-4047` → `CLSRSC-336` sequence completing
   successfully. If your own run's output stopped exactly at "Start Oracle Clusterware
   stack and try again." without reaching a `CLSRSC-336`/`CLSRSC-557` line, let it keep
   running (or re-check with `echo $?` / re-paste the full output) before assuming it's
   stuck — don't ctrl-C it.

3. **After deconfig genuinely completes**, `CLSRSC-559` in the reference transcript is
   worth acting on directly: it explicitly says to ensure the GPnP profile data under
   `$GRID_HOME/gpnp` is deleted before reconfiguring. Confirm
   `$GRID_HOME/gpnp/oradbserv05` is actually gone once deconfig finishes; if anything's
   left over there, remove it by hand (as `grid`) before re-running `root.sh`.

## 30. `/u01` and `/u01/app` weren't owned the way Oracle actually documents them — and the old task would have fought `root.sh`'s own ownership change on every re-run

`os_prep` set `{{ u01_mount_point }}` (`/u01`) to `oracle:oinstall` unconditionally, and
never gave `/u01/app` (the shared parent of both `grid_home` and `oracle_base`) any
explicit ownership at all — it was just an accidental Ansible-created intermediate
directory, left at whatever the control node's default umask produced. Neither matches
Oracle's actual documented model, confirmed against the current 19c install guide:

- `/u01` and `/u01/app` should be **`grid:oinstall`, `0775`, before any install** — this
  is specifically what lets OUI create `/u01/app/oraInventory` in the first place (this
  project's GI layer installs first — see #3 — so `grid` is the right pre-install owner
  here too, same reasoning as `inventory_loc`'s ownership).
- **`root.sh` itself re-owns both of them to `root:oinstall`** as part of its own,
  normal, expected post-install security hardening — this is not a bug or something to
  "fix" when you see it; it's Oracle doing exactly what it's supposed to.

**Why the old task was a real problem, not just imprecise:** it forced `oracle:oinstall`
on `/u01` unconditionally, on *every single `--tags os_prep` run* — and this project has
re-run `os_prep` many times over the course of this session's troubleshooting. Any
re-run of `os_prep` *after* `root.sh` had already flipped `/u01` to `root:oinstall`
would have silently reverted that back to `oracle:oinstall` — fighting Oracle's own
installer state on a node that had already progressed past it. Not confirmed as the sole
cause of this session's chmod/`EPERM` issues (see #29), but a genuinely plausible
contributor worth ruling out, and wrong regardless of whether it's the specific cause of
any one error.

**Fix:** both `/u01` and `/u01/app` now get an explicit `stat` check first, and only get
set to `grid:oinstall` `0775` if they're **not already owned by root** — i.e., only on a
node that's still pre-install. Once `root.sh` has taken ownership, `os_prep` leaves it
alone on every subsequent run. `/u01/app/grid` (the parent of `grid_home`, previously
also just an accidental intermediate directory) now gets an explicit, unconditional
`grid:oinstall 0775` too, matching Oracle's documented value for that exact path — this
one doesn't have the same root.sh-reownership lifecycle as `/u01`/`/u01/app`, so no guard
needed. `grid_home` and `oracle_base` themselves were already correct and unaffected —
this only touches the two/three levels above them that were previously accidental or
wrong. `verify_baseline` now reports (informationally, not as a hard failure, since
either owner is legitimately correct depending on lifecycle stage) if `/u01` or
`/u01/app` end up owned by anything other than `grid` or `root`.

## 31. `db_silent_install` extracted the DB software zip into `db_home` — wrong for 12.2.0.1's actual packaging, unlike GI's zip

**The extraction TARGET described below (a separate staging directory) was superseded
by #33** — extraction now goes directly into `db_home` per explicit project direction.
The core diagnosis in this entry is still accurate and worth keeping: `runInstaller`
lives inside a `database/` subfolder the zip's packaging always creates, and the
original bug was invoking `{{ db_home }}/runInstaller` (flat, no `database/`) instead of
the correct nested path. What changed in #33 is *where* that `database/` folder ends up
(inside `db_home` now, not a separate staging directory) — the nested-path fact itself
didn't change and isn't in question.

A real `--tags db_software` run failed immediately at the `runInstaller` task:
`[Errno 2] No such file or directory: '/u01/app/oracle/product/12.2.0/db_1/runInstaller'`
— `db_home` existed (created empty by the prior task) but had no `runInstaller` in it,
despite the "Extract Database software into db_home" task immediately before having
reported success.

**Root cause: the Database 12.2.0.1 media is packaged completely differently from the
Grid Infrastructure media, and this role's software-extraction task was written as if
it followed the same convention.** `LINUX.X64_193000_grid_home.zip` (GI, and the later
`_db_home.zip`-suffixed 18c+ DB media) is packaged flat — meant to be unzipped
*directly into* an already-created, empty target home, which the zip's contents then
*become*. `linuxx64_12201_database.zip` (this project's actual DB media — confirmed by
the exact filename already in `group_vars/all.yml`) is packaged the older way: it
contains its own top-level `database/` folder holding `runInstaller` and the rest of
OUI's staging bundle, meant to be unzipped to *any* staging location and run *from
there* — `runInstaller` then copies/creates the real product files into a *separate*
`ORACLE_HOME` (`db_home`, set via `ORACLE_HOME=` in the response file), which starts
out empty and is populated by the install, not by the zip extraction. Confirmed against
multiple independent, version-matched, 12.2.0.1-specific sources (not just one) — see
Sources below. The `_db_home.zip`/flat-extraction model is real too, just for a later
packaging era (18c+) this project's DB layer isn't on.

**Fix:** the software zip now extracts to `{{ staging_dir }}/software` (creating
`{{ staging_dir }}/software/database/runInstaller`), and the `runInstaller` invocation
in the next block now calls `{{ staging_dir }}/software/database/runInstaller`, not
`{{ db_home }}/runInstaller`. `db_home` itself is still pre-created empty (harmless,
and it's where `ORACLE_HOME=` in the response file points, so the installer populates
it correctly during the real install). The DB OPatch update task's destination moved
the same way, from `db_home` (empty at that point, definitely wrong) to the extracted
staging `database/` folder — this second half is a **reasoned inference, not a
source-confirmed fact** like the extraction-path fix was; none of the sources checked
covered exactly where OPatch needs to be updated for a staging-folder-model `-applyRU`
flow specifically. If `runInstaller` fails during the patch-application phase citing an
OPatch version too old, that's the signal this particular guess was wrong — check
`install`/`installActions` logs (same ones the `-applyOneOffs` task comment already
points at) and fall back to Mechanism 2 in `docs/patching-strategy.md` (software-only
install with no `-applyRU`, then `opatchauto apply` against the now-populated `db_home`)
if so.

**Cleanup needed before re-running** — `db_home` (`/u01/app/oracle/product/12.2.0/db_1`
on `oradbserv05`) now contains a stray `database/` subfolder from the failed run (the
old, wrong extraction target). The role's own tasks won't clean this up on their own
(`file: state: directory` doesn't empty an existing directory) — remove it by hand
first:
```
rm -rf /u01/app/oracle/product/12.2.0/db_1/database
```
Then re-run `--tags db_software`; the new extraction task's `creates:` guard checks the
*staging* path now, so it'll extract fresh there regardless of `db_home`'s state, but
starting from a genuinely clean `db_home` avoids leaving installer-confusing debris in
what's supposed to become `ORACLE_HOME`.

## 32. `db_silent_install`'s idempotency guard trusted inventory.xml registration alone — a stale/incomplete home from a failed earlier run fooled it into skipping `runInstaller` entirely

A real `--tags db_software` re-run (after #31's extraction-path fix was applied) failed
at `root.sh`: `[Errno 2] No such file or directory:
'/u01/app/oracle/product/12.2.0/db_1/root.sh'`. `db_home` turned out to contain almost
nothing — just a leftover `OPatch/` directory (dated Oct 2023, i.e. the patch zip's own
internal file timestamps, not this project's build date) from the *original* broken
run, before #31 was fixed. No `runInstaller` output, no `root.sh`, nothing resembling a
real install.

**Root cause: the "has this already been installed?" guard checked only
`grep 'LOC="{{ db_home }}"' inventory.xml`, and that check is satisfied far too
early.** OUI registers a `HOME` entry in the central inventory relatively early in a
`runInstaller` session — before the actual copy/link/patch/root-script-generation steps
that make the home real — so a run that started, registered the home, and then failed
or was interrupted (exactly what happened here, during the period before #31's fix) left
behind a home that a LOC-only check reads as "already installed." Every subsequent
re-run of `--tags db_software` then skipped `runInstaller` entirely (trusting the stale
registration) and jumped straight to a `root.sh` that could never exist, because the
software was never actually copied in.

**Fix:** the guard now checks `{{ db_home }}/root.sh` existence directly (via `stat`),
not inventory.xml registration. Oracle only writes `root.sh` near the end of a
successful install session — a much later, much harder-to-fool signal that the home is
actually real. `phase_install_check.rc` is preserved as the variable name downstream
tasks read (`set_fact` synthesizes the same `{rc: 0|1}` shape from the `stat` result)
so nothing else in the role needed to change.

**Recovery for the currently-stuck node (`oradbserv05`)** — the stale inventory
registration needs to be cleared before a re-run can work, since Ansible's own guard
now correctly wants to re-run `runInstaller`, but OUI itself will refuse a second
install attempt against an `ORACLE_HOME` it still considers registered. First confirm
the registration is really there and really stale:
```
grep -B2 -A2 'db_1' /u01/app/oraInventory/ContentsXML/inventory.xml
```
If a `HOME` entry for `{{ db_home }}` shows up, detach it from the inventory (this only
edits `inventory.xml` — it does not touch files, and there's almost nothing under
`db_home` to lose anyway) using a **different** Oracle home's `runInstaller` — Oracle
requires this, running `-detachHome` from the home being detached itself fails or
behaves unpredictably. `grid_home`'s `oui/bin/runInstaller` is a healthy, unrelated home
already on both nodes, so it works as the runner here:
```
/u01/app/grid/19.3.0/oui/bin/runInstaller -silent -detachHome \
  -invPtrLoc /etc/oraInst.loc \
  ORACLE_HOME="/u01/app/oracle/product/12.2.0/db_1"
```
Then clean up the leftover `OPatch/` directory the same way #31 already called out for
the stray `database/` folder:
```
rm -rf /u01/app/oracle/product/12.2.0/db_1/*
```
and re-run `--tags db_software`. With #31/#32/#33 all in, this should now extract into
`db_home` correctly, run `runInstaller` for real (guard correctly sees no `root.sh`
yet), and stop cleanly at the existing pause once `root.sh` has run on both nodes — no
database gets created at this stage regardless (that's `--tags dbca_noncdb`, a separate
tag never included in this run).

**On whether this touched Grid Infrastructure at all — it didn't, and here's why that's
knowable, not just assumed:** every task in `db_silent_install` operates on
`{{ db_home }}` (`/u01/app/oracle/product/12.2.0/db_1`), `{{ staging_dir }}`, or the
central inventory — never `grid_home`, never `{{ oracle_base }}/crsdata`, never anything
GI's own `root.sh` created or owns. The one task that runs with `become: true` (the
failed `{{ db_home }}/root.sh` command) errored with `ENOENT` *before* executing
anything at all — Python couldn't even find the file to exec, meaning literally nothing
ran as a side effect of that failure. Worth confirming directly rather than taking on
faith regardless: `crsctl check crs` and `crsctl stat res -t` (as `grid`) should still
show the cluster exactly as it was before this `db_software` run.

## 33. Extraction target for the DB software zip revised — into `db_home` directly, per explicit direction, not a separate staging directory

**SUPERSEDED by #34** — after inspecting the actual staged zip's contents together, the
extraction target moved back to a separate staging directory (matching #31), settling
the question this entry raised. Kept for the history; the reasoning below about the
unavoidable nested `database/` folder is still accurate and is exactly what motivated
#34's final call.

#31 moved the DB software zip's extraction target from `db_home` to a separate staging
directory (`{{ staging_dir }}/software`), reasoning from several 12.2.0.1-specific
sources that described that as the packaging's intended use. Overridden here on
explicit instruction: **the zip is extracted directly into `db_home` (`ORACLE_HOME`)**,
matching another documented, real-world convention for this same media (extract the
staging bundle inside what will become `ORACLE_HOME`, rather than a separate location) —
web search results turned up both conventions in active use, genuinely not a
single settled answer across the DBA community for this exact zip.

**What did NOT change, because it isn't a modeling choice — it's just what's inside the
zip:** `linuxx64_12201_database.zip` contains its own top-level `database/` folder
(`runInstaller`, `install/`, `response/`, `stage/`, `OPatch/`, ...). Unzip always
recreates that folder wherever `dest` points — extracting into `db_home` produces
`db_home/database/runInstaller`, not `db_home/runInstaller` directly. This was true
in #31's staging-directory version and stayed true here; only the *location* of the
`database/` folder changed (inside `db_home` now), not its existence. Every task
invoking `runInstaller` or updating OPatch reads from `{{ db_home }}/database/...`
accordingly.

**Current state of the three tasks that matter here:**
- Software extraction: `dest: {{ db_home }}`, `creates: {{ db_home }}/database/runInstaller`.
- OPatch update: `dest: {{ db_home }}/database` (co-located with `runInstaller` — the
  same reasoning as #31's version, just relocated: this is the OPatch that
  `-applyRU`/`-applyOneOffs` actually reads during their own internal
  patch-application phase, and it's what OUI then copies into the real, final
  `db_home/OPatch` as part of laying down the product — one update serves both).
- `runInstaller` invocation: `{{ db_home }}/database/runInstaller -silent -applyRU ...`.

## 34. Settled: DB software zip extracts to a staging directory; `runInstaller`/OPatch run from there; `root.sh` runs from `db_home` — two different locations, two different reasons

After #33 tried extracting directly into `db_home`, the actual staged zip's contents
were inspected together and confirmed: `linuxx64_12201_database.zip` contains its own
top-level `database/` folder regardless of where it's extracted to. Extracting into
`db_home` doesn't eliminate that nesting — it just relocates it to
`db_home/database/`, leaving the installer media sitting inside what's supposed to
become a clean `ORACLE_HOME`. Settled back to a separate staging directory
(`{{ staging_dir }}/software`, matching #31) for that reason: `db_home` stays genuinely
empty until `runInstaller` actually populates it as the real product install, rather
than permanently housing the leftover staging bundle as a sibling to `bin/`, `lib/`,
`rdbms/`, etc.

**Task state as of THIS entry (#35 changed the patching parts below — extraction
location is unaffected and still current):**
- Software extraction: `dest: {{ staging_dir }}/software`,
  `creates: {{ staging_dir }}/software/database/runInstaller`. Still accurate.
- ~~OPatch update: `dest: {{ staging_dir }}/software/database`~~ — superseded by #35.
  OPatch is no longer touched before install at all; it's updated in `db_home` itself,
  after `root.sh`, once there's a real home to update.
- ~~`runInstaller` invocation: `... -applyRU ... -applyOneOffs ...`~~ — superseded by
  #35. Neither flag is supported by 12.2.0.1's installer; the invocation is now plain
  `-silent -responseFile ...`.
- **`root.sh` invocation stays `{{ db_home }}/root.sh`, not
  `{{ staging_dir }}/software/database/root.sh`.** This one is not a location
  convention with two valid answers the way the extraction target was — it's a plain
  fact about what OUI does: `root.sh` is *written into* the real `ORACLE_HOME` by a
  successful install, not shipped as part of the staging media. Every real transcript
  checked confirms this regardless of which extraction convention was used, including
  one using this exact zip: a 12.2.0.1 install staged the same way as this project
  prints, at the end of a successful `runInstaller` run, `As a root user, execute the
  following script(s): ... /u01/app/oracle/product/12.2.0.1/dbhome_1/root.sh` —
  `dbhome_1` there is `ORACLE_HOME`, not the staging `database/` folder. The role's
  "Show runInstaller output" task (right before the `root.sh` task) prints the actual
  path a given run reports — worth eyeballing against `{{ db_home }}/root.sh` the
  first time rather than trusting either source blindly.

**Why this took three tries to settle:** the extraction-target question genuinely has
two different real-world conventions in active use for this exact zip (staging
directory vs. straight into `ORACLE_HOME`) — search results and even this project's own
back-and-forth reflected that real ambiguity, not a mistake either time. The `root.sh`
location was never actually ambiguous in the same way; it just needed to be checked
against real transcripts rather than assumed to follow whichever convention the
extraction step used.

**Practical upshot for `db_home` itself:** with extraction back in the staging
directory, `db_home` stays genuinely clean — just the real product directories
(`bin/`, `lib/`, `rdbms/`, `root.sh`, ...) once `runInstaller` has actually run, no
stray `database/` subfolder inside it. The staged `{{ staging_dir }}/software/database`
bundle is safe to `rm -rf` once install + `root.sh` have completed, purely for
tidiness — nothing downstream reads it again.

**One more layer on top of this, not a contradiction of it:** #35 found that
`-applyRU`/`-applyOneOffs` — used throughout this entry's task states above — aren't
supported by 12.2.0.1's `runInstaller` at all. The extraction-location conclusions here
(staging directory, `root.sh` at `db_home`) are unaffected and still correct; only the
*patching mechanism* itself changed. Read #35 for the current, actual patching flow.

## 35. `-applyRU`/`-applyOneOffs` aren't supported by the 12.2.0.1 Database installer at all — confirmed by the tool itself, not inferred

A real `--tags db_software` run got past every extraction-path question settled in
#31/#33/#34 and hit a completely different, more fundamental problem the moment
`runInstaller` actually launched:

```
[INS-04003] Invalid argument passed from command line. Specified argument
([-applyRU]) is not a supported argument for this application.
```

This is about as unambiguous as a finding gets — the installer itself rejected the
flag and printed its own usage/help text confirming `-applyRU` isn't in its supported
argument list at all. Not a modeling question, not a version-convention ambiguity like
the extraction-location question was — the tool said no.

**Why every previous entry in this doc (and the sources behind them) assumed
`-applyRU` worked for the DB layer:** it does, just not for 12.2.0.1. `-applyRU` (and
its companion `-applyOneOffs`) were added to the Database installer starting at 18c —
every DB-layer `-applyRU` example found while researching #31/#33/#34
(oracle-base/Tim Hall, dbi-services) used `LINUX.X64_213000_db_home.zip` or similar
18c+/19c/21c media. The two 12.2.0.1-specific sources found (House of Brick, Mike
Dietrich) never once used `-applyRU` for the DB install — House of Brick's working
12.2.0.1 transcript uses plain `-silent -responseFile`, and Mike Dietrich's dedicated
12.2.0.1 RU-application article applies the RU as a fully separate, post-install
`$ORACLE_HOME/OPatch/opatch apply` step. In hindsight this was there to be noticed
earlier — GI's `-applyRU` usage stayed correct throughout (19c genuinely supports it,
confirmed by GI's own successful real run), but the DB-layer conclusion generalized
from the wrong version line.

**New flow, per explicit direction, matching the two 12.2.0.1-specific sources and
Oracle's own documented Mechanism 2 pattern:**

1. Plain software-only `runInstaller -silent -responseFile ...` — no patch flags.
2. `root.sh`, as always.
3. Update OPatch **in the now-populated `db_home`** (not the staging `database/`
   folder, and not before install — there's nothing there to update yet at that
   point): move the bundled `OPatch/` aside, unzip MOS patch 6880880's `OPatch/` in
   its place.
4. Patch the real, unconfigured (no database created yet) home directly:
   `opatch prereq CheckConflictAgainstOHWithDetail -ph <RU patch dir>`, then
   `opatch apply <RU patch dir>`, then `opatch apply <OJVM one-off dir>`, then
   `opatch lsinventory` to confirm.

   **UPDATE 2026-08-12 — step 4 was wrong; see #38.** A real run proved this RU ships
   as a System Patch, which plain `opatch prereq`/`opatch apply` explicitly refuses to
   handle. #38 also resolves the "not confirmed" RAC-node-propagation question raised
   below — it's `opatchauto`, not plain `opatch apply`, and its rolling-mode behavior
   *is* now confirmed. Steps 1-3 are unaffected.

**Automated through step 3; step 4 is a documented, unconditional pause with the exact
commands to run by hand — a deliberate choice, not a gap.** `opatch apply` against a
RAC-registered `ORACLE_HOME` has genuinely version-dependent behavior around other
cluster nodes: older OPatch releases are documented to interactively prompt for a
remote node list and propagate the patch from a single invocation; more recent Oracle
guidance (the OPatchAuto documentation specifically) describes plain `opatch apply` as
`-local`-only with no automatic cross-node propagation, pointing at `opatchauto`
instead for multi-node RAC automation. Which behavior this project's actual OPatch
version has is **not confirmed** — and an Ansible `command:` task has no way to answer
an interactive prompt if one shows up; a task that silently hangs forever is worse than
one that stops and asks a human. This follows the exact same philosophy this project
already applies to cluster-forming `root.sh` (#8, #24): genuinely worth watching
interactively the first time, not blindly trusted to a `changed_when`. If a real run
through step 4 confirms `opatch apply`'s actual behavior (prompts and all, or
cleanly `-local`-only), that's worth automating properly at that point — right now it
would just be a second guess dressed up as confidence.

**What did NOT need to change:** GI's `-applyRU` usage in `grid_silent_install` — genuinely
confirmed working, unaffected by this finding. `patch_before_config`'s staging of both
combo patch zips — still correct, both mechanisms need the same unzipped patch
directories on disk regardless of how each layer applies them. The extraction-location
and `root.sh`-location conclusions in #31/#33/#34 — unaffected; this is a finding about
which *flags* the installer accepts, not where anything lives on disk.

## 36. `runInstaller` forks a detached background process and returns immediately — `root.sh` ran against an empty `db_home` because Ansible didn't actually wait for install to finish

The very next real run after #35's fix (plain `runInstaller -silent -responseFile ...`,
no patch flags) failed differently:

```
TASK [Run runInstaller silently ...] changed: [oradbserv05]
TASK [Show runInstaller output ...] ok: [oradbserv05] =>
  - Starting Oracle Universal Installer...
  - 'Checking Temp space: ... Passed'
  - 'Checking swap space: ... Passed'
  - Preparing to launch Oracle Universal Installer from /tmp/OraInstall... Please wait ...

TASK [Run root.sh for the DB home ...] fatal: [oradbserv05]: FAILED! =>
  msg: '[Errno 2] No such file or directory: .../db_1/root.sh'
```

The `runInstaller` task reported `changed=true` and returned a real `rc`, but its
captured stdout cuts off mid-install — right where OUI's wrapper script hands off to
the actual Java installer process. That's the tell: **this is documented OUI behavior,
not a bug in this project's Ansible.** `runInstaller`, by default, forks the real
install work into a separate process and returns control to the calling shell almost
immediately rather than blocking until installation genuinely completes — the same
symptom is visible in House of Brick's own 12.2.0.1 transcript (a shell prompt appears
mid-line, before "The installation of Oracle Database 12c was successful" prints). In
an interactive terminal this is barely noticeable — the completion lines just show up
a bit later, after you already have your prompt back. Under Ansible's `command:`
module, which waits on and captures output from the process it directly spawned, it's
fatal: the module returns as soon as that immediate parent exits, with `db_home` still
empty, and the next task (`root.sh`) runs immediately against nothing.

**Fix — confirmed against Oracle's own documented flag, not a custom workaround:**
`-waitforcompletion`. Per oracle-base.com's OUI silent-install reference (which shows
this exact flag in its 12cR2-specific command examples): "Stop the installer spawning
as a separate process, so scripts happen in sequence." Added to the `runInstaller`
invocation in `db_silent_install` — no log-polling loop needed, no `async`/`poll`
gymnastics, just the one documented flag:

```
runInstaller -silent -waitforcompletion -responseFile db_install.rsp ...
```

**Why `grid_silent_install`'s `gridSetup.sh` call never hit this, without having the
flag either:** that role already puts a manual, unconditional `pause:` between
`gridSetup.sh` and `orainstRoot.sh`/`root.sh` (Phase A, "root scripts are worth
watching interactively the first time through") — a human reading the prompt, typing
the commands, and pressing Enter takes far longer than the detached background install
needs to finish, so the race never surfaced there. `db_silent_install` runs `root.sh`
automatically, back-to-back with `runInstaller`, with nothing to accidentally provide
that buffer — so it hit the race on the very first real run. Worth remembering if
`gridSetup.sh` is ever changed to run its root scripts automatically too: it would need
`-waitforcompletion` (or the GI equivalent) added at that point, since the lucky timing
buffer wouldn't exist anymore.

**Recovery for this run:** nothing to clean up — the failed attempt never got far
enough to create `db_home/root.sh`, so the idempotency guard in #32 will correctly see
the install as not-yet-done and re-invoke `runInstaller` on retry. Worth checking
`db_home` isn't unexpectedly partially populated first (`ls {{ db_home }}`) before
re-running — the previous run's detached background process may have kept running
after Ansible gave up and could have finished, or partially finished, on its own in
the meantime; a non-empty target could make a second `runInstaller` invocation
complain rather than cleanly redo the work.

## 37. DB installer's bundled CVU hard-fails a mandatory "CRS Integrity" check against 19c GI — legacy `crs_stat` doesn't exist there, and it's a real, confirmed CVU-vs-GI version mismatch, not cluster damage

With `-waitforcompletion` from #36 in place, the very next real run got much further —
past the SSH-setup phase, into `runInstaller`'s own prerequisite checks — and still
never wrote anything into `db_home`. The install log
(`/u01/app/oraInventory/logs/installActions<timestamp>.log`) shows why:

```
INFO: CRS Integrity: This test checks the integrity of Oracle Clusterware stack across the cluster nodes.
INFO: Severity:CRITICAL
INFO: OverallStatus:OPERATION_FAILED
SEVERE: [FATAL] [INS-13013] Target environment does not meet some mandatory requirements.
```

Digging into what "CRS Integrity" actually ran:

```
PRVF-7595 : CRS status check cannot be performed on node "oradbserv06"
PRVG-2043 : Command "/u01/app/grid/19.3.0/bin/crs_stat -t " failed on node "oradbserv06"
sh: /u01/app/grid/19.3.0/bin/crs_stat: No such file or directory
```

(Same for `oradbserv05`.) `crs_stat` is a long-deprecated Clusterware utility
(superseded by `crsctl`), and it genuinely isn't shipped in this project's 19c
`GRID_HOME` — this isn't a broken install, it's the DB installer's bundled CVU
(`CVU_12.2.0.1.0`, visible in the log's temp-script paths) still checking for a binary
that a newer GI release doesn't carry.

**Confirmed as a false positive, not real cluster damage**, two independent ways
before touching any code:

1. `crsctl check cluster -all` on both nodes — `CRS-4537`/`CRS-4529`/`CRS-4533` all
   "online" on both `oradbserv05` and `oradbserv06`.
2. `crsctl stat res -t` — every resource `ONLINE`/`STABLE` on both nodes (ASM,
   listeners, SCAN VIPs, node VIPs, `ora.cvu`, everything).

Also not unique to this project's environment — an oracle-mosc community thread
(GI 19c + a 12.x DB home, filed 2020) hits the identical error text against the
identical `<grid_home>/bin/crs_stat` path pattern.

**Why this is a direct, foreseeable consequence of #2's deliberate design, not a new
mistake:** running GI 19c under DB 12.2.0.1 (an intentional, independently-certified
combination — see #2) means the DB layer's own bundled tooling (CVU included) predates
the GI version it's pointed at by several years. Most of the time that gap is
invisible; this is the one place it surfaces as a hard failure instead of a silent
version skew.

**Fix:** `db_ignore_prereq: true`, a new var in `group_vars/all.yml`, deliberately kept
separate from the existing `use_ignore_prereq` (still `false`) rather than reusing it —
GI's own prereq validation is genuinely fine and shouldn't lose that safety net just to
work around a DB-layer-only, already-independently-confirmed false positive.
`db_silent_install`'s `runInstaller` invocation now passes
`-ignorePrereq -ignoreSysPrereqs` whenever `use_ignore_prereq` OR `db_ignore_prereq` is
true. There's no narrower runInstaller flag to skip just the "CRS Integrity" check —
`-ignorePrereq` is all-or-nothing for the mandatory-check category, which is exactly
why the cluster health was verified independently via `crsctl` first, rather than
reaching for the blunt flag on faith.

## 38. The RU and OJVM patches are both System Patches — plain `opatch prereq`/`opatch apply` against `db_home` was the wrong mechanism; `opatchauto` is, run per-node, RU then OJVM, resolving #35's open RAC-propagation question (initial answer corrected once, same day)

With #36 and #37 fixed, `runInstaller` finally succeeded on both nodes for real —
`root.sh` ran cleanly on `oradbserv05` and `oradbserv06`, OPatch upgraded fine
(12.2.0.1.6 → 12.2.0.1.40) in `db_home` on node1. Then the #35-era patch-application
commands, run by hand exactly as documented, failed immediately:

```
$ ./opatch prereq CheckConflictAgainstOHWithDetail -ph /u01/app/oracle/staging/patches/33559966/33583921
This command doesn't support System Patch.
OPatch failed with error code 21
```

`opatch prereq`/`opatch apply`'s plain command set explicitly refuses to operate on a
**System Patch** — a packaging format, not a description of severity. `opatchauto` is
required instead, confirmed against Oracle's own documented command for this exact
patch number: `opatchauto apply <patch_dir>`, as root, though which home's `OPatch` to
invoke it from took two rounds to pin down (see below).

**First answer to #35's open RAC-propagation question was itself wrong, and got
corrected within the same session.** The first source checked described `opatchauto`
running in "rolling mode by default" from a single invocation, patching every node from
one command. A second pass — specifically searching for this exact combo-patch
category (`33559966`'s structure, one parent directory containing separate RU and OJVM
subdirectories, is Oracle's well-established "Combo of OJVM Component + DB RU"
packaging) — turned up a far more detailed, specifically-sourced reference
(oracledba.help, itself citing several real MOS cases) that says plainly:
**"opatchauto only patches the individual node. So you have to run it on all nodes."**
That source is trusted over the first, more general one — it's specific to this exact
patch category, shows real session output, and cites concrete MOS case numbers rather
than a general description of `opatchauto` behavior.

**Which home's `OPatch` to invoke `opatchauto` from also needed a real-run
correction.** The first attempt tried `grid_home/OPatch` for the RU (matching a
general "GI\DB combo PSU" reference where a GI component is present) — that failed
with `opatchauto must run from one of the homes specified` once `-oh db_home` was
added. `opatchauto` must be invoked from the `OPatch` of the home actually named via
`-oh` — this patch (`33559966`) is a DB-only RU with no GI component, so that's
`db_home`, not `grid_home`, for **both** steps. Confirmed working against a real run.

**Corrected flow — two separate patches, each needing its own `opatchauto`
invocation from `db_home/OPatch`, run on EACH node in turn, RU before OJVM:**

```bash
export ORACLE_HOME=/u01/app/oracle/product/12.2.0/db_1
export PATH=$PATH:$ORACLE_HOME/OPatch
cd $ORACLE_HOME/OPatch

# STEP 1 — RU, as root, on oradbserv05 THEN oradbserv06:
sudo ./opatchauto apply /u01/app/oracle/staging/patches/33559966/33583921 -oh $ORACLE_HOME

# STEP 2 — OJVM one-off, as root, WITH -nonrolling (OJVM is documented as a
# nonrolling patch type — it cannot be rolled node-by-node the way the RU can),
# on oradbserv05 THEN oradbserv06:
sudo ./opatchauto apply /u01/app/oracle/staging/patches/33559966/<ojvm_patch_id> -oh $ORACLE_HOME -nonrolling
```

Confirm afterward, on both nodes: `db_home/OPatch/opatch lsinventory`. No manual
`datapatch` step needed at this stage either way — no database exists yet
(`dbca_noncdb` hasn't run); DBCA registers the SQL-level half automatically for
databases it creates (see `docs/patching-strategy.md` Mechanism 3) — the detailed
create-pfile/startup-upgrade/`datapatch`/restore-normal-mode dance in general OJVM
guides is for patching an *already-running* database, which doesn't apply here yet.

**Also fixed while here:** `db_silent_install`'s OPatch-upgrade block (move bundled
`OPatch/` aside, unzip MOS 6880880's newer one) was `run_once`/`delegate_to` node1
only, matching the old plan's now-obsolete assumption that only `db_home/OPatch` on
one node would ever matter. Now runs on both `rac_nodes` — cheap, safe, and removes
one more open variable (node2's `db_home` sitting on the OUI-bundled 12.2.0.1.6)
before a first-time `opatchauto` run. GI's own `grid_home/OPatch` was already current
going into this — `grid_silent_install`'s stage block updates it from the same MOS
6880880 zip (filtered to the GI release) before `-applyRU`, confirmed already run
successfully earlier in this project.

**Still a manual, unconditional `pause:`, not automated as an Ansible `command:`
task** — same reasoning as #35 and the project's established pattern for root.sh
(#8, #24), doubly so given this exact procedure was already corrected once in the same
session: worth watching interactively, on both nodes, before trusting any of it to a
`changed_when`.

**Worth remembering for the write-up:** this is a good, honest "what went wrong"
moment for the eventual showcase post — not just the original `-applyRU`-unsupported
finding, but the fact that the *first* documented fix for the RAC-propagation question
was itself incomplete, caught only by deliberately searching for a more specific
source instead of stopping at the first plausible answer.

**UPDATE 2026-08-12 — confirmed against a real run, two more small corrections:**

1. **`opatchauto` runs via `sudo` directly, not `su - root` first.** The oracle user
   has sudo rights on these nodes — `sudo ./opatchauto apply ...` run right from the
   oracle user's own shell is what actually worked. Both the role's pause prompt and
   the command examples above are now written with an explicit `sudo` prefix rather
   than a generic "as root" that left the how up to guesswork.
2. **The OJVM one-off (step 2) succeeded on `oradbserv05`** on the first real attempt
   with the corrected command (`sudo ./opatchauto apply <ojvm_patch_dir> -oh
   $ORACLE_HOME -nonrolling`, from `db_home/OPatch`) — clean run, no `RemoteHostExecutor.pl`
   error this time, confirming the earlier node-OPatch-version mismatch (node2 still on
   the OUI-bundled 12.2.0.1.6 while node1 had already been upgraded to 12.2.0.1.40)
   was indeed the root cause of that failure, not something wrong with the command
   itself. Still outstanding at this point: step 2 on `oradbserv06`, and confirming
   step 1 (the RU) actually completed on both nodes before trusting the OJVM result —
   `opatchauto apply ... -nonrolling` patches one node per invocation, same as step 1.

3. **`-oh $ORACLE_HOME` needed to point at `db_home`, and `opatchauto` needed to be
   invoked from `db_home/OPatch` for BOTH steps, not `grid_home/OPatch` for the RU.**
   The RU step, run from `grid_home/OPatch` with `-oh db_home` (mismatched — the
   binary and the `-oh` target were different homes), failed with `opatchauto must
   run from one of the homes specified`. `opatchauto` must be invoked from the
   `OPatch` of the home actually named via `-oh` — this patch (`33559966`) is a
   DB-only RU with no GI component, so that's `db_home` for both the RU and the
   OJVM one-off. Confirmed working against a real run once corrected.

## 39. DBCA needs the audit file destination created on every node first — DBT-06608, and it's a local filesystem path, not ASM/CFS

Comparing this project's `dbca_gp_noncdb.rsp.j2` against a known-working DBCA response
file from a similar RAC build surfaced a real gap: the template had no `initParams`
line at all, relying entirely on the `General_Purpose.dbc` template's own default for
`audit_file_dest` (`{ORACLE_BASE}/admin/{DB_UNIQUE_NAME}/adump`). Nothing in this
project ever created that directory. DBCA validates it up front and fails immediately,
before touching anything else, if it's missing:

```
[DBT-06608] The specified audit file destination (/u01/app/oracle/admin/<db>/adump)
is not writable.
```

**Why this matters specifically for RAC, not just "create a directory somewhere":**
`audit_file_dest` is an OS filesystem path, not ASM or shared cluster storage — each
node needs its own copy, created before DBCA runs. `dbca_noncdb`'s whole play runs
from `rac_node1` only (`site.yml`, `hosts: rac_node1` — DBCA talks to the rest of the
cluster via the response file's `nodelist`, it doesn't need to execute per-node
itself), so a plain `file:` task in this role would only ever touch node1 — this
needed an explicit `loop: "{{ groups['rac_nodes'] }}"` + `delegate_to: "{{ item }}"`
to actually reach both nodes.

**Fix:** a new task in `dbca_noncdb`, before the response file is rendered, creates
`{{ oracle_base }}/admin/{{ db_unique_name }}/adump` (`oracle:oinstall`, `0750`) on
every `rac_nodes` host. The response file template now sets `audit_file_dest`
explicitly via `initParams` to that same resolved path, rather than leaving it to the
template's implicit default — self-documenting, and independent of whichever default
`General_Purpose.dbc` happens to carry for this patch level.

**Also changed while comparing:** `runCVUChecks` — `true` in this project's template,
`false` in the reference file. Switched to `false` here: this database's `dbca` binary
is the same 12.2.0.1 install already confirmed (#37) to bundle a CVU build that
hard-fails a mandatory "CRS Integrity" check against 19c GI over the deprecated
`crs_stat` binary. DBCA's own CVU pass would hit the identical false positive.
`dbca_noncdb`'s own "Confirm the cluster is up" task already verifies cluster health
independently via `crsctl` before this role does anything else, so DBCA's internal CVU
run is redundant here, not a safety net being removed.

**Not changed, worth a deliberate decision rather than a silent copy:** the reference
file sets explicit `initParams` for memory (`sga_target`/`pga_aggregate_target` instead
of this project's `memoryPercentage`-driven automatic sizing), per-instance
`thread`/`instance_number`/`undo_tablespace` mapping, and an ASM path convention that
namespaces each database under its own subfolder (`+DATA01/{DB_UNIQUE_NAME}/` rather
than this project's flat `+DATA01`). None of these caused the reported error, and none
were adopted here — worth a real yes/no decision if useful later (the per-database ASM
subfolder convention in particular is worth considering once more than one database
shares `DATA01`), not something to fold in silently alongside the actual bug fix.

**UPDATE 2026-08-12 — the `+DATA01/{DB_UNIQUE_NAME}/` question above is resolved, no
change needed.** This is standard ASM OMF behavior, not something the response file
has to spell out: when Oracle Managed Files is active (it is here — `storageType=ASM`,
no explicit filenames given), ASM automatically namespaces every database under its
own subdirectory of whatever diskgroup is specified, named from `DB_UNIQUE_NAME` —
`diskGroupName=DATA01` already lands datafiles at `+DATA01/APEXDB/DATAFILE/...`
without writing `{DB_UNIQUE_NAME}` into the path explicitly. The reference file's
literal `{DB_UNIQUE_NAME}` templating produces the identical result, just spelled out.
Left as-is.

## 40. Multiplexing online redo logs across two diskgroups, and resizing them, via the DBCA response file

Asked whether 2-member multiplexed redo log groups (one member in `DATA01`, one in
`RECO`, 128MB each, OMF-managed) are achievable through `dbca_gp_noncdb.rsp.j2` before
the database exists yet — genuinely possible, confirmed against two independent,
documented DBCA response-file mechanisms rather than assumed:

1. **Multiplexing** — setting *both* `db_create_online_log_dest_1` and
   `db_create_online_log_dest_2` as `initParams` makes OMF multiplex every redo log
   member it creates across both destinations automatically, for every group DBCA
   lays down. OMF generates the actual filenames itself
   (`o1_mf_<group>_<unique>_.log`, one under each diskgroup's `ONLINELOG/`) rather
   than literal names like `1a`/`1b` — same outcome (2 members per group, split
   across `DATA01`/`RECO`), system-managed naming instead of hand-picked.
2. **Sizing** — `redoLogFileSize` (top-level, megabytes) is a genuine, documented
   `dbca.rsp` parameter, independent of `templateName` — confirmed against a real,
   working 12.2 response file using it exactly this way (not just template
   documentation). Set to `128` here.

**What this does NOT control: how many groups get created per thread.** That's
defined inside `General_Purpose.dbc` itself (the stock template this project uses,
not a custom one) — not something overridable from the response file the way
size/multiplexing are. Two RAC threads (2 instances) means groups get created in
pairs per thread, matching the "groups 1-4" framing of the ask, but the exact count
General_Purpose.dbc actually creates per thread wasn't independently confirmed here
(no direct access to inspect `{{ db_home }}/assistants/dbca/templates/General_Purpose.dbc`
on the target host from this session) — rather than assume it lands on exactly 4,
`dbca_noncdb` now includes a read-only post-creation check
(`v$log`/`v$logfile`, group/thread/member/size) so the actual result gets confirmed
against the real database rather than trusted on faith.

**Deliberately NOT scripted as an automatic fix if the layout doesn't match** — same
reasoning as every other first-time, hard-to-reverse operation in this project
(patch application pauses, cluster-forming `root.sh`): redo log DDL against a live
RAC thread structure (dropping the wrong group, or dropping a group before its
contents are archived) is a genuinely bad place for a wrong guess to execute
unattended. If the verification query shows a mismatch, resize/re-multiplex by hand
with `ALTER DATABASE ADD/DROP LOGFILE MEMBER` — worth reading interactively the first
time, informed by what the query actually shows, not scripted defensively for a
scenario that hasn't been observed yet.

## 41. `dbca_gp_noncdb.rsp.j2` had a stray `[CREATEDATABASE]` section header that was never valid — DBT-00108, and the giant parameter dump in the error is a red herring

The first real `--tags dbca_noncdb` run failed immediately, before DBCA did anything:

```
[WARNING] [DBT-00108] Incorrect value passed to a command line argument.
   CAUSE: Exception encountered : cvc-complex-type.2.4.a: Invalid content was found
   starting with element 'CREATEDATABASE'. One of '{silent, progressOnly, ... }' is
   expected.
```

That massive `{...}` list is every valid flat top-level `dbca.rsp` parameter name —
easy to misread as "something's wrong with one of these fields," but it's actually the
XML schema validator's own error-recovery output: `cvc-complex-type` is a plain
Java/XML Schema validation error class, meaning DBCA parses this "plain key=value"
file against an XML schema (`rspfmt_dbca_response_schema_v12.2.0`) under the hood even
though nothing about the file *looks* like XML. The template had a bracketed
`[CREATEDATABASE]` line right after `responseFileVersion=` — that line has no place in
this format at all. The parser hit it, couldn't match it against any expected element
in the schema's grammar, and dumped the full list of what it *did* expect (every flat
parameter name) as the error detail.

**Confirmed not valid by direct comparison**, not just inference: a real, working
response file for a similar RAC build (used as a reference for #39/#40 above) has no
section header anywhere — `responseFileVersion=...` is followed immediately by
`gdbName=...` and every other field, flat, no brackets. This bug predates the recent
audit-dest/redo-log changes — unrelated to either.

**Fix:** removed the `[CREATEDATABASE]` line entirely. Nothing else in the template
needed to change for this specific error — the parameter list itself was always
correct; the corrupting element was a single stray header line.

**A secondary symptom worth recognizing if seen again:** because the response-file
render failed at the XML-parse stage, DBCA never got far enough to do anything, so the
very next task (`srvctl status database -d apexdb`) correctly reported the database
doesn't exist yet (`PRCD-1120`/`PRCR-1001`) — expected, not a second bug, just the
idempotency-guard-adjacent tasks downstream reacting honestly to nothing having been
created.

## 42. `useAutomaticMemoryManagement` isn't a real `dbca.rsp` parameter — a second, distinct DBT-00108 in the same template, same class of bug as #41 but a different line

Re-running `--tags dbca_noncdb` after #41's fix got further (cluster check, audit-dir
task, response file render, `dbca` itself started) but hit the identical error class
again, this time against a different element:

```
[WARNING] [DBT-00108] Incorrect value passed to a command line argument.
   CAUSE: Exception encountered : cvc-complex-type.2.4.a: Invalid content was found
   starting with element 'useAutomaticMemoryManagement'. One of '{silent, ... }' is
   expected.
```

Same mechanism as #41 — the schema validator hit an element it doesn't recognize and
dumped its full valid-parameter list as the error detail. This time the offending line
was `useAutomaticMemoryManagement=false`, sitting directly under the genuinely valid
`automaticMemoryManagement=false`. `useAutomaticMemoryManagement` was never a real
`dbca.rsp` field — confirmed against a real, working 12.2 RAC response file
(oracle-base.com, same `responseFileVersion=/oracle/assistants/rspfmt_dbca_response_schema_v12.2.0`
as this project), which only has `automaticMemoryManagement`, nothing named
`useAutomaticMemoryManagement`.

**Worth noting why `enableArchive` (also present in this template, higher up) wasn't
also flagged:** the validator only reports the *first* element it can't place, scanning
top to bottom — since `enableArchive=true` sits well before
`useAutomaticMemoryManagement=false` in the file and the error pointed at the later
line, everything up to and including `enableArchive` had already parsed cleanly. Not
a coincidence worth re-litigating every field over; the ordering of these two errors
across two separate runs (`[CREATEDATABASE]` first, near the top of the file; this one
second, near the bottom) is itself the confirmation.

**Fix:** removed the `useAutomaticMemoryManagement=false` line, keeping
`automaticMemoryManagement=false`. Same non-issue downstream `PRCD-1120`/`PRCR-1001`
from `srvctl status database` as #41 — expected, not a third bug.

## 43. `asm_diskgroup_reco` said `RECO` but the diskgroup that actually exists on the cluster is `RECO01` — DBT-06002, and it's a variable/reality drift, not a template bug

With #41 and #42 both fixed, the response file finally parsed cleanly and DBCA got as
far as actually querying ASM — then failed:

```
SEVERE: [FATAL] [DBT-06002] Selected disk group (RECO) is not found.
   ACTION: Specify a disk group that is accessible from the system.
```

This one isn't a schema/parsing problem like #41/#42 — it's DBCA asking the real ASM
instance (via `kfod`) what diskgroups exist, and getting back exactly two:

```
149952  49408  NORMAL  RECO01  10.1.0.0.0  19.0.0.0.0
149952  49112  NORMAL  DATA01  10.1.0.0.0  19.0.0.0.0
```

`DATA01` matched fine (`asm_diskgroup_data: DATA01`). But `recoveryGroupName` in the
response file was rendered from `asm_diskgroup_reco`, which `group_vars/all.yml` had
set to `RECO` — a diskgroup that genuinely doesn't exist. The one that does exist is
named `RECO01`, consistent with the `ora.RECO01.dg` resource already seen in this
project's own `crsctl stat res -t` output earlier in the session. `DATA02` doesn't
show up in this `kfod` listing either — not a problem for this run (`dbca_noncdb`
never references it), but a sign it hasn't been created yet on this cluster; worth
running `--tags grid_storage` for it separately if/when it's needed.

**Root cause, best understanding:** `grid_silent_install`'s storage stage creates
this diskgroup via `asmca -createDiskGroup -diskGroupName {{ asm_diskgroup_reco }}` —
so whatever value that variable held at the time that task actually ran is what
landed on the cluster (`RECO01`). The variable was later either set or left at `RECO`
in `group_vars/all.yml` — a plain drift between the value the diskgroup was actually
created with and the value the file currently declares, not something either
`dbca_noncdb` or the diskgroup-creation task did wrong in isolation.

**Fix — matched the variable to reality, not the other way around:** renaming a live
ASM diskgroup is a real, disruptive operation (`ASMCMD` doesn't even support renaming
a mounted diskgroup in place); correcting `group_vars/all.yml` to say what's actually
there is the safe, non-destructive fix, consistent with this project's general
"don't touch live cluster storage to fix a documentation/variable mismatch" stance.
`asm_diskgroup_reco` is now `RECO01` — every consumer (`dbca_gp_noncdb.rsp.j2`'s
`recoveryGroupName`, `recoveryAreaDestination`, and the `db_create_online_log_dest_2`/
redo-multiplexing `initParams` from #40; `grid_silent_install`'s RECO01 idempotency
check and `asmca` creation task) reads from this one variable, so the single edit
fixes the whole chain. Task names/comments in `grid_silent_install/tasks/main.yml`
and `group_vars/all.yml` updated from "RECO" to "RECO01" to match, cosmetic but worth
keeping accurate for anyone reading the role later.

## 44. `srvctl` database-resource commands have to run from the DATABASE home's `srvctl`, not the Grid home's — PRCD-1229, and a genuinely dangerous latent idempotency bug it would have caused on every later run

With #43 fixed, DBCA actually completed — confirmed independently outside Ansible
(`gv$instance` showing both `apexdb1`/`apexdb2` `OPEN`, `srvctl config all` listing
`ora.apexdb.db`, `dba_registry_sqlpatch` showing both patches `SUCCESS`, 0 invalid
objects). But the very next Ansible task failed:

```
PRCD-1229 : An attempt to access configuration of database apexdb was rejected
because its version 12.2.0.1.0 differs from the program version 19.0.0.0.0.
Instead run the program from /u01/app/oracle/product/12.2.0/db_1.
```

**Root cause:** this project deliberately runs GI at 19c and the database at
12.2.0.1 (see #2) — a fully supported, documented pairing, but it means `srvctl`
itself is version-sensitive per-command. Oracle's own rule (confirmed against
multiple independent sources hitting this exact error, including the identical
12.2.0.1/19.0.0.0.0 version pair this project uses): **clusterware-resource srvctl
commands (ASM, network, SCAN) run from the Grid home; database-resource srvctl
commands (`config database`, `status database`, `start`/`stop database`, etc.) have
to run from the actual DATABASE home whose version matches the target database** —
not grid_home's srvctl, even though grid_home's is the newer/"current" one.

**Why this was worse than just one failed task:** `dbca_noncdb`'s own idempotency
guard (`Check whether the database has already been created`, the task this whole
role's re-run-safety depends on — see #14's general idempotency principle) called
`{{ grid_home }}/bin/srvctl config database` too, with `failed_when: false`. Once the
database actually exists, that call would hit the identical PRCD-1229 and return a
non-zero rc — **indistinguishable, from this guard's point of view, from "the
database doesn't exist yet."** Every subsequent `--tags dbca_noncdb` run from this
point forward would have silently concluded the database needed creating and
re-invoked `dbca -createDatabase` against an already-existing one — a real, "expensive
and not automatically safe to re-run" collision (#14's own words), not just a cosmetic
verification-step failure. Caught here because the final status check failed loudly;
the idempotency guard's version of the same bug would have failed silently and only
shown up as damage on a future run.

**Fix:** both `srvctl` invocations in `dbca_noncdb/tasks/main.yml` (the idempotency
guard and the final status check) now use `{{ db_home }}/bin/srvctl`, not
`{{ grid_home }}/bin/srvctl`. No other role in this project calls `srvctl ... database`
against the wrong home — checked directly, this was confined to these two tasks.

## 45. `group_vars/all.yml` had real, committed weak passwords — fine for a working lab, not fine to publish

Pre-publish review (`docs/known-risks.md` didn't catch this one during the build
itself, since a working lab has no reason to notice its own passwords) —
`sys_password: "sys"` and `system_password: "system"` were literal, checked-in
values, not placeholders, even though the comment directly above them already said
"placeholders only. Never commit real values; use ansible-vault." The comment's
intent was right; the actual lines under it didn't match it. These two variables feed
SYS/SYSASM/ASM-monitor (`grid_install.rsp.j2`) and SYS/SYSTEM/DBSNMP
(`dbca_gp_noncdb.rsp.j2`) — every privileged password in this build, from one place.

**Why this matters even for a fully NAT-isolated, single-host home lab:** the repo
is explicitly written to be read by hiring managers and other DBAs (see this
project's whole premise) — committed credentials, however weak and however
lab-only, read as a real hygiene gap in exactly the audience this is written for,
and they'd sit in git history even if changed later.

**Fix:** replaced both with loud, obviously-fake placeholders
(`CHANGE_ME_sys_password`/`CHANGE_ME_system_password`) that fail Sections 11–13
clearly if left as-is, rather than silently installing with a value nobody chose.
Two ways to supply real values without committing them, documented in
`group_vars/all.yml`'s own comment and `installation/README.md` Section 5d:
`-e sys_password=... -e system_password=...` on the command line, or a gitignored
`group_vars/all_local.yml` (added to `.gitignore`) for something that persists
across runs. `ansible-vault` is the actually-correct answer for anything beyond a
single-host lab — not adopted here since it would require `--ask-vault-pass` on
every `ansible-playbook` invocation in this whole SOP, a real workflow change
beyond the scope of a pre-publish cleanup pass.
