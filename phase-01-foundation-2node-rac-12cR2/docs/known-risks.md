{% raw %}
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

## 46. Data Guard standby (usatclust2) built via GI/DB Oracle Home cloning, not a fresh silent install — and deliberately NOT stopping Clusterware on the live source node first

Phase 2 stands up `oradbserv09`/`oradbserv10` as a second, independent 2-node RAC
cluster (`usatclust2`) to host the Data Guard standby, using `oradbserv05`'s
already-installed, already-patched GI 19c and DB 12.2.0.1 Oracle Homes as the source
— skips re-running the silent install + RU/OJVM patch cycle entirely (the whole point
of cloning, not just a shortcut).

**Followed Oracle's actual documented procedure, not an improvised one** — confirmed
against the current 19c *Clusterware Administration and Deployment Guide*, chapter 7,
"Creating a Cluster by Cloning Oracle Clusterware" (distinct from that same chapter's
"Using Cloning to Add Nodes to a Cluster," which is for extending an *existing*
cluster — not what this is; `usatclust2` is a separate cluster with its own OCR/
voting, confirmed by the doc's own statement that "OCR and voting files are not
shared between the two clusters after you successfully create a cluster from a
clone"). The documented mechanism: tar the source Oracle Home with node-specific/
runtime files excluded (`log/`, `gpnp/`, `cdata/`, `crf/`, `network/admin/*.ora`,
`root.sh*`, `crsconfig_params`, `oraInst.loc`, etc.), deploy (untar) onto the
destination node(s), fix ownership, then run the *normal* `gridSetup.sh` install-then-
configure flow against the already-deployed binaries — the same Phase A/B sequence
`usatclust1` itself went through, just skipping the "extract zip + `-applyRU`" part.
No dedicated GI cloning doc chapter exists for the RDBMS (DB) home the same way, so
the DB Oracle Home is cloned by the same tar-and-deploy technique, finished with
`runInstaller -silent -attachHome` to register it in each target node's own central
inventory (the manual equivalent of what `clone.pl` automates for a straight
relocate).

**Deliberate deviation from the documented procedure, not an oversight:** Oracle's
own instructions say to stop Clusterware on the source before cloning a *fully
configured* GI home — reasonable when the home being cloned is being relocated or
decommissioned. `oradbserv05` is neither: it's live, and it's the only thing serving
`usatclust1`'s one real database (`apexdb`). Stopping it to clone binaries for an
unrelated second cluster isn't acceptable here. The files Oracle's own exclusion list
strips out are exactly the node-runtime-state files that would actually be
inconsistent if copied from a live stack (GPnP profile, OCR/CRS cache, logs, PID/lock
files) — the program binaries being cloned don't change while the stack is running.
`roles/gi_db_home_clone/tasks/main.yml` documents this reasoning inline; flagged here
too since it's a real, informed departure from Oracle's own written guidance, not
something to gloss over in a showcase write-up.

**What this role does NOT do:** form the `usatclust2` cluster, touch `usatclust1` in
any way beyond a read-only `tar` of its Oracle Homes, or create the standby database.
Cluster configuration (`gridSetup.sh` Phase B equivalent, root scripts, `usatclust2`
formation) and standby database creation (RMAN `DUPLICATE ... FOR STANDBY FROM ACTIVE
DATABASE`, not DBCA — DBCA creates new databases, not standbys) are later, separate
roles, not yet built as of this entry.

**Not yet verified against a real run** — this role hasn't executed against real
hardware yet at the time of writing. If the `-attachHome` invocation or the tar
exclusion list needs correction once actually run, that'll land here as an update,
same as every other entry in this file.

**UPDATE — self-reviewed before any real run, three fixes made:**

1. **Removed the GI home `-attachHome` task entirely.** It contradicted the very doc
   this entry cites: Oracle's documented procedure has `gridSetup.sh`'s own normal
   install flow register the GI home as part of configuring `usatclust2` next —
   pre-registering it manually first, with a guessed `CLUSTER_NODES` value, risked
   `gridSetup.sh` seeing an "already installed" home and skipping or conflicting with
   steps it still needs to run (the same stale-inventory class of problem as #32).
   The DB home keeps its `attachHome` step — no later "install" step exists for it
   the way there is for GI, so it genuinely needs this now, and #32 already
   confirmed this exact flag works in this project.
2. **Added a preflight check** (`/etc/oraInst.loc` + `id oracle grid` on every target
   node) before any tar/copy work starts — this role assumes `os_prep` already ran on
   `oradbserv09`/`10`; failing fast on that beats failing after moving multi-GB
   tarballs around.
3. **Noted, not yet fixed:** the fetch→control-node→copy path for two multi-GB
   tarballs is slower and more disk-hungry on the control node than a direct
   node-to-node `scp` would be (avoided only to skip an extra Ansible collection
   dependency) — acceptable for a first correct pass, worth revisiting once this
   role has actually run once. Same for the lack of a role-level idempotency guard
   (a re-run currently re-tars/re-copies everything rather than skipping completed
   work) — deferred until there's a real run to design the guard against.

**UPDATE — James decided to stop Clusterware on the source before cloning, reversing
this entry's original deviation; plus a real syntax bug caught on the first real
run:**

1. **Decision reversed, deliberately, by James:** rather than accept the "leave it
   live" deviation above, James is stopping Clusterware on `oradbserv05`
   (`crsctl stop crs`) before running this role, mitigating the live-file-consistency
   risk directly instead of arguing it away. This is a **manual** step (not automated
   by the role — stopping Clusterware on the node hosting `apexdb`'s only instance
   isn't something to hide behind a playbook flag), documented in
   [`../../high-availability/README.md`](../../high-availability/README.md) Section 6.
   The role now has a hard preflight gate (`crsctl check crs` against
   `clone_source_node`, fails the play if any component still reports "is online")
   so a forgotten manual step is caught before any tar happens, not after. The tar's
   exclusion list itself is unchanged — still correct and still needed regardless of
   whether the source is running or stopped.
2. **Real bug, caught on first actual run against `oradbserv09`/`oradbserv10`:**
   `ERROR! 'loop' is not a valid attribute for a Block` — the "ensure target GI/DB
   home directories exist" task used `loop:` directly on a `block:`, which Ansible
   does not support (loops only apply to individual tasks/modules, never to a block
   as a whole). This is also why the error surfaced even when running
   `--tags standby_os_prep`, a completely different play — Ansible parses every task
   file referenced anywhere in `site.yml` up front, before executing anything, so a
   syntax error in one role's tasks file blocks every tagged run, not just that
   role's own. **Fix:** split the single blocked task into two plain looped `file:`
   tasks (one for `grid_home`, one for `db_home`), each with its own `loop`/
   `delegate_to` — functionally identical, just without the invalid `block`+`loop`
   combination.

## 47. `gi_db_home_clone` had no way to actually run — every existing `site.yml` play was hardcoded to `hosts: rac_nodes`, so nothing could reach `standby_nodes` at all

Found when asked directly: "how do I start a new build when the SOP is not ready
yet?" The honest answer was that the SOP wasn't the only missing piece — `os_prep`,
`verify_baseline`, `ssh_equivalence`, and `asmlib_disks` are all real, reusable,
already-debugged roles, but every play in `site.yml` that invokes them has `hosts:
rac_nodes` or `hosts: rac_node1` baked in. A play's `hosts:` pattern can only be
*narrowed* by `--limit`, never widened — there was no `--tags`/`--limit` combination
that could point any of them at `oradbserv09`/`oradbserv10`. `#46`'s `gi_db_home_clone`
role was fully built and reviewed but had nothing upstream of it to actually bring
`oradbserv09`/`oradbserv10` to a state where it could run (`os_prep` never applied,
`/etc/oraInst.loc` wouldn't even exist — exactly what `gi_db_home_clone`'s own
preflight check from #46 would have caught, just later than necessary).

**Fix:** two additions, both minimal, reusing existing roles as-is — no role code
changed.

1. **`group_vars/standby_nodes.yml`** (new) — Ansible auto-loads `group_vars/<group
   name>.yml` for any host in that inventory group. This file redirects exactly four
   variables (`nodes`, `scan_name`, `scan_ips`, `cluster_name`) to their existing
   `standby_*` equivalents in `group_vars/all.yml` (`standby_nodes`,
   `standby_scan_name`, `standby_scan_ips`, `standby_cluster_name` — all already
   defined, unused until now) for any host in `standby_nodes`. Everything else
   (`oracle_base`, `db_home`, `grid_home`, `oracle_user`/`grid_user`, the `/u01`
   device, ASMLib disk naming) is deliberately left unoverridden — `usatclust2` is
   built to be architecturally identical to `usatclust1` in every way except cluster
   identity, which is exactly what makes Oracle Home cloning (#46) valid at all.
2. **New `site.yml` plays** targeting `hosts: standby_nodes` — a python3 bootstrap
   (mirrors the existing `rac_nodes` one), then `os_prep`, `verify_baseline`,
   `ssh_equivalence`, `asmlib_disks`, each under its own `standby_*`-prefixed tag
   (`standby_os_prep`, etc.) rather than reusing the `rac_nodes` plays' tags — running
   `--tags os_prep` alone should not silently also re-run against
   `oradbserv09`/`oradbserv10`, and vice versa; keeping them distinct keeps every
   `ansible-playbook` invocation targeted, which matters when trying to be deliberate
   about resource/time use.

**Deliberately not included in this fix:** `dns_bind` and `chrony` against
`standby_nodes` — neither is a dependency of `gi_db_home_clone` (a tar/fetch/copy/
extract sequence has no name-resolution or time-sync requirement), only of the actual
cluster-configuration step (`gridSetup.sh`/`cluvfy`), which isn't built yet. Adding
those plays now, ahead of the role that would need them, would be scope creep against
this project's own "don't build ahead of what's actually next" discipline. See
[`../../high-availability/README.md`](../../high-availability/README.md) Sections 7-8
for where they're planned.

**Confirmed working:** `--tags standby_os_prep` run against `oradbserv09`/`oradbserv10`
completed clean (`ok=50 changed=7 unreachable=0 failed=0` on each) — the
`group_vars/standby_nodes.yml` redirection and the new plays both work as designed.

## 48. `gi_db_home_clone`'s Clusterware preflight check crashed with `'dict object' has no attribute 'stdout'`, and separately, the manual "stop Clusterware first" instruction named the wrong command

Two related problems surfaced on the first real attempt to run `gi_db_home_clone`
after #46/#47:

**1. The stop command in the SOP was wrong.** James ran
`crsctl stop cluster -all`, which returned `CRS-4688: Oracle Clusterware is already
stopped` — looked successful — but a follow-up `crsctl check crs` still showed
`CRS-4638: Oracle High Availability Services is online`. `crsctl stop cluster` only
stops CRSD-managed resources (ASM, listeners, the database) and deliberately leaves
OHASD (Oracle High Availability Services, the lower daemon) running — it is **not**
equivalent to `crsctl stop crs`, which stops the entire stack (OHASD/CRSD/CSSD/EVMD)
but only on the **local** node (no `-all` flag — must be run once per node, as
root/sudo, not as `grid`). The original SOP text said "as grid," also wrong. Fixed in
[`../../high-availability/README.md`](../../high-availability/README.md) Section 6 —
now `sudo $GRID_HOME/bin/crsctl stop crs`, run explicitly on both `oradbserv05` and
`oradbserv06`.

**2. The role's preflight check itself crashed rather than reporting the mismatch
cleanly.** `Preflight: confirm Clusterware is actually stopped` registered
`crs_check`, then a `fail:` task referenced `crs_check.stdout` directly in a `when:`
— when the previous task's result genuinely lacks a `stdout` key (a `become`/
connection-level failure, as opposed to a normal nonzero-exit command result, which
still has `stdout`), Ansible raises `'dict object' has no attribute 'stdout'` instead
of evaluating the condition. **Fix:** the `when:` now checks
`crs_check.stdout is not defined or 'is online' in crs_check.stdout` — fails closed
(assumes NOT safe to proceed) either way, and the failure message branches to explain
which case it hit, including the `stop cluster` vs `stop crs` distinction from #1
directly in the error text so the next person hitting this doesn't have to find this
entry to understand it.

**UPDATE — the "fails closed" logic worked exactly as designed on the very next real
run, and surfaced a third, distinct problem:** after James actually ran `crsctl stop
crs` correctly on both nodes (`crsctl check crs` manually confirmed
`CRS-4639: Could not contact Oracle High Availability Services` — genuinely, fully
stopped this time), the preflight task itself came back as `MODULE FAILURE` rather
than a normal command result — meaning it hit the exact "stdout not defined" branch
above, by design, and failed the play instead of crashing or (worse) silently
proceeding. The `MODULE FAILURE` happened both times now — once while Clusterware was
still partially up, once after it was fully down — which points at the task's
execution context, not at Clusterware's actual state. **Fix:** added
`become_user: "{{ grid_user }}"` to the check task (it was implicitly root before,
Ansible's `become` default). Per Oracle's own documented privilege model, only
`crsctl start/stop/enable/disable crs` genuinely require root — `crsctl check crs`
is a read-only query the GI owner can run directly, so this is also the more
*correct* privilege model, not just a workaround. Also widened the failure message's
diagnostics (`module_stderr`/`module_stdout` before falling back to `msg`) so a real
`MODULE FAILURE` shows the actual remote error text next time instead of just the
generic wrapper string. **Not yet confirmed this was the actual root cause** — flagged
honestly, same as every unverified fix in this file, pending the next real run.

**UPDATE #2 — the previous fix's own theory was wrong, but it produced a real,
specific, useful error this time instead of a generic one:** switching to
`become_user: grid` didn't fix it — it changed `MODULE FAILURE` into a fully
diagnosable error: `Failed to set permissions on the temporary files Ansible needs
to create when becoming an unprivileged user (rc: 1, err: chmod: invalid mode:
'A+user:grid:rx:allow')`. This is a documented Ansible limitation, not an
Oracle/Clusterware issue at all: when `become_user` is anyone other than root,
Ansible has to hand the temp file it already created (as the connecting user) over
to that unprivileged user, and on some targets it does this via NFSv4/macOS-style
ACL `chmod A+...` syntax — which this node's GNU `chmod` doesn't understand, so the
handoff itself fails before the actual command ever runs. Root never hits this code
path (nothing to hand off — root can already read anything), which is almost
certainly why the *first* version of this task (plain root, before either of these
two updates) also failed differently — some part of the same become-permission
machinery, just surfacing as the more generic `MODULE FAILURE` message rather than
this specific chmod error.

**Fix, per James's explicit direction:** stop fighting Ansible's unprivileged-become
permission model in this role entirely. The check task is back to plain root
(`become: true`, no `become_user` override) — matching every other task in this role
(the tar/copy/unarchive steps were never changed, they were already plain root from
the start, which is also why James specifically asked for "tar the grid home and
oracle home as user root ... just tar and untar as root": root guarantees nothing in
either home tree gets skipped for a permission-denied read, without needing to
reason about grid-vs-oracle file ownership boundaries at all). The one exception,
deliberately kept as-is: the DB home `attachHome` step still runs as
`become_user: oracle` — that one is a genuine Oracle requirement (OUI expects to be
invoked by the actual software owner, not root), unrelated to this Ansible
limitation, and out of scope for James's tar/untar instruction.

**UPDATE #3 — found the actual root cause: `site.yml`'s own play definition, not the
task, not `become_user`, not Clusterware state.** Reverting to plain root produced yet
another different error — `sudo: a password is required` — while every other
root-`become` task in this entire project (dozens of them, against this exact node,
this whole session) has worked without a password prompt. That inconsistency was the
real tell: the `gi_db_home_clone` play in `site.yml` was declared with both
`hosts: localhost` **and an explicit `connection: local`**. Every task in this role
uses `delegate_to` — nothing runs on `localhost` itself — but an explicit
`connection: local` set at the *play* level pins **every** task in that play to a
local connection, delegated or not; it does not defer to `delegate_to`'s own
connection resolution the way the implicit default would. So every attempt to run
this role was actually trying to `sudo`/execute on the WSL2 control node itself, never
reaching `oradbserv05` at all — which explains all three previous distinct-looking
failures (`AttributeError` on missing `stdout`, the ACL `chmod` error, generic
`MODULE FAILURE`) as the same underlying problem showing up differently depending on
what state the *control node's own* sudo/become handling happened to be in at that
moment, not anything about Clusterware, `become_user`, or file permissions on the
actual target nodes.

**Fix:** removed `connection: local` from the play in `site.yml`. `hosts: localhost`
alone is sufficient for a control-node-only play — `delegate_to` on each task still
resolves the real connection (SSH, per `inventory/hosts.ini`) correctly without it.
No task-level code changes were needed for this fix; the `become_user`/root changes
from the prior two updates stay as documented (root throughout, oracle-user exception
for `attachHome`), now actually running against the right host.

**Confirmed working:** with `connection: local` removed, the Clusterware preflight
check reached `oradbserv05` for real and passed clean (`localhost: ok=2`) — the first
time any task in this role successfully executed against a real target node.

## 49. The `os_prep`-ran preflight checked the wrong file — `/etc/oraInst.loc`, which this role's whole design guarantees will never exist yet

Next task to actually run (the first one to reach `oradbserv09`/`oradbserv10`)
correctly failed — but for the wrong reason to have been checking in the first
place. `stat: path: /etc/oraInst.loc` came back `exists: false` on both nodes, which
is factually true, but `/etc/oraInst.loc` is written by an actual Oracle installer
run (OUI, via its `-invPtrLoc` handling) — confirmed via `grep -r oraInst.loc
roles/os_prep`, zero matches. `os_prep` never touches that file. Since this entire
role exists specifically to clone Oracle Homes onto `oradbserv09`/`oradbserv10`
*without* ever running an installer there, `/etc/oraInst.loc` was never going to
exist at this point in the build — checking for it was checking for a condition this
role's own design makes permanently false until the not-yet-built cluster
configuration step (`gridSetup.sh`) runs. A preflight check that can never pass isn't
a safety gate, it's a dead end.

**Fix:** check `{{ inventory_loc }}` (e.g. `/u01/app/oraInventory`) as a directory
instead — confirmed by reading `roles/os_prep/tasks/main.yml`'s "Create OFA directory
structure" task, which creates that exact path (owner `grid:oinstall`) directly and
unconditionally on every `os_prep` run, real signal that `os_prep` has actually
executed on the node. `grid_home` itself is also created empty by that same task, but
isn't used as the check here since `gi_db_home_clone`'s own later "ensure target GI
home directory exists" task recreates/re-owns it anyway, so checking it first adds
nothing `inventory_loc` doesn't already cover.

**UPDATE — the very next task had the same class of bug, one command over:**
`command: "id {{ oracle_user }} {{ grid_user }}"` — GNU coreutils `id` only ever
accepts a single username operand; `id oracle grid` isn't "check both users," it's a
syntax error (`id: extra operand 'grid'`), and the `command` module doesn't fail
until the process itself returns nonzero, so this had never actually validated
anything, on any node, ever — it would have reported "confirmed" even on a node
missing both users, since the error message itself has nothing to do with whether
oracle/grid exist. **Fix:** `shell: "id {{ oracle_user }} && id {{ grid_user }}"` —
two real, separate `id` calls, `&&`-chained so either one failing (user missing)
still fails the overall task, which is what this check was always supposed to catch.

**Confirmed working:** both preflight fixes together got the role past all its guard
checks for the first time and into real work — both GI and DB home tarballs were
created successfully on `oradbserv05` (multi-GB files, `tar` completed clean).

## 50. `fetch` OOM-killed itself pulling a multi-GB tarball off oradbserv05 — `rc: 137`, `Killed`

First genuinely new-territory failure — everything before this point was a bug in
this role's own guard logic; this one is a real Ansible/Oracle-scale mismatch. The
`fetch` module's actual mechanism is to run the `slurp` module on the remote host,
which reads the whole target file and base64-encodes it into a single JSON payload
returned over the connection — fine for config files and logs, fundamentally the
wrong tool for a multi-GB Oracle Home tarball. On the real run, the `slurp` process
on `oradbserv05` got killed (`rc: 137` = SIGKILL, `module_stdout` showed `Killed`
directly) — almost certainly the kernel OOM killer, since holding a multi-GB file
doubled in memory as base64 text is exactly the kind of allocation that trips it.
This was flagged as a known, deferred risk back in #46's first update ("fetch→
control-node→copy path... slower and more disk-hungry... acceptable for a first
correct pass, worth revisiting once this role has actually run once") — now that it
has actually run once, it's not just slower, it's broken outright.

**Fix:** replaced the `fetch` task with a plain `scp` shelled out from the control
node (`command:`, not delegated — this is the one task in the role that must run as
the scp *client*, on the control node itself, not on any managed node), using the
same `ansible_user`/`ansible_host` values and SSH identity Ansible's own connection
already relies on for every other task in this project. `scp` streams the file
rather than buffering the whole thing as base64 in a single process's memory.
Deliberately did NOT switch to `ansible.posix.synchronize` (rsync-based, the more
"official" fix for this exact problem) — it would work too, but adds a collection
dependency this role's header comment already chose to avoid, and plain `scp` needs
nothing beyond what's already proven working. Also added a `mode: '0644'` correction
on both tarballs right after they're created (as root) — `scp` pulls them as the
`ansible` connection user, not root, so if `oradbserv05`'s root umask were ever
stricter than the `022` assumed here, the pull would fail on a permission error
instead of a memory error; fixed proactively rather than waiting to hit that too.

**Confirmed working — the big one:** the `scp` fix got both tarballs all the way from
`oradbserv05` through the control node, copied to both `oradbserv09` and
`oradbserv10`, and extracted into place (`ok=15 changed=6`, zero failures through the
whole copy/extract chain). This is the first time this role has actually deployed
real GI/DB Oracle Home binaries onto the standby nodes.

## 51. `attachHome` failed with `S_OWNER_SYSTEM_EPERM` — it was trying to create `/etc/oraInst.loc` as a non-root user, which `/etc`'s own permissions don't allow

Only the very last task in the role failed this time. `runInstaller -attachHome`,
run as the `oracle` OS user (must be — OUI expects the actual software owner, not
root, per #48), threw `OiilNativeException: S_OWNER_SYSTEM_EPERM` from deep inside
OUI's `OiipgBootstrap.writeInvLoc → changeGroup → chgrp` call, with `'AttachHome'
failed` as the final line. Root cause: `-invPtrLoc /etc/oraInst.loc` pointed at a
file that genuinely didn't exist yet on `oradbserv09`/`oradbserv10` (confirmed
correctly by #49's fixed preflight — nothing has ever installed Oracle software on
these nodes before, that's the whole point of cloning). OUI tried to create that file
itself, as the `oracle` user — but `/etc` is root-owned, `755`, so a non-root user
can't create a new file there at all, regardless of group membership. In a normal
Oracle install, this exact file gets created by the **root** script (`orainstRoot.sh`)
that OUI generates for you to run by hand right after a first-ever software-only
install — this project's `-attachHome`-only flow never goes through that generation
step, so nothing was ever going to create the file for it.

**Fix:** added a task, as root, immediately before `attachHome`, that writes
`/etc/oraInst.loc` directly with the same two-line content Oracle's own installer
would have produced (`inventory_loc={{ inventory_loc }}` /
`inst_group=oinstall`, owner `root:oinstall`, mode `0664`) — standard, stable format,
unchanged across Oracle versions. With the file already present and correct before
`attachHome` runs, OUI's `writeInvLoc` should find nothing to change and skip the
`chgrp` call that was failing, rather than trying to create the file itself.
**Not yet confirmed against a real run** — same honesty flag as every other fix in
this file pending its first real test.

## 52. `asmlib_disks` marked zero disks on usatclust2 — its "which node marks the shared disks" gate was hardcoded to a variable that only ever points at oradbserv05

Found running `--tags standby_asmlib_disks` for real: every disk-marking task
(`Confirm the expected block devices exist`, `Mark each shared disk for ASMLib`,
etc.) reported `skipping` on both `oradbserv09` and `oradbserv10` — not failed, just
silently skipped — and the run correctly finished by failing on
`oracleasm listdisks found 0` once it tried to verify disks that were never marked in
the first place. Root cause: every one of those tasks gates on
`when: use_asmlib and inventory_hostname == dns_master`. `dns_master` is a single
global value (`oradbserv05`, `group_vars/all.yml`) — it identifies usatclust1's BIND
primary, and reusing it as "the node that marks ASM disks" happened to work for
`usatclust1` only because oradbserv05 is coincidentally both. For `usatclust2`,
`inventory_hostname` is `oradbserv09`/`oradbserv10` — never equal to `dns_master` —
so the condition was structurally false for this cluster from the start, not a
transient bug. No error, no warning, just silence, which is exactly why it took an
actual run (and the *next* task's real failure) to surface at all.

**Fix:** decoupled "who marks ASM disks" from "who is DNS master" with a new,
cluster-scoped variable, `asm_marking_node`. `group_vars/all.yml` defaults it to
`"{{ dns_master }}"` (so `rac_nodes`/usatclust1 behavior is unchanged — still
`oradbserv05`), and `group_vars/standby_nodes.yml` overrides it to
`"{{ standby_nodes[0].name }}"` (`oradbserv09`) for anything in that inventory group
— same pattern already used for `nodes`/`scan_name`/`scan_ips`/`cluster_name` in
that file (#47). All five `when:` conditions in `roles/asmlib_disks/tasks/main.yml`
now check `inventory_hostname == asm_marking_node` instead of `== dns_master`.

**Confirmed working — partially, and it immediately surfaced the next real bug:**
`asm_marking_node` correctly routed disk marking to `oradbserv09` this time (the
"confirm block devices exist" check ran and passed on all 6 disks) and correctly
skipped `oradbserv10` — the fix itself works exactly as designed. The very next task
hit a genuinely new, unrelated problem: see #53.

## 53. `lsblk`'s `PTTYPE` column doesn't exist on OL7 — `lsblk: unknown column: PTTYPE`

`Confirm each ASM device path is genuinely free` used
`lsblk -no MOUNTPOINT,FSTYPE,PTTYPE {{ item.device }}` to check a candidate disk
wasn't already carrying a mountpoint, filesystem, or partition table before
`oracleasm createdisk` runs against it — a real, deliberate safety check (see #5),
not incidental. The `PTTYPE` column, though, was added to `lsblk` in a later
util-linux release than what OL7 ships (util-linux 2.23.2) — the command failed
outright with `lsblk: unknown column: PTTYPE` on every disk, on the very first real
run against `oradbserv09`'s actual shared disks. This wasn't caught earlier because
nothing in this project had exercised this specific task against a genuinely fresh
set of disks before (`usatclust1`'s 6 disks were marked once, early in the project,
and never re-verified through this exact code path since).

**Fix:** replaced the `lsblk` column check with `blkid -o value -s TYPE
{{ item.device }}` — `blkid` reports the on-disk signature type directly (filesystem
name like `xfs`/`ext4`, or `dos`/`gpt` if a partition table is present, or nothing at
all if the device is genuinely blank) and doesn't depend on a `lsblk` column that's
version-gated. `blkid` exits `2` with empty output for a clean device — added
`failed_when: false` to the check task since that's the expected, good outcome, not
an error; the following `fail:` task's logic (fail if `stdout` is non-empty) needed
no changes, since `blkid`'s "found something" output shape is exactly the same
truthy/falsy signal `lsblk`'s combined column output was providing before.

## 54. `oracleasm createdisk` against a raw disk fails — "Device is not a partition" — I asserted the opposite as settled fact, and I was wrong

James ran `oracleasm createdisk ASMDISK01 /dev/sdd` by hand as a direct test and got
`Device "/dev/sdd" is not a partition`. In the previous turn I'd told him whole-disk
`oracleasm createdisk` (no partition) was "standard, fully-supported classic ASMLib
practice" and that partitioning "isn't required" — stated as settled fact, not
hedged, and it was wrong. He called it out directly, cited his own real-world
experience, and told me to verify rather than take my word for it. Verified via web
search and Oracle's own current 19c Linux documentation ("Configuring Disk Devices to
Use Oracle ASMLIB"): the documented procedure is to create a single whole-disk
partition with `fdisk`/`parted` first, then run `oracleasm createdisk` against the
**partition** (e.g. `/dev/sdb1`), not the raw disk. This role never had a
partitioning step at all — it went straight from "confirm the raw disk is blank" to
`oracleasm createdisk {{ item.device }}` on the raw device, and had simply never been
exercised against a genuinely fresh, never-manually-partitioned disk before now
(`usatclust1`'s original 6 disks were almost certainly partitioned by hand outside
Ansible, going by James's own stated normal practice — never captured in this repo).

**Fix:** added three tasks between the "confirm free" check and `createdisk`: install
`parted` (package module, no new Ansible collection dependency — matches this
project's own established preference, e.g. #50's `scp`-over-`synchronize` choice),
`parted -s {{ item.device }} mklabel gpt mkpart primary 0% 100%` to create one
GPT partition spanning the whole disk, then `partprobe {{ item.device }}` so the
kernel registers the new partition device before anything reads it. `createdisk` now
targets `{{ item.device }}1` (the partition), not `{{ item.device }}` (the raw disk).
Safe against a second run touching an already-marked disk: the earlier "confirm free"
`blkid` check (#53) will correctly find the new partition-table signature on a re-run
and fail closed, same as it would for any other already-in-use disk — partitioning
doesn't weaken that guard.

**Not yet confirmed against a real run.** For all future primary/standby builds, this
means James only needs to hand over the raw `/dev/sd*` paths for a blank set of
shared disks — this role now partitions them itself before marking, matching his
stated workflow going forward.

## 55. A standby-only run was touching oradbserv05/06 — the `always` tag on both bootstrap plays fires on every invocation, regardless of --tags

James asked directly: `--tags standby_asmlib_disks` shouldn't touch `oradbserv05`/`06`
at all — what's it doing there? Real question, not just noise: both python3-bootstrap
plays in `site.yml` (one for `rac_nodes`, one for `standby_nodes`) were tagged
`[always]`. `always` is an Ansible special tag — it makes a play run on **every**
`ansible-playbook` invocation regardless of which `--tags` were requested, as long as
the play's `--skip-tags` doesn't exclude it. That's why running a `standby_nodes`-only
tag still connected to `oradbserv05`/`06`: the `rac_nodes` bootstrap play doesn't care
what tag was actually requested, it just always fires for its own hosts. Harmless in
practice (a `raw: test -e` check, no changes, no config touched), but pointless
overhead and — since `oradbserv05` is live, hosting `apexdb` — worth avoiding on
principle, not just for efficiency.

**Fix:** replaced `tags: [always]` on both bootstrap plays with an explicit list of
every real tag that actually needs that group's python3 present first —
`[os_prep, verify_baseline, dns_bind, chrony, asmlib_disks, ssh_equivalence,
patch_before_config, grid_infrastructure, db_software, dbca_noncdb]` for the
`rac_nodes` play, `[standby_os_prep, standby_verify_baseline, standby_ssh_equivalence,
standby_asmlib_disks, gi_db_home_clone]` for the `standby_nodes` play. Preserves the
original guarantee (python3 exists before any module-based task in that group runs,
even on a completely fresh node) for every tag that's actually relevant, while a
standby-only run no longer connects to `oradbserv05`/`06` at all, and vice versa.

## 56. DNS and chrony for usatclust2 — one needed a new play, the other didn't; both looked identical at first glance

**SUPERSEDED by #59 — the "one shared BIND pair for the whole lab" design this entry
describes was reversed at James's explicit direction.** Left in place below as a
record of the reasoning at the time, not deleted, per this file's own convention —
see #59 for the current design (independent BIND pair per cluster) and #58 for the
step in between that first tried a "client-only" middle ground before landing there.

Building high-availability/README.md Sections 7-8. Both roles looked like they'd need
the same treatment as `os_prep`/`verify_baseline`/`ssh_equivalence`/`asmlib_disks`
(#47) — a new `group_vars/standby_nodes.yml`-backed play targeting `standby_nodes`.
Reading both roles' actual task files before building anything showed that's wrong
for `dns_bind` and right for `chrony`, for different reasons:

**`dns_bind`** runs a **single BIND pair for the entire lab domain**
(`oradbserv05` primary, `oradbserv06` secondary) — not one nameserver per cluster.
Its zone-rendering tasks are gated `when: inventory_hostname == dns_master` (a fixed
global value, always `oradbserv05`) — running this role against `standby_nodes` would
never render anything (same structural-skip class of bug as #52), AND its
`Enable and start named` task has no `when:` guard at all, so it would have tried to
install and start a **second, unwanted BIND service** on `oradbserv09`/`10` — wrong
architecture, not just a skipped condition. The actual fix: extend
`zone.forward.j2`/`zone.reverse.j2` to loop over `standby_nodes`/`standby_scan_ips` in
addition to `nodes`/`scan_ips`, in the **same** zone file `oradbserv05` already
renders — same pattern `os_prep`'s `hosts.j2` already uses for `/etc/hosts`. No new
site.yml play; re-running the existing `--tags dns_bind` picks up the new records.
`oradbserv09`/`10` themselves don't need a `named` service or even their own
`/etc/resolv.conf` change to function right now — `/etc/hosts` (already rendered by
`standby_os_prep`, covers both clusters) resolves everything they need directly via
normal `files`-before-`dns` NSS order, same reasoning already established for
`usatclust1`'s SCAN entries in #12.

**`chrony`**, by contrast, gates its client branch on
`when: inventory_hostname != chrony_master_hostname` — an inequality against a fixed
*external* master (`oemserver01`), which is true for any node that isn't
`oemserver01`, `oradbserv09`/`10` included. No hidden per-cluster assumption, nothing
in `chrony.conf.client.j2` referencing cluster identity either. This one genuinely
just needed the straightforward new play — `hosts: standby_nodes, tags:
[standby_chrony]`, role reused as-is, zero code changes.

**Lesson applied going forward:** the "reuse the same role for the standby cluster"
pattern from #47 is not one-size-fits-all — each role's actual `when:` gates
determine whether it needs a new group_vars redirection, a content extension to an
existing single shared artifact, or nothing at all. Worth reading the role before
assuming which category it falls into, same discipline that caught #52 and #55.

## 57. Standby build order didn't match the primary's own proven sequence — SSH equivalence and cloning were scheduled ahead of DNS/chrony

James caught this by comparing the standby SOP against `installation/README.md`
directly: that document's own proven order is `os_prep` (6) → DNS (7) → chrony (8)
→ ASMLib (9) → SSH equivalence (9a) → software staging/install (10-12) → DBCA (13) —
every OS-level prerequisite lands *before* anything Oracle-software-related touches
the node. The standby `site.yml` plays, built incrementally across several separate
turns as each section got added, ended up in `os_prep` → `verify_baseline` →
`ssh_equivalence` → `chrony` → `asmlib_disks` → `gi_db_home_clone` — SSH equivalence
too early, and worse, no play ordering enforced DNS/chrony being fully done before
`gi_db_home_clone` (the standby's equivalent of "install the Oracle software") ran.
James's point: cloning the Oracle Home doesn't change what the *node* needs before
Oracle software touches it — a standby node should reach that ready state exactly
like a freshly built primary node does, independent of which mechanism (fresh
install vs. clone) puts the software there.

**Fix:** reordered the `standby_nodes` plays in `site.yml` to `os_prep` →
`verify_baseline` → *(DNS — re-run `--tags dns_bind`, documented inline since it has
no `standby_nodes` play of its own, see #56)* → `chrony` → `asmlib_disks` → `ssh_equivalence`
→ `gi_db_home_clone`, matching `installation/README.md`'s own sequence exactly.
`high-availability/README.md`'s section numbering updated to match (DNS now Section
3a-equivalent positioning; full renumber, not just a reshuffled task list). No role
or tag changes — this was purely an ordering/sequencing bug, not a functional one;
every individual play still worked correctly in isolation, they just weren't gated
to run in the right order relative to each other.

## 58. `--tags dns_bind` couldn't be targeted at the standby cluster at all — not a `--limit` gap, a real missing capability

**SUPERSEDED by #59 — the "client-only" fix below (gate server tasks, give
oradbserv09/10 resolv.conf pointed at oradbserv05/06) was itself replaced one turn
later, once James clarified he wanted usatclust2's DNS fully independent, not just a
client of usatclust1's BIND pair.** Left in place as a record of the reasoning at
the time — the diagnosis here (why a bare `--limit` couldn't have worked) is still
accurate and still the right way to think about the problem; only the chosen fix
changed. See #59 for the current design.

James asked directly why `--tags dns_bind` wasn't customizable per-cluster and tried
`--tags dns_bind oradbserv09,oradbserv10` (missing `--limit`, but the underlying ask
was legitimate regardless of exact syntax). The honest answer: even with correct
`--limit oradbserv09,oradbserv10` syntax, that command would have matched **zero**
hosts and silently done nothing — the `dns_bind` play's `hosts:` is `rac_nodes`
(`oradbserv05`/`06`) only, `--limit` can narrow a host set, never widen it outside
what a play's `hosts:` pattern already includes. So this wasn't a syntax question,
it exposed a real, missing piece: `oradbserv09`/`10` had no path to get real
DNS-client configuration (`/etc/resolv.conf` pointed at the BIND pair,
`NetworkManager` `dns=none` override) at all — they were relying solely on
`/etc/hosts`, which is NOT the same setup `oradbserv05`/`06` themselves get. Given
James's own standing principle from #57 ("the standby node should reach that ready
state exactly like a fresh primary node does"), that's a real parity gap, not
cosmetic.

**Also found while fixing it:** the `Point resolv.conf` task's second-nameserver
logic was a ternary — `nodes[1].public_ip if inventory_hostname == dns_master else
nodes[0].public_ip` — written assuming only two possible callers (`dns_master` or
`dns_secondary`). Run against a third host (`oradbserv09`), the `else` branch always
resolves to `nodes[0].public_ip` (`oradbserv05`) — both nameserver lines would have
pointed at the same IP, not a crash, just quietly wrong.

**Fix:** two parts.
1. Every server-only task in `roles/dns_bind/tasks/main.yml` that wasn't already
   gated to `dns_master`/`dns_secondary` (firewalld checks, `Enable and start
   named`) now is — running this role against a third host no longer tries to
   install/start a BIND service there.
2. New play in `site.yml`, `hosts: standby_nodes, tags: [standby_dns_bind]`, reusing
   the same role — with the tasks above now gated off for `oradbserv09`/`10`, what's
   left running is exactly the client-config tasks (resolv.conf, NetworkManager),
   giving them real DNS-client parity with `oradbserv05`/`06`. The ternary was
   simplified to always resolve the second nameserver as `nodes[1].public_ip`
   (`oradbserv06`) — correct for every caller, `rac_nodes` and `standby_nodes` alike,
   no self-reference edge case to reason about.

Full standby DNS setup is now two commands, in order: `--tags dns_bind` (server,
picks up `usatclust2`'s zone records) then `--tags standby_dns_bind` (client config
on `oradbserv09`/`10` themselves).

## 59. DNS should be fully independent per cluster, not a shared lab-wide service — James corrected the architecture directly, twice in a row

James's response to #58's fix: "I want you to know that oradbserv0506 and
oradbserv09/10 are completely separate and independent clusters and their DNS
resolution should be independent from each cluster... I want these scripts to be
server agnostic." Direct, correct pushback on the design in #56/#58 — both of which
built toward "one shared BIND pair for the whole lab domain," reasoning by analogy to
`/etc/hosts` (one file, both clusters' entries) without checking whether that
analogy actually holds for DNS. It doesn't: `/etc/hosts` has no concept of
authority or ownership — any file can list any name. DNS zone authority is
different — the entire point of `usatclust1`'s OCR/voting being genuinely separate
from `usatclust2`'s (a principle already established elsewhere in this project) is
that neither cluster depends on the other's infrastructure being up or correct.
A shared BIND pair violates that: if `oradbserv05`/`06` are ever down or
misconfigured, `usatclust2` would lose DNS resolution for its own names too, despite
being otherwise fully healthy and independent.

**Fix:** made the `dns_bind` role genuinely cluster-agnostic rather than
lab-domain-specific:

1. **Reverted the zone-file merge from #56** — `zone.forward.j2`/`zone.reverse.j2`
   no longer loop over `standby_nodes`/`standby_scan_ips` in addition to `nodes`/
   `scan_ips`. Each rendered zone now contains only the records for whichever
   cluster's group is actually invoking the role — nothing role-specific needed
   here, since `nodes`/`scan_name`/`scan_ips` were already correctly redirected per
   group back in #47.
2. **The one variable that was still hardcoded lab-wide**: `dns_master`/
   `dns_secondary`/`dns_master_ip`, previously left un-redirected in
   `group_vars/standby_nodes.yml` on the (now-reversed) assumption that DNS was
   shared infrastructure like `chrony_master_*` genuinely is. Added the redirection
   — `dns_master: "{{ standby_nodes[0].name }}"` (`oradbserv09`),
   `dns_secondary: "{{ standby_nodes[1].name }}"` (`oradbserv10`),
   `dns_master_ip: "{{ standby_nodes[0].public_ip }}"` — same pattern already
   proven for `asm_marking_node` (#52).
3. **`--tags standby_dns_bind` now stands up a genuinely independent, standalone
   BIND primary/secondary pair on `oradbserv09`/`10`** — not a client of
   `oradbserv05`/`06` (#58's design), not a shared multi-cluster zone (#56's
   design). No dependency on the `rac_nodes` `dns_bind` play running first or ever.
   The gating added in #58 (server-only tasks limited to
   `inventory_hostname == dns_master or == dns_secondary`) turned out to be exactly
   the right piece of infrastructure for THIS design too — it's what makes the same
   role correctly stand up a full server pair for whichever group's `dns_master`/
   `dns_secondary` happen to resolve to, not just gate down to client-only.

**What stays intentionally shared, not per-cluster:** `chrony_master_*`
(`oemserver01`) — a genuinely different kind of dependency, one physical time
source for the whole lab, not a per-cluster service like DNS. `domain` (`usat.com`)
also stays shared — both clusters' hostnames live in the same DNS namespace, they
just each have their own independent, non-zone-transferring authority over their
own subset of it. No client in this lab ever queries the "wrong" cluster's BIND
pair for the other cluster's names — cross-cluster lookups go through `/etc/hosts`
(#12's established pattern), not DNS.

## 60. `standby_verify_baseline` failed with "2 gap(s)" right after a clean `standby_os_prep` — not a create-timing issue, an ownership one

James's own theory going in: "Verify baseline will fail if the directories have not
be[en] created by standby_os_prep... The directories get created after clone." A
real run's `verify_baseline : List every gap found` output named the actual two
gaps precisely, on both `oradbserv09` and `oradbserv10`:

```
- /u01/app/grid/19.3.0 missing or not owned by grid
- /u01/app/oraInventory missing or not owned by grid
```

**The theory didn't hold up against the actual role code** — `os_prep`'s "Create
OFA directory structure" task creates `oracle_base`, `grid_home`, `inventory_loc`,
and `staging_dir` (plus its three subdirs) in one ungated loop, unconditionally,
with zero dependency on `gi_db_home_clone` having run, same as it already does for
`oradbserv05`/`06` pre-clone. Directories don't wait on cloning to appear. The
`verify_baseline` check itself is `not item.stat.exists or item.stat.pw_name !=
item.item.owner` — either the missing case OR a wrong-owner case produces the same
"missing or not owned by" wording, which reads like a create-timing problem even
when the real issue is ownership.

**Actual cause:** this project made several `gi_db_home_clone` attempts against
`oradbserv09`/`10` earlier, before the standby build order was corrected (#57) —
the S_OWNER_SYSTEM_EPERM/chmod/sudo failures earlier in this session. Those
attempts' directory-creation and tarball-extraction tasks run as root via
`become: true` and don't set `owner: grid` the way `os_prep`'s OFA loop does —
almost certainly leaving `/u01/app/grid/19.3.0` and `/u01/app/oraInventory`
root-owned (or oracle-owned) from those earlier, out-of-order runs, rather than
genuinely missing.

**Fix:** none needed in the role itself — `os_prep`'s OFA directory task has no
"skip if already touched" guard on `grid_home`/`inventory_loc` (unlike the
`/u01`/`/u01/app` lifecycle-aware checks in #30, which deliberately don't fight
`root.sh`'s later re-ownership), so simply re-running `--tags standby_os_prep`
reasserts `grid:oinstall` on both paths and clears the gap. Confirmed as the
correct remedy, not yet confirmed against a re-run's actual output.

## 61. `ssh_equivalence` hardcoded `groups['rac_nodes']` in two tasks — same "not cluster-agnostic" bug class as `dns_bind` (#58) and `asmlib_disks` (#52), just not caught yet because it happened to be invisible on the primary cluster

While investigating a `known_hosts` "differs" warning during manual SSH testing
between `oradbserv09`/`10` (benign — `known_hosts` entries keyed by IP vs. hostname
capturing different host keys, typical of a freshly-built/cloned VM whose `sshd`
host key was still settling when `ssh-keyscan` ran; the role fully replaces
`known_hosts` via `copy:` each run, so a fresh re-run resolves it), a read of
`roles/ssh_equivalence/tasks/per_user.yml` turned up a real, separate bug: the
"Authorize every peer host's public key on this node" task and the "Verify
equivalence" task both looped over `groups['rac_nodes']` — a literal, hardcoded
inventory group name, not `nodes` (the cluster-agnostic variable `main.yml`'s own
`ssh_keyscan_targets` already correctly uses, redirected per `group_vars/<group>.yml`
the same way `dns_bind`/`asmlib_disks` are).

`groups['rac_nodes']` is inventory-global — unaffected by which group the play
currently targets. Concretely, for `--tags standby_ssh_equivalence`
(`hosts: standby_nodes`): run in isolation, `hostvars['oradbserv05'/'06']` are
undefined in that play, so the `when: hostvars[item].ssh_equiv_pubkey is defined`
guard silently skips every iteration — `oradbserv09` and `oradbserv10` never
actually get each other's key authorized by this role at all. Worse, if this play
is ever run in the same `ansible-playbook` invocation as `--tags ssh_equivalence`
(both plays live in the same `site.yml`), `oradbserv09`/`10` would end up
authorizing `oradbserv05`/`06`'s `grid`/`oracle` keys onto themselves — a genuine
cross-cluster SSH leak, directly contradicting the independent-clusters design
established in #59.

**Fix:** both loops now use `{{ nodes | map(attribute='name') | list }}` instead
of `{{ groups['rac_nodes'] }}` — correctly resolves to `[oradbserv05, oradbserv06]`
for the primary play, `[oradbserv09, oradbserv10]` for the standby play, no
cross-cluster leakage either way. Not yet confirmed against a real run —
`--tags standby_ssh_equivalence` should be re-run after this fix (safe,
idempotent — `lineinfile`/`copy` don't remove any equivalence a prior manual
workaround may have already established) to confirm `oradbserv09`↔`10` mutual
equivalence is actually in place via Ansible now, not just from whatever manual
testing got it working before.

## 62. Pre-seeding an IP-keyed `known_hosts` entry alongside the hostname-keyed one triggers OpenSSH's `CheckHostIP` mismatch warning — confirmed on a real self-loop, not just theoretical

A real manual test — `oradbserv10` sshing to itself as `grid`, via its own FQDN —
hit `Warning: the ED25519 host key for 'oradbserv10.usat.com' differs from the key
for the IP address '192.168.56.185'`, with `/etc/ssh/ssh_known_hosts` showing two
genuinely different stored keys: one at the line matching the hostname, one at the
line matching the IP. Connecting by short name (`oradbserv10`, no domain) or to
the peer node showed no warning at all — this was specific to the IP-keyed entry
for the box's own identity.

**Root cause: OpenSSH's `CheckHostIP` (on by default) stores and cross-checks a
SEPARATE known_hosts entry keyed by the resolved IP address, in addition to the
hostname-keyed entry, specifically to catch DNS spoofing.** This role's
`ssh_keyscan_targets` pre-seeded three identities per node (short name, FQDN, and
`public_ip`) from one `ssh-keyscan` command, on the assumption that scanning all
three in one pass would keep them consistent. That assumption doesn't hold:
`ssh-keyscan` opens a separate TCP connection per target string, with no guarantee
both land in the same instant — and this project's own lab nodes are exactly the
case where host keys regenerate out from under a stale scan (freshly
cloned/rebuilt VMs, already documented in `per_user.yml`'s own comment). Once the
name-keyed and IP-keyed entries diverge, `CheckHostIP` warns on every subsequent
connection by hostname, and can escalate to a hard `Host key verification failed`
refusal if the interactive prompt isn't answered (confirmed — the first sighting
of this in the session turned out to be that, a red herring unrelated to this
entry's actual bug).

**Fix:** dropped `nodes | map(attribute='public_ip')` from `ssh_keyscan_targets`
entirely — `main.yml` now only pre-seeds short-name and FQDN identities. No IP
entry ever gets pre-populated for `CheckHostIP` to compare against, so there's
nothing to drift out of sync in the first place; OpenSSH's client adds its own
IP-keyed entry dynamically on first real connection, taken from that same live
session, self-consistent by construction. Nothing in this project's Oracle
tooling (`cluvfy`, `gridSetup.sh`, GI's own SSH equivalence) ever connects by raw
IP — every node reference comes from the response file's hostname list — so
dropping the pre-seeded IP identity costs nothing functionally. Re-running
`--tags standby_ssh_equivalence` (or `--tags ssh_equivalence` for the primary
cluster) fully regenerates `known_hosts` via `copy:` (replace, not append), so the
existing stale IP-keyed lines are gone the moment it's re-run — no manual
known_hosts cleanup needed. Not yet confirmed against a fresh run.

## 63. `per_user.yml`'s "belt-and-suspenders" `~/.ssh/config` (`UserKnownHostsFile /dev/null`) actively defeated the role's own primary fix — every connection looked brand-new, forever

After #62's fix (dropping the pre-seeded IP identity from `ssh_keyscan_targets`)
and a re-run, James reported it got WORSE, not better: every single `ssh
grid@peer date` — including two back-to-back calls to the exact same host —
printed `Warning: Permanently added the ECDSA/ED25519 host key for IP address
'X' to the list of known hosts.` every time, when it should have been silent
after the first connection.

**Root cause:** `per_user.yml` deploys `/home/{{ ssh_user }}/.ssh/config` with:

```
Host oradbserv09 oradbserv09.usat.com oradbserv10 oradbserv10.usat.com
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
```

`UserKnownHostsFile /dev/null` means literally what it says — for any connection
matching that `Host` pattern, ssh writes new host-key entries to `/dev/null`
instead of a real file. Nothing is ever actually persisted, so every subsequent
connection looks like the first-ever connection to that host, and ssh "adds" (and
instantly discards) a key every single time. Worse: this setting applies to
exactly the same hostnames the role's own PRIMARY fix (the real
`ssh-keyscan`-populated `~/.ssh/known_hosts`, the task directly above this one in
`per_user.yml`) just spent effort populating — so this task was silently
nullifying the actual fix for grid/oracle's own login sessions the whole time.
This task's own comment already said it wasn't the real fix ("secondary,
belt-and-suspenders only") — it turned out to be actively harmful, not just
redundant.

**Why this didn't show up as clearly before #62's fix:** with the pre-seeded IP
entry still present, some connections were hitting the (broken, `CheckHostIP`-
triggering) real known_hosts file instead of this `/dev/null` redirect, depending
on exact matching/ordering — masking the deeper problem behind a different
symptom (#62's "differs" warning) rather than this one.

**Fix:** removed the `~/.ssh/config` task entirely from `per_user.yml`, and added
an explicit `file: state: absent` task in its place to remove the file this role
already deployed on prior runs — deleting the Ansible task alone doesn't undo a
file it already wrote to disk. The real known_hosts pre-population task
(directly above, in the same file) is sufficient on its own; nothing else in this
role needs `StrictHostKeyChecking no` to work correctly. Not yet confirmed
against a fresh run — re-run `--tags standby_ssh_equivalence` (and eventually
`--tags ssh_equivalence` for the primary cluster, which has the same stale file
sitting on `oradbserv05`/`06` from earlier runs of this same role) and confirm a
manual `ssh grid@peer date` / repeat self-loop now returns silently, exactly the
date and nothing else.

## 64. Even with #62/#63 fixed, short name vs. FQDN still disagreed — `CheckHostIP` comparing across TWO VALID BUT DIFFERENT key algorithms for the same sshd, not a stale/spoofed key

After #62 and #63 both landed, James re-tested and still saw inconsistency —
some short-name/FQDN pairs came back silent, others didn't, with no obvious
pattern: `oradbserv09`→`oradbserv09` (self, short name) printed a one-time
"Permanently added ... for IP address" notice (expected — first-ever connection
to that IP identity, now that #62 stopped pre-seeding it); `oradbserv10`→
`oradbserv09` (short name) hit a real `CheckHostIP` "differs" warning requiring
a `yes` to proceed, timestamped 6 seconds after a clean FQDN connection to the
same target.

**Root cause, confirmed from the actual log:** `oradbserv10`'s FQDN connection
to `oradbserv09.usat.com` negotiated an **ED25519** host key and (via
`CheckHostIP`) stored it under the IP-keyed entry for `192.168.56.184`. Six
seconds later, the short-name connection (`ssh grid@oradbserv09`) negotiated
**ECDSA** instead — a different algorithm entirely, not a different or stale key
of the same type — and `CheckHostIP` compared that against the ED25519 IP entry
from moments earlier and flagged a mismatch. `sshd` on these OL7 nodes offers
RSA, ECDSA, and ED25519 simultaneously (the OS default, unchanged by this
project); which one a given connection negotiates depends on what the client
already has cached for that *exact* target string, so the short name, the FQDN,
and the dynamically-added IP entry can each land on a different algorithm for
the literal same daemon — not a spoofed host, not a genuinely changed key,
`CheckHostIP` fundamentally assumes a host only ever presents one key and this
project's per-node multi-alias setup (short name + FQDN + IP, all valid ways to
reach the same box) breaks that assumption.

**Fix:** added a system-wide `ssh_config` block (`ssh_equivalence/tasks/main.yml`,
via `blockinfile`) disabling `CheckHostIP` — `Host * / CheckHostIP no`.
Deliberately narrow: `StrictHostKeyChecking` stays untouched (still enforced,
still real protection against an actually-changed key) — only the secondary
IP-based cross-check is disabled, since that specific check is what's
structurally incompatible with a multi-algorithm host reachable under several
names, not a security property this lab network actually needs (`CheckHostIP`
exists to catch DNS spoofing on networks where hostname-to-IP mappings might be
attacker-controlled; this is a VirtualBox host-only network with static,
project-controlled IPs). This is deliberately a different, narrower fix than
#63's mistake — that one disabled ALL host-key checking via
`UserKnownHostsFile /dev/null`; this one disables only the one specific
cross-check that's producing false positives, keeping real key verification
intact for the identities Oracle's tooling actually uses. Not yet confirmed
against a fresh run.

## 65. Configuring `usatclust2` against a CLONED GI home — confirmed against Oracle's own 19c cloning chapter, and what it meant for `grid_silent_install`

Section 9 (Configure the `usatclust2` cluster) was still Planned, reusing the same
two-phase `gridSetup.sh`/`config.sh` pattern Section 11 documents for a fresh
install — but `usatclust2`'s GI home didn't arrive via fresh media; it arrived via
`gi_db_home_clone` (tar/untar from `oradbserv05`'s already-installed, already-RU-
patched home). Rather than assume the fresh-install command just works unmodified
against a pre-populated home, checked Oracle's current 19c documentation directly:
[Clusterware Administration and Deployment Guide, ch. 7, "Cloning Oracle
Clusterware"](https://docs.oracle.com/en/database/oracle/oracle-database/19/cwadd/cloning-oracle-clusterware.html).

**Confirmed, not assumed:** for creating a NEW cluster from a clone (this
project's exact scenario — distinct from "Using Cloning to Add Nodes to a
Cluster," a different procedure for extending an EXISTING cluster), Oracle's own
documented Step 3 is simply: "run the `gridSetup.sh` utility in either
interactive or silent mode on one node, as you would when installing Oracle Grid
Infrastructure for a new cluster." No `clone.pl`, no `-attachHome`-equivalent for
the GI home specifically — and `clone.pl` itself is explicitly deprecated as of
19c, with Oracle's own guidance pointing at the plain software-only install flow
instead. This directly confirms `gi_db_home_clone`'s own design (deliberately
leaving the GI home unregistered, expecting `gridSetup.sh`'s normal flow to
register it — see #46) was correct, and that Section 9 is genuinely the SAME
`grid_silent_install` role Section 11 already uses, not a different mechanism.

**Two real adaptations were still needed, found by reading the role's actual
code, not assumed:**

1. **Hardcoded `groups['rac_nodes'][0]`/`[1]` throughout `grid_silent_install`**
   — 14 occurrences (every `delegate_to`, the `cluvfy -n` node list, both root.sh
   guidance messages). Same bug class as #52/#58/#61: inventory-global, so
   reusing the role via a `standby_nodes`-targeted play would have kept
   delegating every Phase A/B action to `oradbserv05`/`06` instead of
   `oradbserv09`/`10`. Fixed with a `set_fact` at the top of the role resolving
   `gi_node1`/`gi_node2` from the already-cluster-agnostic `nodes` variable (the
   same one `dns_bind`/`asmlib_disks`/`ssh_equivalence` already rely on), then
   replacing every `groups['rac_nodes'][0]`/`[1]` reference with those facts.

2. **`-applyRU`/OPatch update assume a fresh, unpatched install** — Phase A's
   `gridSetup.sh` call unconditionally passed `-applyRU {{ gi_ru_patch_path }}`,
   and a preceding block unconditionally staged/applied the GI OPatch zip. Both
   are wrong for a cloned home: it's already at the patched level (tarred from
   `oradbserv05` post-RU), and there's no RU/OPatch zip staged on `oradbserv09`/
   `10` at all — the OPatch-zip `stat` check would fail closed with nothing to
   find. Added `gi_apply_ru` (default `true` in `group_vars/all.yml`, overridden
   `false` in `group_vars/standby_nodes.yml`): the OPatch-update tasks are now
   gated `when: gi_apply_ru`, and the `-applyRU` flag itself is only included in
   the `gridSetup.sh` command line when `gi_apply_ru` is true.

**What did NOT need changing, confirmed by reading the actual guard logic rather
than assumed:** the software-extraction task's own `creates:
"{{ grid_home }}/gridSetup.sh"` guard already no-ops correctly against a
pre-populated (cloned) home — nothing to change there. The `cvuqdisk` RPM fetch
reads from `{{ grid_home }}/cv/rpm/` on whichever node is "node1" for the
CURRENT play; `cv/rpm/*` was never on `gi_db_home_clone`'s tar exclusion list, so
it's already present in the cloned home too. Both response-file templates
(`grid_install_swonly.rsp.j2`, `grid_install.rsp.j2`) already read `cluster_name`/
`scan_name`/`nodes` as plain, already-redirected variables — no template changes
needed, same reasoning as `dns_bind`'s zone templates.

**New site.yml play:** `standby_grid_infrastructure` (hosts: `standby_nodes`),
reusing `grid_silent_install` exactly as-is — the umbrella tag only, matching
this role's own stated primary workflow (see the role's header comment on
sub-tags being for targeted re-runs, not first-time use). Worth flagging
honestly: the role's internal sub-tags (`grid_stage`/`grid_install_software`/
`grid_configure_cluster`/`grid_storage`) are NOT parameterized per group — running
`--tags grid_stage` directly (bypassing the umbrella tag) would match that stage
in BOTH the `rac_nodes` and `standby_nodes` plays simultaneously, since both
plays' copies of the role carry the same inner tag. Not a problem for the normal
umbrella-tag workflow this role already documents as the supported path; a real
limitation only if someone reaches for a bare sub-tag directly against one
cluster only — not solved here, flagged for awareness.

## 66. `gi_db_home_clone` deployed the tarballs to EVERY target node — wrong. OUI does its own node-to-node propagation; a pre-populated peer node makes gridSetup.sh refuse it outright

First real run of `--tags standby_grid_infrastructure` failed immediately:

```
[FATAL] [INS-44002] The Oracle home location contains directories or files on
following remote nodes: [oradbserv10]. These nodes will be ignored and not
participate in the configured Grid Infrastructure.
```

**Root cause:** `gi_db_home_clone` copied and extracted both tarballs (GI and DB
home) onto EVERY node in `clone_target_nodes` — `oradbserv09` AND `oradbserv10`.
But `gridSetup.sh`, launched from one node with a cluster node list in its
response file, does its OWN propagation to every other listed node — over the
grid user's SSH equivalence, the same mechanism this session spent considerable
effort getting genuinely clean (#61/#62/#63/#64). It expects the OTHER nodes'
target directory to be empty so it can populate it itself; finding one already
populated, it doesn't merge or overwrite — it silently drops that node from
cluster participation and fails.

**This was confirmable by reading code already in the repo, not a new
discovery** — `grid_silent_install`'s own software-extraction task has always
been `run_once: true, delegate_to: gi_node1` (node1 only), with its own comment
explaining exactly this: "OUI copies GRID_HOME to every node listed in the
response file's clusterNodes parameter over the grid user's SSH equivalence...
you don't stage software or invoke the installer separately on node 2."
`db_silent_install`'s extraction/`runInstaller` tasks are identically
node1-only, for the identical reason. `gi_db_home_clone` was written before this
project had reason to look closely at that detail and got it wrong for both
homes — this fix makes it consistent with a mechanism the codebase already
demonstrated correctly elsewhere.

**Fix:** `gi_db_home_clone` now deploys (copies + extracts) both tarballs onto
`clone_target_nodes[0]` ONLY — never touches any other target node. The
preflight checks (os_prep readiness, oracle/grid OS users exist) still run
against EVERY target node, correctly — every node still needs its OS baseline
ready before `gridSetup.sh`'s own propagation reaches it, that part was never
wrong. `os_prep`'s own OFA-directory-creation task already leaves an empty,
correctly-owned `grid_home`/`db_home` on the untouched node(s) — exactly the
state `gridSetup.sh` expects to find there, confirmed by the primary cluster's
own successful install never needing Ansible to pre-populate `oradbserv06`
either.

**Also removed: the DB home's `attachHome` step and its `/etc/oraInst.loc`
pre-creation.** The original design's stated reason for `attachHome`-ing the DB
home immediately ("the DB home has no equivalent later 'install' step coming")
turned out to be based on the same wrong assumption this entry corrects —
`db_silent_install` uses the identical single-node-launch + OUI-propagation
mechanism as GI, so a later reuse of that role for the standby RDBMS layer (not
yet built — comes with the RMAN duplicate work) is the right place to register
`db_home`, symmetric with how `gi_db_home_clone` already deliberately leaves the
GI home unregistered for `grid_silent_install` to handle. Registering it early
via `attachHome`, on a guessed `ORACLE_HOME_NAME`, on a node whose binaries
weren't even fully propagated to its eventual peer, risked the same stale-
registration class of problem as #32 on the primary build. James flagged the
core issue directly and asked for the clone script to stop copying files to
remote nodes at all, deferring the DB home's own open question ("do we need
both nodes or just one") rather than guessing — this entry resolves that
question too: just one, same as GI, same as the primary cluster's original
install.

## 67. `INS-44002` persisted after #66's fix and a manual cleanup — hidden dotfiles, not visible ones, were the actual leftover

After #66's fix (deploy to `clone_target_nodes[0]` only) and a manual file
removal on `oradbserv10`, the SAME `gridSetup.sh` run hit the exact same
`[FATAL] [INS-44002]` again. James's own manual `cluvfy` run against
`oradbserv09`/`10` passed cleanly (same known false-positive pattern as #24 on
the primary cluster — cluvfy's bundled checks are stricter than what actually
blocks a real install), ruling out basic reachability/SSH as the cause and
correctly pointing back at the Oracle home location check itself.

**Root cause, confirmed against a real-world report of the identical error**
([Muhammad Asif, "Error: INS-44002"](http://muhammad-asif-dba.blogspot.com/2021/02/error-ins-44002-oracle-home-location.html)):
hidden dot-files/dot-directories left behind by a previous install or patch
attempt (`.opatchauto_storage`, `.patch_storage` in that report) trip this
check even when the directory LOOKS empty at a glance. Given `oradbserv09`/`10`
went through several earlier broken clone/install attempts this session before
#47/#57/#66's fixes landed, residual dotfiles from those attempts are the most
likely explanation — and a `rm -rf {{ grid_home }}/*`-style cleanup would not
have removed them, since shell globbing doesn't match dotfiles by default.
Oracle's own error text ("contains directories or files," no qualifier
excluding hidden ones) is consistent with this.

**Fix, in two parts:**

1. **Manual, immediate:** full `rm -rf` of the directory itself (not a wildcard
   clear) followed by a fresh `mkdir`, on `oradbserv10`:
   ```
   rm -rf /u01/app/grid/19.3.0
   mkdir -p /u01/app/grid/19.3.0
   chown grid:oinstall /u01/app/grid/19.3.0
   chmod 0775 /u01/app/grid/19.3.0
   ```
2. **Automated, permanent:** `grid_silent_install`'s Phase A block now wipes and
   recreates `grid_home` (full `state: absent` then a fresh `state: directory`,
   not a wildcard clear) on every node in `nodes` OTHER than `gi_node1`,
   immediately before invoking `gridSetup.sh` — gated by the same
   `phase_a_inventory_check.rc != 0` guard Phase A's own idempotency check
   already uses, so this can never run against, and can never wipe, an
   already-formed cluster's home. This protects against the SAME class of
   leftover-dotfile problem recurring on any future rebuild, not just this one
   incident. Two separate looped `file:` tasks (remove, then recreate) — not a
   `block:` + `loop:` combination, which is invalid Ansible syntax (already hit
   and documented once this session, on `gi_db_home_clone`'s own copy tasks).

## 68. `os_prep`'s `/u01`/`/u01/app` ownership guard trusted "owned by root" as proof `root.sh` had run — wrong, and it cascaded into `gridSetup.sh`'s inventory-location failure

After #67's fix cleared `INS-44002`, the very next `gridSetup.sh` attempt hit a
different error: `[FATAL] [INS-32031] Invalid inventory location` /
`[FATAL] [INS-32033] Central Inventory location is not writable`. James pushed
back correctly on the first read of this: `gridSetup.sh` is normally fully
capable of creating the central inventory location itself on a genuinely fresh
install — Oracle doesn't require it to pre-exist — so "not writable" (not
"doesn't exist") was the real clue that something else was blocking the
*creation* of it, not that the path itself was expected to already be there.

**Confirmed root cause:** `ls -la /u01/app` on both `oradbserv09` and
`oradbserv10` showed it owned `root:oinstall`, not `grid:oinstall`. `os_prep`'s
own pre-install ownership task for `/u01`/`/u01/app` (see #30) deliberately
skips re-asserting `grid:oinstall` once either path is root-owned — correct
reasoning in principle (`root.sh` legitimately re-owns both to `root:oinstall`
after a real install, and re-running `os_prep` shouldn't fight that) — but the
guard only checked *current ownership*, not whether `root.sh` had actually run.
On `oradbserv09`/`10`, `root.sh` has never once succeeded (Phase A has never
completed) — `/u01/app` ended up root-owned from something else entirely (most
likely a side effect of this session's own long troubleshooting history against
these two heavily-experimented-on nodes, timestamped from earlier today, not
from a real install). The guard read "root-owned" as "must be post-install" and
silently skipped fixing it on every single `os_prep` re-run — which meant
`grid` could no longer create `{{ inventory_loc }}` as a new child of a
root-owned parent, which is exactly what `INS-32031`/`INS-32033` were reporting
("not writable," because OUI's inventory-creation check fails the same way
whether the leaf directory is missing outright or its parent refuses the
write).

**Fix:** added a check for `/etc/oracle/olr.loc` — the Oracle Local Registry
pointer file, created specifically by `root.sh` (any phase) as part of its own
run, and by nothing else in this project's roles. Both ownership-guard `when:`
conditions now skip the fix only when the path is root-owned **AND**
`olr.loc` exists — real evidence `root.sh` ran, not just an ownership
coincidence. A node where `root.sh` has genuinely never run will always get its
`grid:oinstall` ownership re-asserted on every `os_prep` re-run now, regardless
of how it ended up root-owned in the meantime.

**Immediate unblock** (both standby nodes, root.sh confirmed never run there):
```
chown grid:oinstall /u01/app
```
Then re-run `--tags standby_grid_infrastructure` (or `--tags standby_os_prep`
first, now idempotently safe to confirm — with the fix above it'll reassert the
same ownership and no longer skip it).

## 69. ASM disks marked `grid:oinstall` instead of `grid:asmadmin` — the config file was already correct, the *running* oracleasm driver just never reloaded it

Once Phase A finally completed on both `oradbserv09`/`10` (see #68) and ASM
disks were marked, James flagged the live result directly: `ls -l
/dev/oracleasm/disks/` showed every `ASMDISK0N` owned `grid:oinstall`, not
`grid:asmadmin`. Oracle's documented convention (confirmed via WebSearch —
matches the `OSASM`/`asmadmin` privilege group this project already uses
everywhere else, e.g. `oracle.install.asm.OSASM=asmadmin` in
`grid_install_swonly.rsp.j2`) is `grid:asmadmin`.

**The confusing part:** `asmlib_disks/tasks/main.yml`'s own
`/etc/sysconfig/oracleasm` template already rendered `ORACLEASM_GID=asmadmin`
correctly — this was not a case of the role ever having the wrong value in
code. Grepping the file turned up nothing wrong at the config-content level,
which meant the bug had to be in what happened *after* the file was written,
not in the file itself.

**Confirmed root cause:** `oracleasm init` only *loads* the driver if it isn't
already loaded — confirmed against Oracle's own admin doc ("Administering
Oracle ASMLIB and Disks": `init`/`exit` "load or unload... without restarting
the system"), and against community sources describing the identical symptom.
If the driver was already initialized on a node — which it was here, almost
certainly from earlier troubleshooting on these same heavily-experimented-on
standby nodes, before `ORACLEASM_GID=asmadmin` was ever guaranteed correct at
that point in time — `oracleasm init` just prints "already initialized" and
does nothing. The corrected config file lands on disk, but the *running*
driver keeps whatever UID/GID it loaded under originally, and every disk
`createdisk` marks afterward inherits that stale in-memory group, not the
file's. Same class of bug as #68: code that was technically correct got
silently defeated by pre-existing live state the guard/task never accounted
for.

**Fix:** `asmlib_disks`'s "Configure oracleasm" task now registers its result
(`asm_sysconfig`), and a new task runs `oracleasm exit && oracleasm init`
(a full reload) whenever that registration shows the file actually changed.
Gating on `.changed` matters for safety, not just cleanliness — this must
never fire against a node where ASM is already up with mounted diskgroups
(`exit` unloads the driver out from under them), and gating on "the config
file just changed" means it can only ever fire the very first time the file
is written correctly, long before Phase B/storage brings a real ASM instance
up. Same "don't refight already-correct state" discipline as #68's `olr.loc`
guard.

**Immediate unblock for the two already-broken nodes** (as root, both
`oradbserv09` and `oradbserv10` — safe right now since neither has a live ASM
instance yet):
```
oracleasm exit
oracleasm init
ls -l /dev/oracleasm/disks/
```
Expect every `ASMDISK0N` to flip to `grid:asmadmin` immediately — this is a
live reload of the existing device nodes, not a `deletedisk`/`createdisk`
cycle, so it's non-destructive to the labels already written.

## 70. `config.sh` failed `[INS-30542]` on a garbled failure-group name — Ansible's `trim_blocks` silently merged three response-file properties into one

Phase B (`config.sh -responseFile grid_install.rsp`) failed immediately:
`[FATAL] [INS-30542] Failure group name: /dev/disk/by-label/
ASMDISK03oracle.install.asm.diskGroup.diskDiscoveryString=/dev/disk/by-label/*
is invalid. It does not start with an alphabet.` — a garbled value that's
obviously two different response-file properties glued together with no
separator, not a real ASM failure-group name anyone configured.

**Root cause:** `grid_install.rsp.j2`'s `disksWithFailureGroupNames` (line 113)
and `disks` (line 114) properties are each built with an inline
`{% for %}...{% endfor %}`, and both used to end their physical line
immediately after `{% endfor %}` with no blank line following. Ansible's
`template` module sets `trim_blocks=True` on its Jinja2 environment (confirmed
via WebSearch, and matches Ansible's own documented default) — this silently
removes the ONE newline immediately following any `{% ... %}` block tag. With
no blank line to absorb that, `disksWithFailureGroupNames`'s rendered value ran
straight into `disks=`'s literal text with no line break, which in turn ran
straight into `diskDiscoveryString=`'s literal text — three properties
collapsed into a single giant comma-separated blob that OUI parsed as one
`disksWithFailureGroupNames` value. Splitting that blob on commas shifted every
token after the merge point by one position, landing `diskDiscoveryString`'s
key=value text in a slot OUI expected to hold a failure-group name — hence
"does not start with an alphabet" (it starts with `/dev/disk/by-label/...`).

**Why Phase A never hit this:** `oracle.install.crs.config.clusterNodes`
(`grid_install_swonly.rsp.j2` line 36, and the identical property in
`grid_install.rsp.j2` line 59) has the exact same inline-`{% endfor %}`-at-
end-of-line shape, but both happen to already be followed by a genuine blank
line in the template before the next real content — that blank line absorbs
the one newline `trim_blocks` eats, leaving exactly one real line break
behind. `disksWithFailureGroupNames`/`disks`/`diskDiscoveryString` had no such
buffer between them, so the same underlying behavior stayed invisible until
this run.

**Fix:** added one blank line after each of `disksWithFailureGroupNames` and
`disks` in `grid_install.rsp.j2`, matching the pattern that already worked
for `clusterNodes`. Traced by hand (not executed — the sandbox's isolated
Linux environment was unavailable again this session,
`HYPERVISOR_VIRT_DISABLED`): with one blank line as a buffer, `trim_blocks`
eats one of the two newlines between properties and leaves exactly one behind,
same as the working `clusterNodes` case. Worth keeping as a general habit
going forward in this project's `.j2` templates: any property line built with
an inline `{% for %}...{% endfor %}` (or any other block tag) at the very end
of the line needs a blank line after it, or its trailing newline is not
guaranteed to survive rendering.

**Next step:** re-run `--tags standby_grid_infrastructure` (or
`--tags grid_configure_cluster` directly) — the "Render grid_install.rsp" task
is unconditional (no `creates:`/`when:` guard), so it re-renders fresh from
the corrected template on every run; no manual file cleanup needed on the
target node first.

## 71. `gi_node1`/`gi_node2` `set_fact` had no tags at all — invisible whenever the role is run with a narrow `--tags` filter instead of the whole role

Running `ansible-playbook site.yml --tags grid_configure_cluster` directly
(to retry just Phase B after #70's fix, without re-running the earlier
stages) failed immediately: `'gi_node1' is undefined`. Every task in
`grid_silent_install` that references `gi_node1`/`gi_node2` had been working
correctly all session — the bug was invisible until this run specifically
used a *narrow* tag filter.

**Root cause:** the `set_fact` task that derives `gi_node1`/`gi_node2` from
`nodes` (added earlier this session — see the cluster-agnostic
`gi_node1`/`gi_node2` redesign) was never given a `tags:` line at all.
Ansible only runs a task when `--tags` is passed if that task carries a
matching tag (or `always`) — an untagged task is silently skipped under any
`--tags` filter that doesn't happen to include the *whole play* by default.
Every previous run this session either passed no `--tags` at all or passed a
broader tag that happened to include this task's position in the play, so
the gap never surfaced. The moment a run asked for exactly one narrow sub-tag
(`grid_configure_cluster`), the `set_fact` task was skipped and every
downstream `gi_node1`/`gi_node2` reference broke.

**Fix:** added `tags: always` to the `set_fact` task. This is the same
category of fix `site.yml`'s own python3-bootstrap play already uses (`tags:
[always]`, see #17) for exactly this reason — a prerequisite value that every
other tag in the role depends on has to run regardless of which specific
sub-tag was requested, not just whichever tags happened to be passed
together historically.

## 72. Fixing #70 by explaining the bug inside the response-file template itself broke the template a second way — Jinja parses `#` as plain text, not a comment marker

The very next run after #70's fix (`--tags standby_grid_infrastructure`)
failed differently: `Encountered unknown tag 'endfor'` while trying to
render `grid_install.rsp.j2` at all — a hard Jinja2 parse error, not an OUI
runtime error this time.

**Root cause, entirely self-inflicted:** the explanatory comment added
alongside #70's fix described the bug using the literal tag delimiter text
`{% endfor %}`/`{% ... %}` *inside a `#`-prefixed line in the template
itself*. That `#` is only a comment character to Oracle's response-file
*consumer* (`config.sh`) — Jinja2 has no idea `#` means "ignore the rest of
this line" the way a `.rsp` file or a shell script would. Jinja's own comment
syntax is `{# ... #}`, a completely different delimiter. So the literal
`{% endfor %}` text written into that comment, meant purely as prose
describing the bug, got parsed by Jinja as a real, unmatched block-closing
tag, and the whole template failed to compile.

**Fix:** reworded the comment to describe the mechanism without ever writing
the literal `{%`/`%}` characters (e.g. "Jinja for-loop's closing tag" instead
of `` {% endfor %} ``). Checked the rest of `grid_install.rsp.j2` and
`grid_install_swonly.rsp.j2` for any other comment lines containing literal
Jinja delimiter text — none found; this was an isolated, one-time mistake
made while writing #70's fix, not a pre-existing pattern.

**Worth remembering for any future template comment in this project:** never
write literal `{%`, `%}`, `{{`, or `}}` character sequences inside a `.j2`
file's own comments when describing Jinja syntax in prose — Jinja parses the
entire file for those delimiters regardless of what non-Jinja comment
convention (`#`, `--`, `//`, etc.) the *rendered output* format uses. Wrap
literal Jinja syntax in Liquid's raw/endraw block tags if it genuinely needs to
appear verbatim, or just describe it in plain English instead, as done here.

## 73. `config.sh` failed `[INS-08109] ... / by zero` at `CreateASMDiskGroup` — `AUSize=0` isn't a valid allocation-unit size, it's a literal divisor

With #70-#72 fixed, `config.sh` got further — past response-file parsing —
and failed at a genuinely later validation stage: `[WARNING] [INS-08109]
Unexpected error occurred while validating inputs at state
'CreateASMDiskGroup'. ... SUMMARY: - / by zero`. That's a literal Java
`ArithmeticException` (`x / 0`), not a generic input-validation complaint —
something in OUI's diskgroup-sizing logic divided by an actual zero.

**Root cause:** `grid_install.rsp.j2` hardcoded
`oracle.install.asm.diskGroup.AUSize=0`. Oracle's own real, blank 19.3
`gridsetup.rsp` documents this field as one of `1/2/4/8/16/32/64` (MB,
default 4) — `0` was never a documented value, and isn't a recognized "let
Oracle auto-pick" sentinel either (that would normally be an *empty* value,
not a literal `0`, matching the empty field convention this project's own
diskgroup name/redundancy fields already know to avoid). Confirmed against a
real, independently-sourced, working 12.2/19c reference response file
(oracle-base.com's `grid_config.rsp`, from an actual documented two-node RAC
install): it sets `oracle.install.asm.diskGroup.AUSize=4` — Oracle's stated
default — never `0`. Allocation-unit size is a genuine divisor in OUI's own
diskgroup-sizing arithmetic (converting disk capacity into a number of AUs
to validate against the requested redundancy/failure-group layout); passing
a literal `0` there throws exactly the `/ by zero` this run hit.

**Fix:** changed `AUSize=0` to `AUSize=4`, matching both Oracle's documented
default and the confirmed-working reference file. Not parameterized into
`group_vars` for now — no reason yet to run this project at any AU size
other than Oracle's own default, and hardcoding the correct, documented
value here is clearer than adding a variable with only one sane setting.

**Next step:** re-run `--tags standby_grid_infrastructure` — same
unconditional "Render grid_install.rsp" task as #70, re-renders fresh from
the corrected template automatically.

## 74. `usatclust2` needed its own ASM disk-label convention (`SASMDISK`, not `ASMDISK`), a live relabel, and a disk-path-style change — all three confirmed by James, not guessed

James clarified that the primary cluster's own Phase B never hit #73's
`AUSize=0` bug because it was run manually, not through Ansible — and shared
the manual response file he used as a reference. That reference disagreed
with this project's Ansible template in three concrete ways, each confirmed
directly with James rather than assumed from the example alone:

1. **Disk labels.** The example used `SASMDISK1`/`SASMDISK2`/`SASMDISK3`, not
   this project's `ASMDISK01`/`02`/`03` convention. Confirmed: `SASMDISK` is
   the real, intended label convention for `usatclust2` specifically —
   distinct from `usatclust1`'s `ASMDISK` convention, not a typo or stale
   draft.
2. **Redundancy.** The example had no `redundancy=` line and blank
   failure-group names (`disk,,disk,,disk` — the same shape as a real
   EXTERNAL-redundancy reference file, oracle-base.com's `grid_config.rsp`).
   Confirmed: `usatclust2` should still use NORMAL redundancy with 3 real
   failure groups, matching `usatclust1`'s design (#9) — the blank-FG-name
   shape in the example wasn't meant to change that.
3. **Disk path style.** The example used `/dev/oracleasm/disks/<LABEL>`, not
   this project's `/dev/disk/by-label/<LABEL>` (#4). Confirmed: switch the
   template to `/dev/oracleasm/disks/*` to match what's proven to work.

**The complication #1 creates:** `oradbserv09`/`10`'s shared disks were
already `createdisk`'d under the OLD `ASMDISK01`-`06` labels earlier this
session (Phase A ASM verification, and the `grid:asmadmin` ownership fix in
#69) — before the `SASMDISK` convention was settled. Just changing
`group_vars` to the new labels isn't enough on its own: `asmlib_disks`' own
free-disk safety checks (#5) would refuse to `createdisk` over a device that
already carries a different ASM label.

**Fix, three parts:**

- `group_vars/standby_nodes.yml` now overrides `asmlib_disks` /
  `asm_diskgroup_data_disks` / `asm_diskgroup_data02_disks` /
  `asm_diskgroup_reco_disks` to the `SASMDISK1`-`6` convention (device
  order/paths unchanged from `group_vars/all.yml`'s own list — confirmed
  against oradbserv09's real device mapping earlier this session, e.g.
  `ASMDISK01 -> /dev/sdd1`). `SASMDISK4`-`6` (DATA02/RECO01) extend James's
  `SASMDISK1`-`3` naming by inference, not independently confirmed — flag if
  wrong.
- A new `asmlib_disks_rename_from` list (empty by default in
  `group_vars/all.yml`, set only in `standby_nodes.yml`) drives a new,
  idempotent task pair in `asmlib_disks/tasks/main.yml`: `oracleasm querydisk
  -p <old label>` to check whether the old-labeled disk still exists, then
  `oracleasm renamedisk <old> <new>` only for pairs that do — Oracle's own
  documented, in-place, non-destructive relabel mechanism (no data touched,
  no delete+recreate), safe specifically because nothing has attached to
  these disks yet. Re-running after a successful rename finds nothing under
  the old label and skips cleanly.
- `grid_install.rsp.j2`'s `disksWithFailureGroupNames`/`disks`/
  `diskDiscoveryString`, and the DATA02/RECO01 `asmca -createDiskGroup`
  commands in `grid_silent_install/tasks/main.yml`, all switched from
  `/dev/disk/by-label/` to `/dev/oracleasm/disks/`.

**Honest gap, not yet resolved:** whether the existing free-disk `blkid`
check (#5, `oracle.install.asm.diskGroup...` prereq tasks further down
`asmlib_disks/tasks/main.yml`) will trip AFTER a successful rename is
genuinely uncertain, not verified — it depends on whether OL7's older
util-linux/`blkid` (already flagged as inconsistent for `PTTYPE` in #53)
recognizes an ASMLib-labeled partition as a real `TYPE` signature. Rather
than guess a speculative skip-guard across 6+ downstream tasks without being
able to test it (sandbox unavailable again this session,
`HYPERVISOR_VIRT_DISABLED`), this was deliberately left alone. **If the next
run fails at "Fail if any ASM device path is already in use" after the
rename tasks report success,** that's the signal this gap is real — report
the actual `blkid` output and it'll get a proper fix grounded in what
actually happened, not a guess.

**UPDATE — resolved, and the gap above never materialized:** Phase B
(`config.sh`) completed cleanly. `crsctl check crs` shows the cluster fully
up, `asmcmd lsdg` shows `DATA01` (NORMAL) and `RECO01` (EXTERNAL) both
`MOUNTED`, `crsctl query css votedisk` shows all 3 voting files correctly on
`/dev/oracleasm/disks/SASMDISK1`-`3` in `DATA01`, and `ocrcheck` shows a
clean single OCR copy in `+DATA01`. The rename + relabel + path-style changes
all worked as designed on the first real run.

## 75. There is no DATA02 in this project's design — DATA01 + RECO01 only, corrected on both clusters

James corrected this directly: "There is no DATA02 only DATA01 and RECO01,"
with the exact split confirmed for usatclust2 —
`DATA01(SASMDISK1/SASMDISK2/SASMDISK3)`, `RECO01(SASMDISK4/SASMDISK5/
SASMDISK6)`. This matches real evidence already sitting in this doc from
earlier in the project: a real `kfod` listing on usatclust1 showed `DATA02`
never actually existed there either — at the time that was logged as "hasn't
been created yet," but it was never actually created at any point, on either
cluster. The code had continued to treat a `DATA02` diskgroup as a real,
expected part of the design regardless.

**Fix, applied to both clusters:**

- `group_vars/all.yml` (usatclust1): removed `asm_diskgroup_data02`/
  `asm_diskgroup_data02_disks` entirely. `asm_diskgroup_reco_disks` is now
  `[ASMDISK04, ASMDISK05, ASMDISK06]` — 3 disks, not 2. `DATA01` (01/02/03,
  NORMAL) is unchanged.
- `group_vars/standby_nodes.yml` (usatclust2): same shape —
  `asm_diskgroup_data_disks: [SASMDISK1, SASMDISK2, SASMDISK3]`,
  `asm_diskgroup_reco_disks: [SASMDISK4, SASMDISK5, SASMDISK6]`, no
  `asm_diskgroup_data02_disks` at all.
- `grid_silent_install/tasks/main.yml`: removed the "Create the DATA02
  diskgroup via asmca" and "Multiplex OCR to DATA02" tasks entirely (not just
  skipped/gated off — there's no DATA02 target for either to act on). OCR
  still gets real internal redundancy from `DATA01`'s own `NORMAL` setting (3
  failure groups) — the same mechanism voting relies on (#9) — so removing
  the OCR-multiplex-to-DATA02 step doesn't leave OCR with only one copy of
  anything; it just stops trying to multiplex into a diskgroup that was never
  real.

**Confirmed working:** the very next real run (Phase B `config.sh` on
usatclust2) shows exactly this shape live — `asmcmd lsdg` lists only `DATA01`
and `RECO01`, nothing else.

## 76. Data Guard build (Phases 1-8 of the uploaded SOP) — DB_UNIQUE_NAME stays `apexdb`, not the SOP's proposed `apexdb_pri` rename

The uploaded `standby_dataguard_creation.txt` (a real, MAA-grounded SOP:
RMAN active duplication, role-aware `log_archive_dest_n`, static `_DGMGRL`
listeners, Broker + FSFO) proposed renaming the primary's `DB_UNIQUE_NAME`
from `apexdb` to `apexdb_pri` in section 5.4, with just "bounce the
database" as the mechanism.

**That's incomplete for an already-`srvctl`-registered RAC database.**
Confirmed via WebSearch (Oracle's own `srvctl modify database` doc plus
several independent DBA write-ups agreeing on the same sequence): renaming
`DB_UNIQUE_NAME` on a registered RAC database actually requires `srvctl stop`
+ `srvctl remove database` (unregisters from CRS, doesn't touch files) →
`alter system set db_unique_name=... scope=spfile` → restart → `srvctl add
database`/`add instance` back under the new name. A plain bounce alone
leaves CRS still tracking the old name while the live instance reports the
new one — a real, documented gotcha, not a simplification the SOP made on
purpose.

**Decision (James, after being shown the real procedure):** keep the
primary's `DB_UNIQUE_NAME` as `apexdb` rather than take on the remove/re-add
cycle for a naming preference alone. The SOP's own section 5.4 explicitly
allows this: "If you cannot change DB_UNIQUE_NAME now, keep the existing
value... just ensure the standby uses a different DB_UNIQUE_NAME." The
standby gets its own, genuinely distinct name, `apexdb_stby`.

**Naming convention actually used going forward** (see the `dg_*` block in
`group_vars/all.yml`) — every other name from the SOP's section 3 table
substitutes `apexdb_pri` → plain `apexdb`:

- `db_unique_name` (primary): `apexdb` — unchanged, already existed.
- `dg_standby_db_unique_name`: `apexdb_stby`.
- `dg_primary_redo_service` / `dg_standby_redo_service`: `apexdb_dg` /
  `apexdb_stby_dg` — TNS aliases used by `log_archive_dest_n SERVICE=` and
  Broker's `DGConnectIdentifier`.
- `dg_primary_role_service_rw`/`_ro`: `apexdb_rw` / `apexdb_ro`.
- `dg_broker_config_name`: `apexdb_dg` — same literal string as
  `dg_primary_redo_service`, but a different namespace (a DGMGRL
  configuration name, not a `tnsnames.ora` alias) — not a real collision,
  and it's the standard real-world Data Guard convention, not an oversight.

**Scope decisions confirmed for the whole Data Guard build** (asked
directly, not assumed): Ansible drives every phase, with explicit `PAUSE`
tasks before genuinely risky/judgment-heavy steps — same pattern as
`root.sh`/`config.sh` elsewhere in this project. The Observer (SOP section
12, planned for `oemserv01`) stays a manual, documented step — that host
isn't in this project's Ansible inventory. Build proceeds one phase at a
time, validated against the real lab before moving to the next — same
approach that built Sections 8/9/11 this session.

**Phase 1 built this session:** `roles/dataguard_primary_prep` (SOP sections
5.1-5.7, minus 5.4's rename per the decision above) — verifies current
config, backs up the spfile, enables `FORCE LOGGING` and Flashback Database
(both idempotent, check-then-set), adds the 6 MAA-formula standby redo log
groups on `+RECO01` (idempotent per-group via a PL/SQL loop checking
`v$standby_log` before each `ADD`), sets the role-aware `log_archive_dest_n`/
`fal_server`/`dg_broker_config_file` parameters, and checks (never
auto-creates) the password file registration. Run with `--tags
dataguard_primary_prep`. Phases 2-8 (Net config, standby host prep, RMAN
DUPLICATE, convert to RAC, role services, Broker, FSFO/Observer) are not yet
built — next up, one at a time, per the pacing decision above.

## 77. `shell: >` (YAML folded scalar) silently destroys heredoc SQL blocks — every newline collapses to a space, and bash tries to parse the SQL as shell syntax

The very first real run of `dataguard_primary_prep` failed immediately:
`/bin/sh: -c: line 0: syntax error near unexpected token 'group#,'`, with the
entire multi-line `sqlplus <<'EOF' ... EOF` command shown in the error
output collapsed onto ONE line.

**Root cause:** every SQL-executing task in the new role used YAML's folded
block scalar (`shell: >`), not the literal block scalar (`shell: |`). Folded
scalars (`>`) fold every single line break between same-indentation lines
into a space — fine for an ordinary multi-word command split across lines
for readability, but fatal for a heredoc, which requires REAL newlines: `<<
'EOF'` only starts reading heredoc content from the physical lines that
follow it. With everything folded onto one line, bash sees `sqlplus ...
<<'EOF' set heading on ... select ... EOF` all as a single command line —
the heredoc redirect finds no following lines to read as its body, so bash
instead tries to parse the SQL text itself as further shell command syntax.
Semicolons are valid shell statement separators, so it gets partway through
before hitting `group#,` in a position that's syntactically invalid for
bash, and dies there specifically — not a coincidence tied to that one
query, just wherever the folded-together SQL first produces something bash
can't parse as a command.

**Fix:** changed every `shell: >` to `shell: |` in
`dataguard_primary_prep/tasks/main.yml` — literal block scalars preserve
newlines exactly, which is what a heredoc actually needs.

**This is a pre-existing bug in `dbca_noncdb` too, not something new to this
role.** Its 4 post-creation verification tasks (`redolog_check`,
`cdb_check`, `sqlpatch_check`, `invalid_object_check`) use the identical
`shell: >` + heredoc pattern — this role's tasks were written by copying
that exact pattern as the project's established precedent for running SQL
via Ansible. Fixed there too, for the same reason. **Not confirmed whether
this ever actually broke a real `dbca_noncdb` run** — those 4 tasks are
read-only/informational, run after `dbca -createDatabase` itself (a plain
`command:`, not a heredoc, so unaffected) already succeeds, and none of them
carry `failed_when: false` — meaning if one really did hit this bug on a
past run, the play should have stopped right there rather than silently
continuing. Since Phase 1 (primary database creation) is on record as
complete, either these tasks were never actually exercised in a single
clean run, or something about their specific SQL content happened not to
produce a bash parse error the way this new role's did. Genuinely not
verified either way — flagging honestly rather than asserting a past
failure that was never actually observed.

**Worth remembering for any future task in this project that shells out to
`sqlplus`/`rman`/`dgmgrl` via a heredoc:** always use `shell: |`, never
`shell: >`. A folded scalar is only safe for a command that's meant to be
one logical line split across several lines purely for readability, not for
anything where the literal line structure of the content matters (heredocs,
multi-statement SQL blocks, PL/SQL).

## 78. Fixing #77 exposed a second, related bug — `ORACLE_HOME=... ORACLE_SID=...` on its own line never reaches `sqlplus`'s environment without `export`

James caught this from the very next run: after switching to `shell: |`,
the task failed differently — `SP2-0667: Message file sp1<lang>.msb not
found` / `SP2-0750: You may need to set ORACLE_HOME`. Classic sqlplus
symptom of `ORACLE_HOME` genuinely not being in its process environment,
despite the task clearly setting it right above the `sqlplus` invocation.

**Root cause:** `ORACLE_HOME={{ db_home }} ORACLE_SID={{ sid_prefix }}1` and
the `sqlplus` command used to be on the exact same physical line under
`shell: >` (#77's folding collapsed them together) — `VAR=value
VAR2=value2 command` on one line is POSIX shell's "prefix assignment"
syntax, which scopes `VAR`/`VAR2` into that one command's environment
automatically, no `export` needed. Fixing #77 by switching to `shell: |`
correctly preserved the heredoc's own internal newlines, but it also
un-collapsed THIS line, splitting the variable assignment onto its own
line, separate from the `sqlplus` command that follows it. A bare
`VAR=value` on its own line is a plain shell variable, visible only within
that same shell process — NOT automatically part of the environment
inherited by a child process like `sqlplus`, unless explicitly `export`ed.

**Fix:** `export ORACLE_HOME={{ db_home }}` and `export ORACLE_SID={{
sid_prefix }}1`, each on their own line, in both `dataguard_primary_prep`
(all 11 SQL tasks) and `dbca_noncdb` (all 4). Worth noting `db_silent_install`
already used `export ORACLE_HOME=...` correctly elsewhere in this project
(`tasks/main.yml` around the RU/OJVM patch-application tasks) — this was
always the right pattern, just not the one `dbca_noncdb`'s original heredoc
tasks happened to follow, since the same-line folding accidentally made the
missing `export` invisible there too until #77's fix un-collapsed it.

**Combined lesson from #77+#78:** the two bugs partially masked and then
partially caused each other — folding (#77) accidentally made the missing
`export` (#78) a non-issue by keeping everything on one shell line, and
fixing #77 correctly is what surfaced #78. Any future heredoc-based
`shell:` task in this project should use `shell: |` (never `>`, per #77)
AND `export` any environment variables the invoked command needs (per
#78) — both matter together, not just one or the other.

## 79. Self-inflicted `group_vars/all.yml` edit orphaned a 3rd `standby_scan_ips` entry, which YAML then silently folded into `dg_srl_group_start`'s value — turning an int into a string

The "Add any missing standby redo log groups" task failed:
`Unexpected templating type error ... can only concatenate str (not 'int')
to str`, on a `name:` field doing `{{ dg_srl_group_start + (...) - 1 }}`
arithmetic. Every earlier task in the same role (verify, spfile backup,
FORCE LOGGING, Flashback, `STANDBY_FILE_MANAGEMENT=MANUAL`) had already
succeeded — a strong clue the bug was specific to `dg_srl_group_start`
itself, not the role's general structure.

**Root cause, entirely self-inflicted:** the earlier edit that added the
`dg_*` naming-convention block to `group_vars/all.yml` matched an
`old_string` of `standby_scan_ips:` plus its two visible entries
(`.211`/`.212`) — but `standby_scan_ips` actually had a THIRD entry,
`.213` (a proper 3-member SCAN round-robin, matching the primary cluster's
own SCAN IP count), that the match didn't include. The new `dg_*` block got
inserted correctly, but the orphaned `- 192.168.56.213` line was left
sitting immediately after wherever the new block's last line
(`dg_srl_group_start: 11`) happened to land — with no owning list key
anymore.

**Why this broke `dg_srl_group_start` specifically:** YAML's plain
(unquoted) scalar folding rules allow a mapping value to continue onto
subsequent MORE-INDENTED lines, joining them into the same scalar with a
space — this is normally how a long unquoted string wraps across lines.
`dg_srl_group_start: 11` followed immediately by a more-indented
`- 192.168.56.213` line satisfies that rule: YAML folded the orphaned line
into `dg_srl_group_start`'s value, turning it from the intended plain int
`11` into a STRING containing something like `"11 - 192.168.56.213"`. Every
task that used `dg_srl_group_start` as a bare reference (`{{
dg_srl_group_start }}`) still displayed something IN the string and didn't
error; only the one task doing real arithmetic on it (`+`) hit Python's
`str + int` `TypeError` and surfaced the corruption.

**Fix:** restored `standby_scan_ips` to its correct 3 entries
(`.211`/`.212`/`.213`), and removed the orphaned line from after
`dg_srl_group_start: 11`. Both are one-line changes; the underlying vars
(`dg_srl_groups_per_thread`, `dg_srl_size_mb`, `dg_srl_diskgroup`) were
never affected — only the single line immediately adjacent to where the
bad edit's insertion boundary landed.

**Worth checking after this fix:** if `--tags standby_dns_bind` or
`--tags standby_os_prep` were re-run at any point between the original bad
edit and this fix, `usatclust2`'s BIND zone file or `/etc/hosts` may have
been rendered with only 2 SCAN IPs instead of 3 — worth a quick `dig
scan-usatclust2.usat.com` / `getent hosts scan-usatclust2.usat.com` to
confirm all 3 addresses round-robin correctly before relying on it. GI's
own SCAN VIP registration (`ora.scan1/2/3.vip`, all `ONLINE` in the
`crsctl stat res -t` output earlier this session) predates the bad edit and
is unaffected either way — this is purely a DNS-layer concern, not a
cluster-configuration one.

**General lesson:** when editing a YAML file by matching only PART of a
list (rather than the whole key-to-next-key span), double check there
isn't a further, unseen entry past the matched boundary — an `old_string`
that looks complete from a truncated read isn't necessarily the whole
list, and a partial match can silently orphan real content instead of
failing loudly.

## 80. `sqlplus -s` (silent mode) hid the actual SQL being run — James asked for full transcript-style output on every task, not just selected ones

James flagged two related gaps directly: the SQL*Plus output shown for
"Verify current primary configuration" didn't look like a real session
transcript (no `SQL>` prompt, no echoed command text ahead of each result —
just bare formatted rows), and several tasks in the role had no visible
output at all (`FORCE LOGGING`/Flashback checks and changes,
`STANDBY_FILE_MANAGEMENT` toggles, the spfile backup, the ASM directory
check). Both come from the same root choice: every `sqlplus` invocation
used `-s` (silent mode), which suppresses the version/connection banner,
the `SQL>` prompt, and command echo — and only some tasks had a follow-up
`debug` task registered to actually show their `stdout_lines`.

**Fix:** dropped `-s` from every `sqlplus` call in the role and added `set
echo on` to each SQL*Plus session — this reproduces a real interactive
transcript (banner, `SQL>` prompt, the literal command text, then its
result), matching what a DBA would see running these same commands by
hand. Added a `register` + follow-up `debug: var: ....stdout_lines` task
after every single SQL-executing (and `asmcmd`/`srvctl`-executing) task in
the role, not just the ones that seemed most interesting — `FORCE LOGGING`
check/enable, Flashback check/enable, both `STANDBY_FILE_MANAGEMENT`
toggles, the spfile backup, and the ASM directory check all now show their
full output. This is the standing convention for every future Data Guard
phase (Net config, RMAN duplicate, Broker/DGMGRL, FSFO) too — always full
transcript-style output, always a `debug` task right after, never silent.

## 81. Broker config file locations must be set BEFORE `dg_broker_start=true`, not after — the SOP's own field order caused a real `ORA-16573`

The "Set primary's role-aware Data Guard initialization parameters" task
got partway through (8 of 10 statements succeeded) and then failed on
BOTH `dg_broker_config_file1` and `dg_broker_config_file2`:
`ORA-02097: parameter cannot be modified because specified value is
invalid` / `ORA-16573: attempt to change or access configuration file for
an enabled broker configuration`.

**Root cause:** the task followed the uploaded SOP's own field order
exactly (section 5.6): `dg_broker_start=true` was set, THEN the two broker
config file locations. `dg_broker_start` takes effect immediately under
`scope=both` (not just on next restart) — setting it to `true` starts
DMON, the broker's background monitor process, right then. DMON
immediately takes ownership of whatever `dg_broker_config_file1/2` already
point at (even Oracle's untouched local-disk defaults), and once it
considers a configuration "enabled," Oracle refuses any attempt to change
those file locations out from under it — hence `ORA-16573`. The SOP's own
listed order has this exact bug; it wasn't a project-specific mistake, just
inherited from the source document without re-checking the ordering
against how `dg_broker_start` actually behaves.

**Fix:** reordered the block so the broker config file locations are set
BEFORE `dg_broker_start=true`, and added an explicit `alter system set
dg_broker_start=false` immediately before the file-location statements —
this actively disables DMON first regardless of whatever state it's
already in, rather than assuming it's off. This makes the fix self-healing
even against the current live state of `oradbserv05`, where the earlier
partial run already left `dg_broker_start=true` set with the wrong
(default, non-shared-storage) file paths. Disabling an already-disabled
broker, or enabling an already-enabled one, are both harmless no-ops — safe
to re-run.

**Separately, re: the `PLAY [...]` banners for unrelated plays (OS baseline,
DNS, chrony, ASMLib, SSH equivalence, GI staging/config, DB software, DBCA)
appearing in the `--tags dataguard_primary_prep` run's output** — this is
inherent `ansible-playbook` CLI behavior, not a bug or unwanted execution.
`ansible-playbook` announces every `PLAY [...]` banner for every play
defined in `site.yml` as it iterates through the file, regardless of
whether `--tags` actually matches any task inside that play — a play with
zero matching tasks under the active tag filter still gets its banner
printed, then immediately moves on with no `TASK` lines underneath it at
all (confirmed in James's own pasted output — every one of those banners
has nothing beneath it before the next banner). Nothing in those plays
actually ran; there's no code change that would suppress the banner lines
themselves without patching `ansible-playbook`'s own display code, which is
out of scope for this project's playbooks.

## 82. `SET ECHO ON` never echoed the actual SQL text — because the SQL was fed via a heredoc on stdin, not run as a script

Every task in `dataguard_primary_prep` showed the `SQL>` prompt (and, for
the standby-redo-log PL/SQL block, the `2 3 4...` continuation-line
numbers) but never the statement text itself — James caught this directly:
"I don't see... Format it correctly," with an example of the
`SQL> select ...` transcript style he expected.

**Root cause:** `SET ECHO ON` only echoes commands SQL*Plus reads from a
script invoked via `@`, `@@`, or `START` — it has no effect on input
redirected or piped straight to stdin, which is exactly what every task
here was doing (`sqlplus / as sysdba <<'EOF' ... EOF`). This is documented
SQL*Plus behavior, confirmed against Oracle's own SQL*Plus reference and
community sources (orafaq.com, Oracle Forums) — not a bug in this
project's syntax, just the wrong delivery mechanism for what James wanted.

**Fix:** every SQL block is now written to its own `.sql` file under
`{{ staging_dir }}/sql/` via a `copy` task first, then run with
`sqlplus / as sysdba @{{ staging_dir }}/sql/<name>.sql`. Each script ends
with an explicit `exit;` so sqlplus terminates cleanly rather than falling
through to read further (empty) stdin. With `SET ECHO ON` and a real
script file, every statement — including each line of the standby-redo-log
PL/SQL block — now prints exactly as written immediately before its
result, matching a genuine interactive transcript.

## 83. `srvctl config database` password-file check reported "ORACLE_HOME environment variable is not set" — `command` module doesn't source shell env

The "Check whether a password file is already registered for the primary"
task used the `command` module directly against `srvctl`, which (unlike
the `shell` tasks elsewhere in this role) doesn't go through a shell and so
never picked up `ORACLE_HOME`/`ORACLE_SID` — `srvctl` failed immediately
with `****ORACLE_HOME environment variable is not set`, which the
downstream "Password file already registered" logic then silently
misread as "not found."

**Fix:** added an explicit `environment:` block (`ORACLE_HOME: {{ db_home
}}`, `ORACLE_SID: {{ sid_prefix }}1`) to that `command` task, the same
values every `shell` task in this role already exports manually. Re-run to
get a real answer to the SOP 5.7 password-file check before continuing to
Phase 2.

## 84. `dataguard_net_config`'s `lsnrctl services` check failed with `TNS-12541`/`TNS-12560`/`Linux Error: 111: Connection refused` — same root cause as #83, different command

First real run of `--tags dataguard_net_config` got through both blockinfile
steps cleanly (`tnsnames.ora` and `listener.ora` both updated on all 4
nodes — `changed=2`/`changed=3` in the recap confirms it) and apparently
through `lsnrctl reload` too, but failed hard on all 4 hosts at "Verify the
static _DGMGRL service is now registered":

```
LSNRCTL for Linux: Version 19.0.0.0.0 - Production on 15-AUG-2026 10:57:52
TNS-12541: TNS:no listener
TNS-12560: TNS:protocol adapter error
TNS-00511: No listener
  Linux Error: 111: Connection refused
```

**Root cause:** the same gap as #83 — `lsnrctl reload`/`lsnrctl services`
ran via the `command` module with no `environment:` block, so neither
`ORACLE_HOME` nor `TNS_ADMIN` was set. Without `TNS_ADMIN` pointing at
`{{ grid_home }}/network/admin` (where the real `listener.ora` — the one
this role had just written the static `_DGMGRL` entry into — actually
lives), bare `lsnrctl services` falls back to a compiled-in default
`(HOST=localhost)(PORT=1521)` guess instead of reading the LISTENER's real
address (bound to the node's VIP, confirmed via Section 9's `crsctl stat
res -t`) — nothing is listening at that guessed default, hence "Connection
refused." `crsctl` already confirms `ora.LISTENER.lsnr` is genuinely
ONLINE; this was purely `lsnrctl` looking in the wrong place, not an
actual listener outage. `lsnrctl reload` apparently didn't hit the same
hard failure (the play reached "Verify" at all, meaning "Reload" either
succeeded or was silently skipped by its own `changed_when` logic) — worth
watching on the next run now that both tasks have the fix, since the two
commands may resolve their target differently (local IPC vs. a real TCP
connection).

**Fix:** added the same `environment:` block used for #83's `srvctl` fix —
`ORACLE_HOME: {{ grid_home }}` and `TNS_ADMIN: {{ grid_home
}}/network/admin` — to both the `lsnrctl reload` and `lsnrctl services`
tasks in `dataguard_net_config`. Re-run `--tags dataguard_net_config` to
confirm the static `_DGMGRL` service now shows `READY` instead of failing
to connect at all.

## 85. `dataguard_net_config` modified `tnsnames.ora` and `listener.ora` with no backup — James caught this directly, not a runtime failure

Both `blockinfile` tasks in `dataguard_net_config` (the TNS alias block and
the static `_DGMGRL` listener block) edited live, already-in-use Oracle Net
config files with no backup step — a real gap against this project's own
established standard: `dataguard_primary_prep` backs up the spfile before
touching it (SOP 5.3 note, step 2 in the Phase 1 writeup), and that
same "back up before changing anything live" discipline should have applied
here too. James flagged this directly rather than it surfacing as a run
failure.

**Fix:** added `backup: true` to both `blockinfile` tasks. This is Ansible's
own built-in mechanism for exactly this case — before modifying an existing
file, it copies the pre-change version alongside the original with a
timestamp suffix (e.g. `listener.ora.2026-08-15@11:04:32~`), entirely
automatically, no separate task needed. Added a `debug` task right after
each `blockinfile` call showing `backup_file` (or an explicit "no backup
taken — file didn't exist yet" message on a first-ever run, where there's
nothing to preserve). Re-run to confirm both backup paths show up in the
output.

## 86. `oradbserv09`/`oradbserv10`'s `/etc/hosts` had NO `usatclust1` (primary) entries at all — every primary-side TNS alias failed with `TNS-12545` from a standby node

Ansible's `dataguard_net_config` run came back all-green (every task `ok`,
including `lsnrctl services` showing `apexdb_DGMGRL`/`apexdb_stby_DGMGRL`
both `UNKNOWN` — expected, correct for a static entry nothing has connected
to yet — and all 4 `tnsping` results `OK` from `oradbserv05`). But the real
connectivity test only ran `run_once` from `oradbserv05` — it never actually
exercised the standby-to-primary direction. James tested that by hand from
`oradbserv09`:

```
$ tnsping apexdb
...
TNS-12545: Connect failed because target host or object does not exist
```

`ping scan-usatclust1.usat.com` from the same host worked fine (resolved
and answered), which narrowed it immediately: DNS/hosts resolution for the
bare hostname was fine, but SQL*Net's own resolution of the TNS alias
wasn't reaching a real address. James traced it to `/etc/hosts` on
`oradbserv09` — it had `usatclust2`'s (standby, its own cluster) SCAN
entries, but **no `usatclust1` (primary) entries whatsoever**. Adding the 3
primary SCAN IPs by hand (`192.168.56.201-203` → `scan-usatclust1.usat.com`)
fixed it immediately — `tnsping apexdb` and `sqlplus sys/sys@apexdb`/
`@apexdb_dg` all worked afterward.

**Root cause, traced in `roles/os_prep/templates/hosts.j2`:** the template
rendered ONE SCAN block using `scan_name`/`scan_ips` — vars that
`group_vars/standby_nodes.yml` deliberately redirects to mean "this host's
own cluster" (documented, correct behavior for other roles, e.g.
`grid_silent_install`). On `rac_nodes`, that block correctly renders
`usatclust1`. On `standby_nodes`, the SAME block renders `usatclust2` — the
template's only other SCAN block (`standby_scan_ips`/`standby_scan_name`,
explicitly NOT redirected) ALSO renders `usatclust2` there, so standby hosts
got `usatclust2` twice and `usatclust1` never. This was invisible from
`oradbserv05`/`oradbserv06` because THEY get `usatclust1` (their own,
correctly redirected) plus `usatclust2` (via the always-standby block) — a
complete set, purely by accident of which direction the asymmetry ran. The
exact same asymmetry exists for the plain node/VIP entries (`nodes` vs. the
hardcoded `standby_nodes` block) — not yet observed to break anything
(RMAN/Broker connect via SCAN aliases, not raw node hostnames), but the
identical latent gap, fixed proactively at the same time.

**Fix:** added `primary_scan_ips`/`primary_nodes` to `group_vars/all.yml` —
literal, deliberately never-redirected duplicates of the primary cluster's
IPs (can't alias them via `"{{ scan_ips }}"`/`"{{ nodes }}"`: Jinja resolves
that at USE time against each host's already-merged variables, so it would
silently inherit the standby override too — same class of mistake this
whole bug already was). `hosts.j2` now renders an unconditional "Primary"
block (node/VIP/SCAN) alongside the existing unconditional "Standby" block,
symmetric, on every host regardless of group. Primary nodes end up with a
harmless duplicate of their own entries (once via the redirected block,
once via the new unconditional one) — left as-is rather than removing the
original block, to keep the diff minimal and not disturb anything else that
comment references (the PRVG-11368 incident, #28, #12).

**Action still needed:** `oradbserv09`'s fix above was applied BY HAND —
this Ansible fix will re-render it correctly (and overwrite the manual
edit with the IaC-managed version, which is the right outcome) the next
time `os_prep` runs there. `oradbserv10` was never touched manually and
still has the bug. Re-run, scoped to standby_nodes only (does not touch
`oradbserv05`/`oradbserv06`):

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags standby_os_prep
```

Then re-run `dataguard_net_config` to get a real, both-directions
connectivity result — the previous run's "FAILED" summary for `apexdb`
(`ORA-01017: invalid username/password`) was a red herring: the alias
resolved and reached the listener fine even with the `TNS-12545` bug live
elsewhere (that run's connectivity test only exercised `oradbserv05`, the
one host that already had a complete `/etc/hosts`) — `ORA-01017` just means
`sys_password` wasn't the real value at runtime (this project's
`CHANGE_ME_sys_password` default, or a `-e sys_password=...` value that
doesn't match) and needs to be supplied correctly, unrelated to this bug.

## 87. My own mistake: the "Show lsnrctl services output" task comment claimed the static `_DGMGRL` service should show `READY`, not `UNKNOWN` — backwards

The real run's `lsnrctl services` output (once #84's `TNS_ADMIN` fix let it
actually connect) showed `apexdb_DGMGRL`/`apexdb_stby_DGMGRL` both with
`status UNKNOWN`, while `apexdb`/`apexdbXDB`/`+ASM` all showed `READY`.
The task's own debug comment I wrote said to expect `READY, not UNKNOWN` —
that framing was wrong, not the output.

**Correction:** `UNKNOWN` is the correct, documented status for a
*statically*-registered `SID_LIST_LISTENER` entry — confirmed against
Oracle community references, not just assumed. Static entries are always
present in `lsnrctl services` output (even with the database fully down,
which is the entire point of registering `_DGMGRL` statically for Broker/
RMAN use before an instance opens) but the listener has no live PMON
heartbeat to report a real state for them, so it reports `UNKNOWN`
unconditionally. `READY` only applies to dynamically, PMON-registered
services (`apexdb` itself, `apexdbXDB`) — those get a real state because
the running instance actively registers and updates it. Seeing
`apexdb_DGMGRL` as `UNKNOWN` in the real output is exactly what a correctly
configured static entry looks like, not a sign of failure. Fixed the task's
own comment in `dataguard_net_config` to say so accurately.

## 88. #86's fix left `/etc/hosts` with duplicate entries — one block too many, not one too few this time

James ran `--tags standby_os_prep` to pick up #86's fix and caught the
follow-up problem immediately from the real output: `oradbserv09`/
`oradbserv10` now had `usatclust1` entries (the actual bug, fixed), but
ALSO still had the original group-redirected block (`nodes`/`scan_name`/
`scan_ips`), which on a standby host renders `usatclust2` — meaning
`usatclust2`'s own node/VIP/SCAN lines now appeared TWICE (once from the
redirected block, once from the explicit "Standby" block), while
`usatclust1` appeared once (the new "Primary" block) but with a redundant,
confusingly-worded old block still sitting above it. #86's own writeup
even flagged this as an intentional tradeoff ("harmless duplicate... left
as-is rather than removing the original block, to keep the diff minimal")
— James's direct instruction overrides that judgment call: exactly one
block per cluster, no exceptions.

**Fix:** removed the old group-redirected block (`{% for n in nodes %}` /
`{% for ip in scan_ips %}`) from `hosts.j2` entirely. Nothing else in the
template needs it — every hostname either cluster's hosts require is
already produced by the unconditional Primary block and Standby block
together, exactly once each. Final structure, in order: `localhost`, OEM
Suite Server, PRIMARY RAC DB SERVER (public/private/virtual/SCAN, using
`primary_nodes`/`primary_scan_ips`/`primary_scan_name`), STANDBY RAC DB
SERVER (public/private/virtual/SCAN, using `standby_nodes`/
`standby_scan_ips`/`standby_scan_name`) — identical on every host,
regardless of which group renders it.

Re-run `--tags standby_os_prep` again to confirm both `oradbserv09` and
`oradbserv10` now show exactly one block per cluster with no duplicates,
then re-run `dataguard_net_config` for the full standby → primary
connectivity confirmation this was all in service of.

**Confirmed fixed:** the re-run's `/etc/hosts` on `oradbserv10` showed
exactly one PRIMARY block and one STANDBY block, no duplicates. The
subsequent `dataguard_net_config` re-run confirmed the whole chain clean on
all 4 nodes: TNS aliases and the static `_DGMGRL` listener entry both
landed correctly, `lsnrctl services` connected fine everywhere (`UNKNOWN`
on `apexdb_DGMGRL`/`apexdb_stby_DGMGRL`, `READY` on everything dynamically
registered — both correct per #87), all 4 `tnsping` results `OK`. The
`/etc/hosts` bug chain (#86 → #88) is fully closed.

## 89. James asked "where and who are you trying to connect to as?" — the connectivity-test output gave no context, just the bare ORA- error

Fair question: `dg_net_test_primary`/`dg_net_test_standby`'s output was
just `ORA-01017`/`ORA-12514` with nothing stating which alias, host, or
user the script had attempted — by design, the `no_log: true` write task
hides the connect string (it contains the real password), but that also
hid the non-secret parts (alias, host, port, username) that would have
made the error self-explanatory.

**Answer, for the record:** both scripts connect as `SYS` — `apexdb` (the
real primary, via `scan-usatclust1.usat.com:1521`) and `apexdb_stby` (the
standby, via `scan-usatclust2.usat.com:1521`), both `AS SYSDBA`, both using
whatever `sys_password` resolves to at runtime. Neither this run supplied
`-e sys_password=...`, so it was still `CHANGE_ME_sys_password` (the
never-defaulted placeholder in `group_vars/all.yml`) — which is exactly
why `apexdb` got `ORA-01017` (wrong password on an otherwise fully working
connection — reaching that error at all confirms listener/service/network
were all fine) while `apexdb_stby` got `ORA-12514` regardless of password
(no service named `apexdb_stby` exists yet on that listener — expected,
Phase 4 territory).

**Fix:** added a `debug` task immediately before each connectivity test
stating exactly what it's about to attempt — alias, real hostname:port,
role, username — with an explicit note that the password itself is never
printed anywhere. Re-run `dataguard_net_config` with the real password
(`-e sys_password='<real value>'` or vault) for a genuine primary
connectivity confirmation; `apexdb_stby`'s `ORA-12514` will stay expected
until Phase 4 regardless of password.

## 90. Connectivity testing only ever exercised one node and one primary alias — James asked for full coverage

Both `tnsping` and the `sqlplus` connectivity test were `run_once`, meaning
they only ever ran from whichever host happened to be first in the
`dg_db_nodes` play (`oradbserv05`). A clean result from `oradbserv05` alone
proves nothing about `oradbserv06`, `oradbserv09`, or `oradbserv10`'s own
ability to reach the primary — `oradbserv09`/`oradbserv10` actually
reaching it at all is exactly the direction `#86`'s `/etc/hosts` bug broke,
and that bug was invisible to this test the whole time it was live,
because the test never ran from the hosts it would have affected. The
`sqlplus` test also only exercised the `apexdb` alias, not `apexdb_dg` —
the alias `log_archive_dest_2`/RMAN/Broker actually use for redo
transport, not `apexdb` itself.

**Fix:** removed `run_once` from `tnsping` and the primary `sqlplus` test
entirely — both now run on every node in `dg_db_nodes`. The `sqlplus` test
also now loops over `apexdb` AND `apexdb_dg` (via a `loop:` on both the
script-writing and execution tasks, script filenames disambiguated as
`dg_net_test_apexdb.sql`/`dg_net_test_apexdb_dg.sql`), so every node
proves it can authenticate through both primary aliases, not just one. The
standby (`apexdb_stby`) test stays `run_once` — the standby database
doesn't exist yet, so every node would just report the identical expected
`ORA-12514`, adding output without adding information; worth revisiting
once Phase 4 creates it. Every summary/output task was updated to prefix
`{{ inventory_hostname }}` so a full run's combined output is readable
per-node, not just per-alias.

## 91. #90's own fix broke on 3 of the 4 nodes it was supposed to add coverage to — `{{ staging_dir }}/sql` never existed there

The very first real run of the expanded (all-4-nodes) connectivity test
failed on `oradbserv06`, `oradbserv09`, and `oradbserv10` — only
`oradbserv05` succeeded. Because the failing task is `no_log: true` (it
writes the SYS password into a file), the actual error was censored in the
output, showing only `item=None` and "output has been hidden."

**Root cause:** the `.sql` scripts get written into `{{ staging_dir
}}/sql/`, but that directory is only ever created by
`dataguard_primary_prep` — a role that runs on `rac_node1` (`oradbserv05`)
alone. `dataguard_net_config` runs against all of `dg_db_nodes` and writes
into that same directory, but never created it itself — it silently
depended on a directory another role happens to create on exactly one of
the four hosts it now runs on. `oradbserv05` worked by coincidence (it
already had the directory from Phase 1); the `copy` module can't create a
missing parent directory, so the other three failed outright the moment
#90 made them actually try to write there.

**Fix:** added a `file: state=directory` task at the top of
`dataguard_net_config`, right after the existing `network/admin`
directory-guard tasks, ensuring `{{ staging_dir }}/sql` exists on every
node the role runs on — not assumed from elsewhere. General lesson for
this project going forward: a role that writes into a shared-name
directory another role also uses should never assume that role already
ran on every host it itself targets, even when they happen to overlap
today.

## 92. Phase 3 design decisions (`dataguard_standby_prep`) — recorded before the first real run, per this project's own convention

Built from SOP section 7 (`standby_dataguard_creation.txt`): create a pfile
from the primary's spfile, copy it (edited) plus the primary's real
password file to `oradbserv09`, and start the `apexdb1` auxiliary instance
there in `NOMOUNT` — everything RMAN `DUPLICATE ... FOR STANDBY FROM
ACTIVE DATABASE` (Phase 4) needs to connect to as its `AUXILIARY` target.
Only `oradbserv09` is touched — RMAN `DUPLICATE` first creates a
single-instance standby; Phase 5 converts it to RAC afterward. SID is
literally `apexdb1`, matching the primary's own instance 1 —
`sid_prefix` is deliberately never overridden per cluster (see
`group_vars/standby_nodes.yml`'s own comment). `DB_UNIQUE_NAME` is set
here too, in the Phase 3 pfile, as of #93 below — not deferred to Phase 4
alone the way this entry originally described.

**Play structure:** `hosts: localhost` with `delegate_to` per remote task —
the same pattern `gi_db_home_clone` already established for primary ->
standby work, and for the identical reason: NOT setting `connection:
local` at the play level, since that pins every task (including delegated
ones) to the control node and breaks `delegate_to` outright (see #48's
third update). Small files (pfile, password file) go via Ansible's own
`fetch`/`copy` through the control node, not `scp`/`delegate_to` peer-to-
peer — deliberately different from `gi_db_home_clone`'s multi-GB tarball
handling (which uses `scp` specifically to avoid `fetch`'s OOM-prone
base64 slurp, #50): these files are a few KB, `fetch` is fine, and going
through Ansible's own connection avoids needing NEW cross-cluster oracle-
user SSH equivalence between `oradbserv05` and `oradbserv09` that doesn't
exist today (this project's `ssh_equivalence` role is scoped per-cluster).

**PFILE edits — James's direct call, not the SOP's literal wording:** the
SOP only mentions forcing `cluster_database=false`. James asked for more:
strip RAC/primary-instance-specific parameters too (`apexdb1.`/`apexdb2.`
prefixed lines, `instance_number`, `thread`, `undo_tablespace`,
`local_listener`, `remote_listener`, `cluster_database_instances`) via
`lineinfile: state=absent` on the fetched copy, THEN pause for review
before this same run starts anything — using Ansible's own `pause:`
module (an interactive prompt mid-run), not a separate manual re-
invocation. Starting the instance itself stays automatic immediately
after that pause (James's second direct call) — this is the first
database instance ever started on `usatclust2`, worth a look-before-you-
leap moment even though `startup nomount` is trivially reversible
(`shutdown abort`).

**Password file:** real ASM path/casing discovered dynamically via
`asmcmd ls`, not hardcoded or copied from the SOP's own example — Phase
1/2's real `asmcmd ls` output already confirmed this environment uses
lowercase `apexdb` in its ASM directory tree (`+DATA01/apexdb`), not the
SOP's uppercase `APEXDB` example. A `fail:` guard requires exactly one
file found under the primary's `PASSWORD` directory before proceeding —
same "investigate by hand rather than guess" discipline as Phase 1's
password-file check. The standby's own ASM `PASSWORD` directory doesn't
exist yet (no database has ever existed on `usatclust2`), so `asmcmd
mkdir -p` runs there first, matching SOP 7.3 exactly.

**Idempotency:** the `NOMOUNT` startup is guarded by a `v$instance` query
first — `ORA-01034`/`ORA-27101` means not started (proceed), anything
else means already up (skip, avoid `ORA-01081` from starting twice) —
same check-then-act pattern as every other idempotent task across
`dataguard_primary_prep`/`dataguard_net_config`.

**Not yet run for real** — will document actual command output here (and
in `high-availability/README.md`) the same way Phases 1-2 were, once
James runs `--tags dataguard_standby_prep` and pastes results.

## 93. James asked for `db_unique_name=apexdb_stby` plus a list of other Data Guard parameters in the Phase 3 pfile — verified which actually belong there before editing

James's list: `db_unique_name`, `LOG_ARCHIVE_CONFIG`, `LOG_ARCHIVE_DEST_n`,
`LOG_ARCHIVE_DEST_STATE_n`, `ARCHIVE_LAG_TARGET`, `FAL_CLIENT`,
`DB_FILE_NAME_CONVERT`, `LOG_FILE_NAME_CONVERT`. Worth checking against
real sources rather than adding all seven reflexively, since #92 had
originally deferred `db_unique_name` itself to Phase 4's RMAN `SET`
clause, and several of the others only make sense once the standby
database actually exists.

**What RMAN itself requires here, confirmed via Oracle documentation and
community references:** when `DUPLICATE ... FOR STANDBY FROM ACTIVE
DATABASE ... SPFILE SET ...` is used (this project's Phase 4 plan, from
the original SOP), the *only* parameter strictly required in the
auxiliary instance's initial pfile is `DB_NAME` — RMAN's own `SET`
clauses take over from there and rebuild the spfile entirely at
duplication time. Nothing in this project's Phase 3 pfile is actually
load-bearing for Phase 4 to succeed; the full-pfile-copied-from-primary
approach this role already used (rather than a minimal `DB_NAME`-only
file) is also a documented, valid alternative — Oracle's own guidance
notes a fully-configured standby-site pfile can even let you skip the
`SPFILE` clause and its parameter list entirely. Both approaches are
legitimate; this project already committed to the fuller-pfile approach
before this request, so the question was only which additional edits are
worth making to it now versus leaving for Phase 4.

**Added:** `db_unique_name=apexdb_stby` (`dg_standby_db_unique_name`) —
James asked for it explicitly, and even though it's not required for
Phase 4 to work, setting it here means `v$instance`/`v$database` report
the standby's correct identity from the very first `NOMOUNT` startup, not
just after duplication — useful for the idempotency check later in this
same role and for anyone reviewing the pause prompt. Implemented as a
strip-then-set `lineinfile` pair (the fetched pfile already carries the
primary's own `db_unique_name` line verbatim, has to come out first).

**Deliberately NOT added, with reasons:**
- `LOG_ARCHIVE_CONFIG` / `LOG_ARCHIVE_DEST_n` — already present in the
  fetched pfile, unedited, because `dataguard_primary_prep` already set
  both on the *primary* (`main.yml` ~L429-434: `log_archive_config`,
  `log_archive_dest_2`). They're inert at `NOMOUNT` — no log transport
  happens before the database is mounted/open — and Phase 4's RMAN `SET`
  clause rebuilds them correctly for the standby's own role regardless.
  Editing them here too would just be a second place for the same values
  to drift out of sync with Phase 4.
- `LOG_ARCHIVE_DEST_STATE_n` / `ARCHIVE_LAG_TARGET` — broker/runtime-
  tunable parameters that don't mean anything before the standby
  database exists; that's Phase 7 (broker configuration) territory, not
  Phase 3.
- `FAL_CLIENT` — confirmed via Oracle documentation and community
  references: no longer required since Oracle Database 11g. Data Guard's
  archive-gap resolution (FAL) works without it in every version this
  project touches (12c through 26ai). Not carried forward anywhere in
  this project, on the primary or the standby — `fal_server` is already
  set on the primary (`dataguard_primary_prep`, same block as above);
  there is no corresponding `fal_client` anywhere and there doesn't need
  to be.
- `DB_FILE_NAME_CONVERT` / `LOG_FILE_NAME_CONVERT` — not needed in this
  specific environment: both clusters use ASM with Oracle Managed Files
  and identical diskgroup names (`DATA01`/`RECO01`) on `usatclust1` and
  `usatclust2` (see #75), so datafile/redo log paths already resolve
  correctly without translation. RMAN places files via
  `db_create_file_dest`-style ASM parameters automatically. These
  parameters exist for the case where primary and standby use different
  paths or diskgroup names — not this build.

Sources checked: Oracle's RMAN Backup and Recovery documentation on
duplicating databases (auxiliary-instance pfile minimum requirement),
and multiple independent Data Guard references on `FAL_CLIENT`'s
11g-and-later optional status — worth re-verifying against current
Oracle docs before publishing, per this project's standing discipline of
not trusting a fact transcribed once as permanently current.

## 94. `dataguard_standby_prep`'s first real run failed immediately — `ansible.cfg`'s global `become = True` silently applies to `hosts: localhost` tasks too, and this role's control-node-only tasks had no override

`ansible.cfg` sets `become = True`, `become_method = sudo`, `become_user = root`
at `[privilege_escalation]` scope — needed project-wide for the real remote
work against `oracle`/`grid` on the managed RAC/standby nodes. That default
applies to EVERY task with no explicit `become:` override, including tasks
in a `hosts: localhost` play that have no `delegate_to` — i.e., tasks that
actually execute on the control node (the machine running
`ansible-playbook`) rather than a managed Oracle node. This role's first
task (`Ensure the local (control node) scratch directory exists for pfile
editing`) and its five sibling `lineinfile` pfile-editing tasks had no
`become:` override at all, so they silently inherited `become: true,
become_user: root` and tried to `sudo` on the control node itself — which
isn't configured for passwordless sudo (only the managed `oracle`/`grid`
accounts are, via `os_prep`). First real run failed immediately:
`sudo: a password is required`.

**Fix:** `become: false` added explicitly to all six tasks in this role
that have no `delegate_to` (the scratch-directory `file` task and the five
pfile-editing `lineinfile` tasks). Every task that DOES have `delegate_to`
already sets its own explicit `become: true` + `become_user:` (`oracle_user`
or `grid_user`), so those were never affected — this only ever hit the
genuinely local, control-node-only tasks.

This is the same class of gap `gi_db_home_clone` already got right on its
own local-only task (`Copy tarballs ... via scp (deliberately NOT
delegated ...)`, `become: false`) — worth checking any *future*
`hosts: localhost` role in this project for the same gap before the first
real run, rather than rediscovering it each time.

## 95. Same run, next task — a directory `asmcmd`/an earlier partial run had already created as `grid` couldn't be re-owned to `oracle` by a non-root `become_user`

Immediately after #94's fix, the next real run failed at `Ensure
{{ staging_dir }}/standby exists on the primary`: `chown failed: [Errno 1]
Operation not permitted`, target directory already existed, owned
`grid:oinstall`. This task explicitly set `become_user: "{{ oracle_user }}"`
— but `chown` (changing a file's *owner*, as opposed to `chgrp`) requires
`CAP_CHOWN`, i.e. root, on Linux, regardless of shared group membership or
even if the calling user happens to already own the file. A non-root
`oracle` process can never take ownership away from `grid`, only root can.

**How the directory ended up `grid`-owned in the first place:** this same
staging directory is written into later in the same role by `asmcmd
pwcopy`, running as `grid_user` — on a prior partial run that got further
than this one before failing elsewhere, that command (or its underlying
shell) appears to have auto-created the parent directory as `grid` before
this "ensure it exists, owned by oracle" task ever got a chance to run
first. Re-running the whole tagged play doesn't reset that — every task
re-executes, but the directory's on-disk ownership from the previous
partial run persists.

**Fix:** dropped the `become_user: "{{ oracle_user }}"` override on both
`staging/standby` directory-creation tasks (primary and `oradbserv09`),
letting them run as plain root (`ansible.cfg`'s own default) — matching
`gi_db_home_clone`'s own equivalent staging-directory task (`Ensure
{{ staging_dir }}/clone exists ...`, `become: true`, no `become_user`
override), which already uses this pattern for exactly this reason. Root
can `chown`/`chmod` a directory back to the declared `owner:`/`group:`/
`mode:` regardless of its current state — self-healing on every re-run, no
manual cleanup of the stray `grid`-owned directory needed.

**General lesson for this role and any future one where two different
Oracle OS users (`oracle`, `grid`) both write into the same shared staging
path:** let root own the "ensure this directory exists with these
permissions" task; reserve `become_user: oracle_user`/`grid_user` for the
tasks that actually need to *act* as that specific application owner
(`sqlplus`, `asmcmd`, file content written by that user). Mixing the two —
using an application user's own privilege level to also enforce ownership
— only works as long as that user happens to already own the target; it
silently breaks the first time it doesn't.

## 96. Same run, next task — `asmcmd pwcopy` into the standby's ASM failed with `ORA-15046` (wrong destination *filename* form) on top of a wrong destination *directory* (wrong `db_unique_name`)

Immediately after #95's fix, the run got further and failed at `Copy the
password file into the standby's ASM (asmcmd pwcopy)`:

```
ASMCMD-8016: copy source '.../pwdapexdb.261.1241123369' and target
'+DATA01/apexdb/PASSWORD/pwdapexdb.261.1241123369' failed
ORA-15046: ASM file name '+DATA01/apexdb/PASSWORD/pwdapexdb.261.1241123369'
is not in single-file creation form
```

Two separate, compounding bugs, both in how the destination path was
built — verified against Oracle documentation and multiple independent
`ORA-15046`/`asmcmd pwcopy` references before fixing either:

- **Wrong filename form:** the destination filename was the primary's own
  real, ASM-generated OMF name (`pwdapexdb.261.1241123369`, discovered
  earlier via `asmcmd ls`), copied verbatim. That numeric `.file#.
  incarnation#` suffix is assigned by ASM itself at file-creation time —
  it cannot be dictated by the caller. Providing it as a *creation* target
  (which is what `pwcopy`'s destination side is, copying INTO ASM) is
  exactly what `ORA-15046` means; it's fine as a *source* (reading an
  already-existing file by its real name, which is what the earlier
  primary-ASM-to-OS-staging `pwcopy` in this same role correctly does —
  that direction was never broken). The fix confirmed across multiple
  independent sources: give the destination a plain alias name with no
  numeric suffix and let ASM generate the real underlying OMF file itself.
  New `dg_standby_pwfile_alias` fact (`pwd{{ dg_standby_db_unique_name }}`,
  e.g. `pwdapexdb_stby`) used as the destination filename instead.
- **Wrong directory — using the PRIMARY's `db_unique_name`, not the
  standby's:** both the `asmcmd mkdir -p` and the `pwcopy` destination
  used `{{ db_unique_name }}` (this project's global var for the primary's
  own name, `apexdb`) instead of `{{ dg_standby_db_unique_name }}`
  (`apexdb_stby`). Oracle's default ASM password-file search path is
  `+<diskgroup>/<db_unique_name>/PASSWORD/pwd<db_unique_name>...`, keyed
  by whatever `DB_UNIQUE_NAME` the instance itself is running with — and
  as of #93, this aux instance's pfile now explicitly sets
  `db_unique_name=apexdb_stby`. Left as `apexdb`, the password file would
  have copied successfully (once the filename-form bug above was also
  fixed) into a directory the instance would never actually look in —
  working today, silently wrong for Phase 4's remote `AUXILIARY`
  connection later, which does need a real, discoverable password file.
  Both tasks now target `+{{ asm_diskgroup_data }}/{{
  dg_standby_db_unique_name }}/PASSWORD`.

**Leftover, harmless:** the earlier wrong run already created an empty
`+DATA01/apexdb/PASSWORD` ASM directory on `oradbserv09` (via the
since-fixed `mkdir -p` task). Not cleaned up automatically — it's empty
and inert, but worth an `asmcmd rmdir` on `oradbserv09` by hand if it's
ever confusing to see two `PASSWORD` directories under different names
there later.

Sources checked: several independent `ORA-15046`/`ASMCMD-8016` references
confirming the no-numeric-suffix destination-naming fix, and the ASM
password-file default-location convention (`+<diskgroup>/<db_unique_name>/
PASSWORD/pwd<db_unique_name>`) — worth re-verifying against current Oracle
docs before publishing, same standing discipline as #93.

## 97. Same run, next task — `asmcmd mkdir -p` isn't a real thing on this environment's 19.3 grid home; the parent directory silently never got created, and `failed_when: false` hid it

James caught this directly, from real `asmcmd` behavior on `oradbserv09`,
not from documentation: `asmcmd`'s `mkdir` has no `-p` (recursive-create)
equivalent — unlike the Linux `mkdir` command it superficially resembles.
`#96`'s fix retargeted the standby PASSWORD directory to
`+DATA01/apexdb_stby/PASSWORD`, but the task creating it still used the
original single-call `mkdir -p +DATA01/{{ dg_standby_db_unique_name }}/
PASSWORD` — which, with no real `-p` support, never created the missing
parent (`apexdb_stby` itself didn't exist yet at ASM's root, only
`PASSWORD` was being asked for under it). That task's `changed_when`/
`failed_when: false` (originally written to tolerate "directory already
exists" on a re-run) also swallowed this completely different failure
mode — a missing PARENT, not a pre-existing directory — so the play
reported success and moved on with nothing actually created. The next
task (`pwcopy`) then failed with `ORA-19505`/`ORA-17502`/`ORA-15173:
entry 'apexdb_stby' does not exist in directory '/'` — the real symptom
of the silently-skipped `mkdir`.

**Fix:** replaced the single `mkdir -p` call with an explicit two-level
`block:` — check via `asmcmd ls` whether `+DATA01/apexdb_stby` exists,
create it if not; then the same check-then-create pattern for
`+DATA01/apexdb_stby/PASSWORD` underneath it. `delegate_to`/`become`/
`become_user` set once at the block level (all four tasks inside inherit
them) rather than repeated per task. This also fixes the masking problem
from #96/this entry — each level's existence is checked and acted on
explicitly now, rather than trusting a single command's exit code to mean
the right thing under `failed_when: false`.

**Leftover from this failed attempt too:** the earlier run's `mkdir -p`
call, despite not creating the parent, apparently still produced *some*
ASM-side state — worth confirming on `oradbserv09` with
`asmcmd ls +DATA01/apexdb_stby` before the next run, in case a partial/
empty entry needs clearing by hand; the new check-then-create tasks
handle "doesn't exist yet" and "already fully exists" cleanly either way,
so this is a housekeeping note, not a blocker for re-running.

## 98. James corrected #94/#96 directly: the standby's ASM directory naming stays `apexdb` (the original db_unique_name), not `apexdb_stby` — and the Broker config file locations needed the same treatment

#94/#96 had reasoned from Oracle's general documented default (ASM
password-file search keyed by the RUNNING instance's own `DB_UNIQUE_NAME`)
to conclude the standby's ASM directory should be `+DATA01/apexdb_stby`,
matching the `db_unique_name=apexdb_stby` set in the pfile per #93. James
corrected this directly from how this environment/SOP actually works: the
ASM directory name stays `apexdb` — the ORIGINAL name — on both clusters'
independent `DATA01`/`RECO01` diskgroups, not re-keyed per cluster. This
is the authoritative, environment-specific answer; the general Oracle
default #94/#96 reasoned from evidently isn't what governs directory
naming here (plausible explanation, not confirmed: `DB_NAME` stays
`apexdb` on both sides — required for any physical standby — and this
convention may simply follow `DB_NAME`/the original alias structure
rather than the per-instance `DB_UNIQUE_NAME`; not worth guessing further
without checking directly against this specific `asmcmd`/RDBMS version's
actual behavior).

**Fixed:** both the ASM-directory `block:` (`Ensure the standby's ASM
PASSWORD directory exists`) and the `pwcopy` destination now use
`db_unique_name` (`apexdb`), not `dg_standby_db_unique_name`
(`apexdb_stby`) — `+DATA01/apexdb/PASSWORD/<alias>`. The destination
*filename* itself (`dg_standby_pwfile_alias`, still `pwdapexdb_stby`) was
never wrong — only the directory portion of the path was.

**Also added, same instruction:** `dg_broker_config_file1`/
`dg_broker_config_file2` pfile edits, using the same `apexdb`-keyed
convention:

```
*.dg_broker_config_file1='+DATA01/apexdb/DG/dr1apexdb.dat'
*.dg_broker_config_file2='+RECO01/apexdb/DG/dr2apexdb.dat'
```

Implemented as a strip-then-set `lineinfile` pair, same pattern as
`db_unique_name` (#93) — strip first in case the primary's own broker
config file lines (set back in `dataguard_primary_prep`, see #81) are
still present verbatim in the fetched pfile, then insert the two lines
above. Not yet verified whether the `DG` subdirectory itself needs to be
created via `asmcmd mkdir` the same way `PASSWORD` did (#97) before the
broker can actually write to it — that's Phase 7 (Broker configuration)
territory; flagging now rather than guessing, since this pfile edit only
needs the *parameter* set correctly for Phase 3, not the directory to
exist yet.

## 99. #97's `asmcmd ls`-based existence check was itself unreliable — the real `mkdir` still hit `ORA-15005` "already used by an existing alias" on a directory that genuinely already existed

James caught this directly from the next real run: `+DATA01/apexdb`
already existed (created earlier — most likely from his own manual
`asmcmd mkdir +DATA01/apexdb` / `asmcmd mkdir +DATA01/apexdb/PASSWORD`
reproduction, the same commands he'd pasted a few turns earlier while
diagnosing #96/#97), but #97's `asmcmd ls +DATA01/apexdb` pre-check
still came back with a non-zero `rc`, so the `when: ...check.rc != 0`
guard fired anyway and the real `mkdir` ran against an already-existing
alias: `ORA-15032`/`ORA-15005: name "+DATA01/apexdb" is already used by
an existing alias`. Exactly the failure #97's check-then-act pattern was
supposed to prevent — `asmcmd ls`'s exit code on this grid home doesn't
reliably mean "exists"/"doesn't exist" the way it does for a normal
Linux `ls`, at least not in every case tested so far.

James's direct instruction: "if exists it continues" — simpler and more
robust than trying to get a separate pre-check exactly right. **Fix:**
dropped the `asmcmd ls` pre-check entirely. Both `mkdir` calls now just
run directly, `register`ed, with `failed_when` treating `rc != 0` as a
real failure UNLESS the error is specifically `ORA-15005` (the exact,
unambiguous "already exists" error) — any other non-zero `rc` still
fails the play normally. `changed_when: rc == 0` reports a true create
as `changed`, and an `ORA-15005` skip as **not** changed (since nothing
was actually created that run) — correctly reflects real state either
way. Same "match the specific tolerable error code, fail on everything
else" idiom already used elsewhere in this project rather than a broad
`failed_when: false`, which is exactly the kind of masking that caused
#97 in the first place.

## 100. `startup nomount` failed with `ORA-09925` — nothing had ever created `audit_file_dest` on usatclust2, and the fix needed to cover both standby nodes, not just the one this phase starts an instance on

The fetched/edited pfile carries the primary's own, deliberately-unedited
`audit_file_dest='/u01/app/oracle/admin/apexdb/adump'` line straight
through (a plain OS path, not ASM — correctly never touched by any of
this role's `lineinfile` edits). But nothing in this project had ever
created that directory on `usatclust2` — no database has existed there
before this phase, unlike the primary cluster, where `dbca_noncdb`
already creates the equivalent directory on both RAC nodes before DBCA
ever runs. First real `startup nomount pfile=...` attempt on
`oradbserv09` failed immediately: `ORA-09925: Unable to create audit
trail file` / `Linux-x86_64 Error: 2: No such file or directory`. James
confirmed the fix by hand (`mkdir -p /u01/app/oracle/admin/apexdb/adump`
on `oradbserv09`, then a manual `startup nomount` succeeded — real
output: `ORACLE instance started`, `v$instance.status = STARTED`) and
asked for the automated fix to cover **every** standby node, not just
the one Phase 3 starts an instance on.

**Fix:** new task, `Ensure the audit file destination exists and is
writable, on every standby node`, added right before the NOMOUNT startup
section — looped over `groups['standby_nodes']` (`oradbserv09` AND
`oradbserv10`) via `delegate_to: "{{ item }}"`, plain root (no
`become_user` override, same reasoning as #95: this is a directory-
ownership task, not an act-as-the-application-user task). Deliberately
mirrors `dbca_noncdb`'s existing equivalent task for the primary cluster
(`Ensure the audit file destination exists and is writable, on every RAC
node`, same path shape `{{ oracle_base }}/admin/{{ db_unique_name }}/
adump`, same owner/group/mode `{{ oracle_user }}:oinstall 0750`) rather
than inventing a new convention — this project already had the right
pattern, just scoped to the wrong cluster. Covering `oradbserv10` now,
even though nothing starts an instance there until Phase 5 converts this
standby to RAC, avoids rediscovering the identical `ORA-09925` a second
time at that phase.

## 101. Phase 4 (`dataguard_duplicate`, RMAN `DUPLICATE ... FOR STANDBY FROM ACTIVE DATABASE`) — built from James's pasted SOP section 8, with several deliberate adaptations, two confirmed directly before writing any code

James pasted the SOP's section 8 script directly. Built from it, not copied
verbatim — several values are generic placeholders that don't match this
project's real environment, and two genuinely ambiguous/risky points were
resolved with direct questions before writing anything, given this phase
is the least reversible step in the project so far (it physically copies
the primary's live datafiles over the network and creates real standby
datafiles):

- **`apexdb_pri` -> `apexdb`, everywhere.** This project's primary
  `db_unique_name` was never renamed to `apexdb_pri` — decided back at
  #76. `TARGET`/`AUXILIARY` connect to the real `apexdb`/`apexdb_stby` TNS
  aliases Phase 2 already built and tested, not the SOP's alternative
  `host:port/service` form.
- **`+data`/`+reco01` -> `+DATA01`/`+RECO01`** — this project's real, only
  diskgroups (#75). The SOP's lowercase generic names were never valid
  here.
- **`db_recovery_file_dest_size`: SOP says `500g`, used `7368m` instead**
  — a home-lab `RECO01` diskgroup has nowhere near 500GB. `7368m` is the
  PRIMARY's own real, currently-working value, read directly off the real
  pfile Phase 3 dumped — not a guess, and not a new made-up group_var
  (no such var existed anywhere in this project; DBCA's own response file
  never set one explicitly either).
- **Channel count reduced from 4+4 to 2+2.** Single-VirtualBox-host lab —
  every channel shares the same physical disk I/O regardless of count, so
  8-way parallelism buys nothing here. Trivial to raise if a real run
  shows it matters.
- **Broker config file paths — confirmed directly, genuine conflict
  found:** the SOP's Phase 4 script uses apexdb_stby-keyed paths
  (`+data/apexdb_stby/dr1apexdb_stby.dat`), but James had directly told
  me apexdb-keyed paths (`+DATA01/apexdb/DG/dr1apexdb.dat`) for Phase 3's
  pfile edit (#98) — two different literal values across two separate
  turns for the same parameter. Since RMAN's `SPFILE SET` clauses rebuild
  the spfile from scratch here, whatever THIS phase sets is what actually
  takes effect — Phase 3's version never mattered past this point either
  way. Asked directly rather than silently picking one; James confirmed
  apexdb-keyed, matching #98 and the password-file convention.
- **`PARAMETER_VALUE_CONVERT` dropped entirely — confirmed directly,
  genuine risk found, not just a style preference.** The SOP's literal
  clause (`PARAMETER_VALUE_CONVERT 'apexdb_pri','apexdb_stby'`) adapted
  to this project's real names would be `'apexdb','apexdb_stby'` — a
  blanket substring replace across every parameter value in the spfile
  template. `db_name` is also literally `'apexdb'` here (and MUST stay
  identical to the primary's on any physical standby — non-negotiable),
  and multiple documentation/community sources checked couldn't confirm
  with confidence that `db_name` is exempt from this conversion; real-
  world examples found also explicitly `SET audit_file_dest`/
  `control_files` rather than relying on convert alone. Since
  `db_unique_name` is the only thing genuinely differing between primary
  and standby in this project (not a renamed `db_name` the way the SOP's
  own generic example assumes), there was nothing left for a blanket
  convert to safely do that explicit `SET` clauses (`audit_file_dest`,
  `fal_server`, `log_archive_config`, `log_archive_dest_1/2`, the broker
  config files) don't already cover directly. James confirmed dropping it
  rather than risk it on a real run.

**Design, unchanged from the SOP:** `DORECOVER` kept (valid, documented
`FOR STANDBY FROM ACTIVE DATABASE` syntax — rolls the standby closer to
current SCN using available redo during duplication itself);
`NOFILENAMECHECK` kept (needed since primary and standby share the same
ASM diskgroup names, `DATA01`/`RECO01`, on genuinely separate storage —
without it RMAN would refuse, assuming a same-host clone); the full 8.3
manual validation sequence (confirm role/state, start managed recovery,
force redo on the primary, verify transport/apply lag, optional primary-
side confirmation) automated as real SQL tasks with full output shown,
same discipline as every other phase.

**Pauses:** two, not one — before `DUPLICATE` itself runs (my own addition,
given how much translation happened above; this is the step actually
worth a look-before-you-leap moment) and before managed recovery starts
(James's direct confirmation, matching Phase 3's precedent of pausing
before each first-time, consequential action). The SOP's own final NOTE —
"only proceed to Phase 5 once transport lag and apply lag are healthy" —
is treated as a manual gate, not automated: the role prints the real
numbers and an explicit reminder, but doesn't try to parse "healthy" out
of fluctuating lag values itself.

**Not yet run for real** — will document actual command output here and
in `high-availability/README.md` the same way Phases 1-3 were, once James
runs `--tags dataguard_duplicate -e sys_password=...` and pastes results.

## 102. First real run failed at `CONNECT AUXILIARY` — `ORA-12514`, the `apexdb_stby` TNS alias can't resolve via the listener yet

**This entry's own fix (switching to `connect auxiliary /`) turned out to
be wrong — corrected in #103.** `DUPLICATE ... FROM ACTIVE DATABASE`
genuinely requires the `AUXILIARY` connection to carry a net service
name; a bequeath `/` connection fails outright with `RMAN-06217: not
connected to auxiliary database with a net service name`, confirmed on
the very next real run. The diagnosis of *why* the original TNS
connection failed (below) was correct and is exactly what #103 actually
fixes — only the "switch to a local connection instead" conclusion was
wrong. Kept this entry as-is for the history; see #103 for the real fix
and the reversion back to a TNS-based `AUXILIARY` connection.

James caught this directly from a real run: `RMAN-04006: error from
auxiliary database: ORA-12514: TNS:listener does not currently know of
service requested in connect descriptor`. #101's original cmdfile
connected `AUXILIARY` the same way `TARGET` connects — over a TNS alias
(`sys/{{ sys_password }}@apexdb_stby`) — but that alias can't actually
resolve yet: `dataguard_net_config` (Phase 2) only created a STATIC
listener entry for the broker's own `_DGMGRL` service name
(`apexdb_stby_DGMGRL`), not for the plain `apexdb_stby` service the TNS
alias's `SERVICE_NAME` points at. That service only gets registered
DYNAMICALLY, by the instance's own PMON, once the database reaches at
least `MOUNT` — and at the exact moment `CONNECT AUXILIARY` runs, the
`apexdb1` instance is still sitting in `NOMOUNT` (Phase 3 left it there
on purpose, waiting for this exact step). There was never a working
listener registration for RMAN to find.

**The deeper point, not just the fix:** `AUXILIARY` was never a genuine
remote connection to begin with. RMAN itself runs locally ON
`oradbserv09` — the exact same host as the `apexdb1` auxiliary instance —
so routing that connection out through TNS/the listener and back was
unnecessary round-about complexity, not just a broken one. **Fix:**
`connect auxiliary /` — a bequeath (OS-authenticated) connection using
whatever `ORACLE_SID` is already exported in the shell (`apexdb1`, set
right before invoking `rman`), no listener involved at all. `TARGET`
correctly stays a real TNS connection (`apexdb`, genuinely remote, over
the network to `oradbserv05`) — that side was never the problem.

**Also corrected in the same fix, unrelated syntax issue:** James's own
phrasing of the fix included `AS SYSDBA` (`connect auxiliary / as
sysdba`) — checked against Oracle's RMAN documentation before
implementing literally, since this looked like it might just be
descriptive shorthand rather than the exact syntax wanted. Confirmed:
RMAN's `CONNECT` command has no `AS SYSDBA` clause at all (unlike
SQL*Plus) — every RMAN database connection implicitly requires and uses
SYSDBA-equivalent privilege regardless of how it's phrased, and
explicitly adding `AS SYSDBA` to a `CONNECT` command is a syntax error.
Implemented as plain `connect auxiliary /` — **since reverted, see #103.**

## 103. #102's fix was wrong — `RMAN-06217`, `FOR STANDBY FROM ACTIVE DATABASE` requires a net service name on `AUXILIARY`; the real fix is a static listener entry for the plain service, not switching to a local connection

James tested #102's `connect auxiliary /` fix by hand and hit
`RMAN-06217: not connected to auxiliary database with a net service
name` — a real, documented RMAN error meaning exactly what it says:
active-database duplication needs a genuine net service name on the
`AUXILIARY` side so RMAN can set up the auxiliary channels that receive
the network-copied files. That requirement holds regardless of whether
RMAN happens to be running on the same host as the auxiliary instance —
#102's "it's local, so a bequeath connection should work" reasoning was
a real mistake, confirmed by checking Oracle's own RMAN-06217 error
reference and multiple independent active-duplicate guides before fixing
it a second time (not just reverting blind).

**So the original `ORA-12514`/service-BLOCKED problem #102 diagnosed
still needed a real fix — just not that one.** James's own follow-up
manual testing nailed it: `lsnrctl status listener` on `oradbserv09`
showed `Service "apexdb_stby" has 1 instance(s). Instance "apexdb1",
status BLOCKED` — confirmed against multiple independent references as
expected, well-documented behavior: PMON registers a NOMOUNT-only
instance's plain service, but marks it `BLOCKED` (not `READY`) because
the database isn't mounted/open yet, and a listener connection request to
a `BLOCKED` service can still surface as `ORA-12514` depending on timing
relative to registration. The standard, documented fix for exactly this
scenario (RMAN active duplication where the auxiliary sits in NOMOUNT) is
a **static** listener entry for the plain service name — dynamic
registration isn't reliable enough at NOMOUNT to depend on.

**Fix:** `dataguard_net_config`'s listener.ora `blockinfile` block (built
back in Phase 2) now adds a SECOND `SID_DESC` alongside the existing
`_DGMGRL` one — same `SID_NAME`, but `GLOBAL_DBNAME = {{
dg_local_db_unique_name }}` (no `_DGMGRL` suffix), matching the plain
`SERVICE_NAME` the `apexdb`/`apexdb_stby` TNS aliases already point at.
Static entries don't depend on PMON/dynamic registration at all — they're
present the moment the listener starts, regardless of what state the
database instance is in. Since this lives in Phase 2 (already run and
confirmed green on all 4 nodes before this gap was found), **Phase 2
needs a re-run** (`--tags dataguard_net_config`) to push the new
`SID_DESC` to all 4 listeners — `oradbserv09`'s specifically is what
Phase 4 actually needs, but re-running against the whole `dg_db_nodes`
group keeps all 4 nodes' listener.ora files consistent with each other,
same as every other change to that shared block this project has made.

`dataguard_duplicate`'s cmdfile reverted to `connect auxiliary sys/{{
sys_password }}@{{ dg_standby_db_unique_name }}` — a genuine, working TNS
connection now that the plain service has a static entry to resolve
against, independent of NOMOUNT/BLOCKED status. `TARGET` was never
affected by any of this — it was always a correct, real TNS connection to
the primary.

## 104. #98's ASM directory correction was right for the Broker config files, wrong for the password file — `V$PWFILE_USERS` returned no rows, meaning the instance genuinely can't see any password file at all

While chasing #102/#103's `ORA-12514`/`ORA-12520` chain, James tried
several manual `rman`/`sqlplus` connection variants against `oradbserv09`
and, critically, ran `select * from v$pwfile_users;` against the running
`apexdb1` instance directly (`/ as sysdba`, local, no listener involved
at all) — **no rows selected**. Compared against the same query on the
primary (`oradbserv05`/`06`), which correctly lists
`SYS`/`SYSDG`/`SYSBACKUP`/`SYSKM`. This is a real, hard finding, not a
connectivity symptom: the `apexdb1` instance cannot see ANY usable
password file, full stop — independent of the listener/TNS issues #102/
#103 were chasing.

**Root cause, confirmed against Oracle documentation:** `asmcmd pwcopy`
(what Phase 3 actually used) is a plain ASM-level file copy — unlike
`asmcmd pwcreate --dbuniquename=...`, it does NOT register "this is the
password file for database X" anywhere. A running instance finds its own
password file through Oracle's own automatic ASM discovery convention,
keyed by **the instance's own `db_unique_name`**:
`+<diskgroup>/<db_unique_name>/PASSWORD/...` — confirmed against multiple
sources describing `--dbuniquename` as exactly the parameter that
identifies "database password files residing in an ASM diskgroup." This
instance's `db_unique_name` is `apexdb_stby` (set in the pfile per #93)
— so it was only ever going to look under
`+DATA01/apexdb_stby/PASSWORD/`. #98 moved the file to
`+DATA01/apexdb/PASSWORD/` instead — wherever we physically copy the
file, the instance's own discovery logic doesn't care; it searches its
own fixed, convention-based location regardless, and found nothing there.

**Why #98 wasn't simply wrong across the board — it was right for a
different parameter with a genuinely different mechanism:** the Broker
config files (`dg_broker_config_file1`/`dg_broker_config_file2`) are
explicit parameter VALUES — Oracle uses exactly the literal path given,
verbatim, with no independent search/discovery involved at all. James's
`apexdb`-keyed convention for those remains correct and unaffected by
this finding; nothing about #98 changes for that parameter. The password
file is the one place in this project where Oracle governs the location
itself via an automatic, non-overridable convention rather than an
explicit parameter — that's the actual distinction, not "apexdb vs.
apexdb_stby" as a blanket rule.

**Fix:** `dataguard_standby_prep`'s ASM `PASSWORD` directory creation
block and the `pwcopy` destination both reverted to
`dg_standby_db_unique_name` (`apexdb_stby`) — back to #94/#96's original
directory, which was correct for this specific parameter all along.
`dg_pwfile_name`'s discovery on the PRIMARY side (`+DATA01/apexdb/
PASSWORD`, reading the primary's own real, existing file) is unaffected
— that's a read from wherever the PRIMARY's own instance already
discovered and created its file, not something this project chose.

**Sequencing for the fix to actually land:** the standby's ASM `PASSWORD`
directory at `+DATA01/apexdb` already has a copy of the password file
from Phase 3's earlier (wrong-location) run — harmless leftover, not
cleaned up automatically, safe to ignore or remove by hand later. Getting
the correctly-located copy in place requires re-running Phase 3
(`--tags dataguard_standby_prep`) — idempotent, safe to re-run (pfile
editing, pause, and the NOMOUNT startup check all tolerate a second run
cleanly). Combined with #103's listener fix (Phase 2) and #102's
reverted `AUXILIARY` connection, the full sequence needed before Phase 4
can succeed is: Phase 2 → Phase 3 → Phase 4, in that order.

## 105. #103's static listener fix never actually reached the listener RMAN's `AUXILIARY` connection goes through — static `SID_LIST` entries are scoped per listener PROCESS, and `apexdb_stby` connects via SCAN, not the plain `LISTENER`

After #103 (Phase 2 re-run) and #104 (Phase 3 re-run, password file
relocated) were both genuinely deployed, `apexdb_stby` still failed
`ORA-12514` with total consistency — dozens of retries, all failing the
same way. James ran an exceptionally thorough round of manual diagnosis
before I found the real cause: confirmed the static entry really was in
`oradbserv09`'s `listener.ora` (`cat`'d it directly, both `_DGMGRL` and
plain `apexdb_stby` `SID_DESC` entries present); created a brand-new
LOCAL password file by hand (`orapwd file=$ORACLE_HOME/dbs/pwdapexdb
...`) to rule out #104 having somehow not landed — `v$pwfile_users` still
came back empty even with that, which in hindsight makes sense: NOMOUNT
instances can't populate that view meaningfully regardless of password
file state, a red herring, not a real problem, since the ASM-based
password file IS what RMAN's own AUXILIARY authentication actually reads
against, not `v$pwfile_users`; ran `alter system register` manually to
force immediate dynamic registration; restarted the instance cleanly;
confirmed `service_names = apexdb_stby` on the running instance
(correct); and — the decisive test — confirmed `apexdb` (the primary,
via `scan-usatclust1`) connects successfully from `oradbserv09` while
`apexdb_stby` (the standby, via `scan-usatclust2`, the SAME node's own
cluster) fails immediately after, every time.

**Root cause, confirmed against Oracle documentation:** static `SID_LIST`
entries in `listener.ora` are scoped to ONE specific listener PROCESS,
selected by the stanza's own name — `SID_LIST_LISTENER` applies only to
the listener literally named `LISTENER`. A SCAN listener is a genuinely
separate process (`LISTENER_SCAN1`/`LISTENER_SCAN2`/`LISTENER_SCAN3`,
confirmed running as distinct `tnslsnr` processes with their own PIDs,
log files, and endpoints in this environment's own `ps -ef`/`crsctl`
output) and requires its OWN separate stanza —
`SID_LIST_LISTENER_SCAN1`, etc. — to carry any static entry at all.
`dataguard_net_config`'s `blockinfile` task only ever wrote a
`SID_LIST_LISTENER` stanza. Since `apexdb_stby`'s TNS alias connects via
`scan-usatclust2.usat.com` — routed through `LISTENER_SCAN1`/`SCAN2`/
`SCAN3`, not the plain `LISTENER` — the SCAN listeners never had ANY
knowledge of `apexdb_stby`, static or dynamic, regardless of how correct
the plain `LISTENER`'s own config was. `apexdb` kept working throughout
because the primary's instances are `MOUNTED`/`OPEN`, so PMON dynamically
registers them with every listener process, SCAN included — dynamic
registration was never the broken piece on the primary side, which is
exactly why chasing `apexdb`'s failures earlier turned out to be a
transient red herring (most likely caught mid-`lsnrctl reload` during a
Phase 2 re-run) while `apexdb_stby`'s failure was real and consistent the
entire time.

**Fix — deliberately NOT adding `SID_LIST_LISTENER_SCAN1/2/3` stanzas:**
that's Oracle's own documented fix for the general case, but it requires
per-node awareness of which SCAN listener GI currently has running where
(`crsctl stat res -t` shows they can and do relocate on failover), for a
need that's actually narrow and temporary: nothing else in this project
needs `apexdb_stby` reachable via SCAN before Phase 4 duplicates it —
Phase 2's own connectivity test already expects `apexdb_stby` to return
`ORA-12514` at that stage ("no standby database until Phase 4"). Once
`DUPLICATE` actually mounts/opens the database, PMON's normal dynamic
registration takes over everywhere, SCAN included, exactly like `apexdb`
already works today — no static entry needed for that later, ongoing
state at all.

Instead: `dataguard_duplicate`'s `AUXILIARY` connection now uses an
inline connect descriptor pointed directly at `oradbserv09`'s own IP
(`{{ ansible_host }}`) and port 1521 — the plain `LISTENER` process,
which DOES have the correct static entry — bypassing SCAN and
`tnsnames.ora` entirely for this one connection. `TARGET` is unaffected,
still a real TNS connection to the primary via SCAN, which was never
broken.

**Leftover from the diagnostic process, harmless:** a manually-created
local password file at `oradbserv09`'s `$ORACLE_HOME/dbs/pwdapexdb` —
James removed it again during the same session, along with a few
Oracle-regenerable files (`snapcf_apexdb1.f`, `id_apexdb1.dat`,
`hc_apexdb1.dat`) that Oracle recreates as needed; nothing to clean up.

## 106. #105's SCAN-bypass fix still failed — `TNS-12537`/`ORA-01017` — a NOMOUNT-only instance's SERVICE_NAME handler is `BLOCKED`; AUXILIARY needs SID, not SERVICE_NAME

Even after #105's fix (AUXILIARY pointed directly at `oradbserv09`'s own
IP, bypassing SCAN), `apexdb_stby` still failed — a new, different error
this time: `ORA-12537: TNS:connection closed` on the first connect
attempt, then `ORA-01017: invalid username/password` on retries. Progress
over #105's `ORA-12514` (the listener now genuinely recognizes the
service — routing was fixed), but a new failure at the next stage.

James ran `lsnrctl status LISTENER` directly on `oradbserv09`, which
showed the actual state plainly:

```
Service "apexdb_stby" has 2 instance(s).
  Instance "apexdb1", status UNKNOWN, has 1 handler(s) for this service...
  Instance "apexdb1", status BLOCKED, has 1 handler(s) for this service...
```

Also confirmed directly, ruling out a real password-file regression:
`show parameter remote_login_passwordfile` on `apexdb1` returned
`EXCLUSIVE` (correct), and the alert log showed nothing past normal
NOMOUNT background-process startup — no password-file errors at all.

**Root cause, confirmed against Oracle documentation:** a NOMOUNT-only
instance can never be more than `BLOCKED` for a `SERVICE_NAME`-based
listener handler — PMON cannot fully register a service until the
database mounts, by design. A `SERVICE_NAME`-routed connection landing on
a `BLOCKED` handler gets its connection closed by the listener, which is
exactly what `TNS-12537` signals (and matches the earlier, general
`ORA-12528: all appropriate instances are blocking new connections`
symptom documented elsewhere for this same class of problem). The
`ORA-01017` on retries was the connection falling through to the OTHER,
`UNKNOWN`-status handler entry for the same service name and failing
authentication there — not a real password problem, and unrelated to
#104's password-file relocation, which is still correctly in place.

This is a well-documented, general RMAN/Data Guard gotcha, not specific
to this lab: connecting to a NOMOUNT auxiliary instance for `DUPLICATE`
must use a `SID`-keyed `CONNECT_DATA`, never `SERVICE_NAME` — `SID`-based
static registration routes directly to the instance process without
passing through the service-handler gate that `BLOCKED` gates.
`apexdb1` is the confirmed real SID (same `lsnrctl status LISTENER`
output, and matches `sid_prefix` + `1` used everywhere else in this
project for the standby's own instance).

**Fix:** `dataguard_duplicate`'s `AUXILIARY` connect descriptor changed
from `(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=apexdb_stby))` to
`(CONNECT_DATA=(SERVER=DEDICATED)(SID=apexdb1))`, still pointed at
`oradbserv09`'s own IP/plain `LISTENER` per #105 (that part was correct
and stays). `TARGET` (the primary, `MOUNTED`/`OPEN`, connecting via a
normal `SERVICE_NAME`) is unaffected — this is specific to connecting to
a NOMOUNT instance.

Sources consulted: Oracle DBA community writeups on `ORA-12528`/
`TNS-12537` during RMAN active `DUPLICATE` to a NOMOUNT auxiliary, all
converging on the same SID-vs-SERVICE_NAME distinction and the
static-registration requirement for NOMOUNT instances (consistent with
#105's own finding that dynamic PMON registration can't help a NOMOUNT
instance either).

## 107. #106's SID-based fix still failed — `TNS-12518`/`TNS-12547`/`TNS-12560` — `gi_db_home_clone`'s tar-then-unarchive clone silently drops the setuid bit on `$ORACLE_HOME/bin/oracle`

Even with #106's `SID=apexdb1` connect descriptor, `AUXILIARY` still failed
— but with a materially different error than before, which is what led
here rather than back down the SCAN/BLOCKED-handler path again:

```
establish * apexdb1 * 12518
TNS-12518: TNS:listener could not hand off client connection
 TNS-12547: TNS:lost contact
  TNS-12560: TNS:protocol adapter error
```

James enabled listener-side tracing (`lsnrctl set trc_level support` /
`trc_directory` / `trc_file` — the dynamic, no-file-edit approach, avoiding
any conflict with `dataguard_net_config`'s own `blockinfile`-managed
`listener.ora`) and pulled both the trace and `oradbserv09_listener.log`/
`oradbserv05_listener.log` for direct comparison. The listener log was
decisive: `oradbserv09`'s log showed this exact `12518`/`12547`/`12560`
sequence on every real connection attempt to `apexdb1`/`apexdb_stby`,
regardless of `SERVICE_NAME` vs `SID` syntax, going back hours —
including a manual `SID=apexdb1` test James ran well before #106's code
fix even existed. `oradbserv05`'s log, over the same multi-hour window,
showed dozens of `establish * apexdb * 0` entries — RMAN and sqlplus, from
every node in the lab — with zero hand-off failures. That ruled out a
general 19c-grid/12.2-db compatibility problem; it was specific to
`oradbserv09` handing off to its own local instance.

**Root cause, confirmed against documented Oracle behavior:** `TNS-12518`
+`TNS-12547` +`TNS-12560` together is the signature of a listener that
successfully finds the target SID/service but can't complete the
handoff — the grid-owned `LISTENER` process (owned by `grid`) forks/execs
`$ORACLE_HOME/bin/oracle` (owned by `oracle`) to spawn the dedicated
server, and that only works if the `oracle` binary has its setuid bit set
(`oracle:oinstall`, mode `6751`). Confirmed directly: `ls -l
$ORACLE_HOME/bin/oracle` on both `oradbserv09` and `oradbserv10` showed
`-rwxr-x--x` — no setuid bit — while the file itself (size, mtime) matched
the source exactly, ruling out corruption. `oradbserv05` (never touched by
`gi_db_home_clone` — it's the original installer-built source) has the bit
set correctly.

The mechanism: `oradbserv05`'s software went through a normal silent
install, where `root.sh` (via `rootadd_rdbms.sh`) explicitly sets this bit.
`oradbserv09`/`10` got their DB home via `gi_db_home_clone`'s
tar-then-`unarchive` clone (#65/#66) instead — that flow deliberately
bypasses the installer (and therefore `root.sh`) entirely, and somewhere
in the tar/copy/`unarchive` pipeline the setuid bit didn't survive onto
either cloned node, while the untouched original was unaffected. Fits the
evidence exactly: both clone targets broken identically, source clean.

**Fix, immediate:** `chmod 6751 $ORACLE_HOME/bin/oracle` as the `oracle`
user (no root needed — `oracle` already owns the file) on both
`oradbserv09` and `oradbserv10`. No listener reload or instance restart
required. Confirmed working: the very next manual connection attempt
progressed past `TNS-12518` entirely and reached a normal Oracle-level
response (`ORA-01033`, expected for a non-`AS SYSDBA` connection to a
NOMOUNT instance — not a new problem).

**Fix, structural:** added a task to `gi_db_home_clone`, immediately after
the DB home `unarchive` task, re-asserting `owner`/`group`/`mode: "6751"`
on `{{ db_home }}/bin/oracle` explicitly — so a future full lab rebuild
via this role doesn't silently reintroduce the same gap. Not extended to
other Oracle setuid binaries (`extjob`, `oradism`, etc.) since this is the
only one confirmed broken and needed here — no guessing at unconfirmed
gaps.

Sources: [TNS-12518: TNS:listener could not hand off client connection on 12c Upgrade](https://community.oracle.com/mosc/discussion/3730335/tns-12518-tns-listener-could-not-hand-off-client-connection-on-12c-upgrade),
[Database - TNS-12518 - TNS:listener could not hand off client connection](https://docs.oracle.com/en/error-help/db/tns-12518/)

## 108. #107's fix still failed — `ORA-01017` — the ASM-based password file (#96/#104) was never actually valid for RMAN's AUXILIARY auth; the classic local `$ORACLE_HOME/dbs/orapw$ORACLE_SID` file is what's CRS-independent, not any ASM/`dbuniquename` mechanism

Even with #107's setuid fix landing (`TNS-12518` gone, replaced by a clean
`ORA-01033` on a non-`AS SYSDBA` test — correct, expected behavior for a
NOMOUNT instance), adding `AS SYSDBA` back produced a genuine, different
failure: `ORA-01017: invalid username/password; logon denied` — on both a
manual `sqlplus ... as sysdba` test and RMAN's own real `AUXILIARY`
connect (`RMAN-04006: error from auxiliary database: ORA-01017`). This is
the first time in the whole #102-#108 chain the failure was a genuine
authentication problem rather than a network/routing/handoff one.

James asked, correctly, why any of this should depend on CRS at all —
`apexdb_stby` isn't registered as a CRS resource yet (no `ora.apexdb_stby.db`,
correctly, since `DUPLICATE` hasn't run) and the instance is a plain
NOMOUNT single instance. I originally answered that the kernel's own
automatic ASM password-file discovery (via the direct `ASMB`-to-ASM-instance
connection visible in the alert log at NOMOUNT startup) is CRS-independent
— true as far as it goes, but I was WRONG to extend that to `asmcmd
pwget/pwcreate --dbuniquename` and to `orapwd ... dbuniquename=`. Both
failed identically and immediately:

```
asmcmd pwget --dbuniquename apexdb_stby
PRCD-1120 : The resource for database apexdb_stby could not be found.
PRCR-1001 : Resource ora.apexdb_stby.db does not exist

orapwd file='+DATA01/apexdb_stby/orapwapexdb_stby' password=sys dbuniquename=apexdb_stby format=12
OPW-00021: Failed to retrieve DB password file location from the CRS resource
```

**Root cause:** the two documented ways to properly TAG an ASM password
file so the kernel's automatic `db_unique_name`-keyed discovery can find
it — `asmcmd pwcreate --dbuniquename` and `orapwd ... dbuniquename=` —
both go through Oracle's CRS resource-lookup layer (`PRCD`/`PRCR`
error-code family, and `OPW-00021` explicitly names it: "Failed to
retrieve DB password file location from the CRS resource") to determine
placement, and neither can run at all before the target's CRS resource
exists. Since #96's original `asmcmd pwcopy` (a plain byte copy, no
`dbuniquename` tagging of any kind) was the only ASM-side mechanism ever
actually used here, and #104 only ever corrected the copy's DIRECTORY
naming — never verified that directory-naming alone was sufficient for
the kernel's discovery without the tagging step — `v$pwfile_users` staying
empty through #104/#105/#106/#107 makes sense in hindsight: that ASM
password file was never actually discoverable, regardless of how
correctly its directory path matched the documented convention.

**Fix:** the classic, pre-ASM, purely local password file —
`$ORACLE_HOME/dbs/orapw$ORACLE_SID` (`orapwapexdb1` for this instance) —
has nothing to do with ASM or CRS at all; it's the original mechanism the
kernel has always checked, still fully supported alongside the ASM-based
one. Created directly:

```
orapwd file=$ORACLE_HOME/dbs/orapwapexdb1 password=sys entries=10 format=12
```

Confirmed working immediately: `v$pwfile_users` populated on the next
local check, and the exact `AUXILIARY` connect string
`dataguard_duplicate` uses (`SID=`, direct IP, `AS SYSDBA`, per #106/#107)
connected cleanly. James had actually tried exactly this idea by hand once
before, during #105's diagnostic marathon — but used the wrong filename
(`pwdapexdb`, `db_unique_name`-keyed with a `pwd` prefix) instead of the
convention the kernel actually looks for (`orapw` + the instance's own
`SID`), so it silently never got found and was written off as a harmless,
removable leftover at the time. Same right instinct, wrong filename.

**Scope, deliberately narrow:** this is a single-node fix, local to
`oradbserv09`'s own filesystem — won't extend to `oradbserv10` and won't
survive this node being reprovisioned. Acceptable for now: RMAN's
`AUXILIARY` connection for Phase 4's `DUPLICATE` only ever runs from
`oradbserv09`. Once `DUPLICATE` creates the real database and it's
registered with CRS (`srvctl add database`, expected later in this
project), the `dbuniquename`-tagged ASM mechanism will finally have what
it needs to work, and that's the right time to move to a proper shared
ASM password file for the RAC-converted standby — not now.

**Folded back into the automation:** added a task to
`dataguard_standby_prep`, right after the existing ASM `pwcopy` task,
that creates this local password file via `orapwd` (idempotent — checks
for the file first, matching this project's established check-then-act
idiom) rather than leaving it as a manual step. Requires `sys_password`
to be passed to that role's own run now, not just `dataguard_duplicate`'s
— a full rebuild invoking `--tags dataguard_standby_prep` on its own will
need `-e sys_password=...` going forward. The ASM-based `pwcopy` from
#96/#104 is left in place, not removed — harmless, and becomes the right
starting point once CRS registration makes its `dbuniquename` tagging
possible later.

**Update:** also duplicated into `dataguard_duplicate` itself (same
idempotent check-then-`orapwd` pattern), since `site.yml` runs
`dataguard_standby_prep` and `dataguard_duplicate` as two separate plays
with two separate tags — a run scoped to just `--tags dataguard_duplicate`
alone (retrying Phase 4 in isolation, or after a node reprovision) would
never reach the copy living only in `dataguard_standby_prep`. Cheap and
harmless to have it in both places; each checks for the file first.

## 109. RMAN `DUPLICATE` actually completed successfully for real — but Ansible reported the task FAILED, because `failed_when`/`changed_when` checked `stdout`, and `rman cmdfile=...log=...` never sends its real output there

First full real run of `dataguard_duplicate` against the live lab, after
#106/#107/#108 all landed. `dg_duplicate.log` on `oradbserv09` — read
directly, not inferred — shows a completely clean, fully successful run:
target/auxiliary connected, all 4 channels allocated, spfile/password
file/control file restored from the primary over the network, every
datafile (1/3/4/5/7) restored and switched to a real ASM datafile copy
under `+DATA01/APEXDB_STBY/DATAFILE/...`, archived logs restored and
applied, media recovery completed, ending in `Finished Duplicate Db at
15-AUG-26` / `Recovery Manager complete.`. The standby database is
physically real at this point.

Ansible reported the task `FAILED! => changed=false` anyway, with `rc: 0`
(rman's own process exit code was fine) and `stdout: 'RMAN> 2> 3> ... 32>
'` — just the bare interactive prompt echoes, none of the actual
substantive output.

**Root cause, entirely mine, not an environment issue:** the task invoked
`rman cmdfile={{ ... }}.rman log={{ ... }}.log` — supplying BOTH
`cmdfile=` and `log=`. With `log=` present, rman redirects essentially all
of its real output — every line, including the success/failure text the
`failed_when`/`changed_when` were searching for — to the LOG FILE, not to
its own stdout/stderr. Ansible's `shell` module only ever captures
stdout/stderr, so `dg_duplicate_run.stdout` was never going to contain
`'Finished Duplicate Db'` regardless of what actually happened — the
`failed_when` clause (`'Finished Duplicate Db' not in
dg_duplicate_run.stdout`) was unconditionally true, every single time,
success or failure alike. A real, fully successful `DUPLICATE` and a
genuinely failed one would have produced the exact same (wrong) Ansible
result. This bug existed from when the role was first written and simply
never surfaced until an actual, complete, real run happened.

**Fix:** split into three tasks. The `rman cmdfile=...log=...` task itself
now only checks `rc != 0` (trusts rman's process exit code as the primary
signal — imperfect on its own for rman specifically, which is documented
to sometimes exit 0 despite an `RMAN-` error, but no longer the only
check). A new task reads the actual log file content directly (`cat
{{ staging_dir }}/sql/dg_duplicate.log`). A third task does the real
safety-net check — `'Finished Duplicate Db' not in` / `'RMAN-' in` —
against that log content, not stdout. This preserves the original
defensive intent while checking the stream that actually has the content.

No manual re-run was needed for the DUPLICATE itself — it already
succeeded for real. Confirmed the fixed role now correctly reports success
on this same, already-completed state via its `dg_duplicate_already_done`
idempotency check (instance is `MOUNTED`, not `NOMOUNT`, so the role skips
straight to 8.3's post-duplicate validation section rather than
attempting `DUPLICATE` a second time).

## 110. `asm_redundancy: EXTERNAL` for RECO01 was based on a wrong assumption about this lab's storage — the underlying `.vdi` disks are genuinely on separate physical drives, so `NORMAL` redundancy is actually correct here, matching `DATA01`

Surfaced while diagnosing a real `ORA-15081`/`ASMB is stuck for 280 seconds`
instance termination on `oradbserv09` (root cause: host memory exhaustion —
`free -h` showed 8.6GB of 16GB swap in use, unrelated to redundancy —
resolved by right-sizing `apexdb1`'s SGA on the standby). While reviewing
the disk layout to rule out redundancy as a cause, I initially claimed
`EXTERNAL` (no ASM mirroring) was the *correct* choice for `RECO01` in a
single-VirtualBox-host lab, reasoning that every ASM "disk" is just a
`.vdi` file on the same physical host storage, so mirroring across
failure groups wouldn't protect against anything real. **James corrected
this directly: the `.vdi` files backing `SASMDISK1`-`6` are actually
spread across separate physical disks on the host**, not one shared
disk — meaning ASM two-way mirroring genuinely does protect against a
real failure mode here (one physical disk dying only takes out the VDIs
stored on that drive), the exact same property `DATA01`'s existing
`NORMAL` redundancy already relies on (`v$asm_disk` confirms `DATA01`
already uses one-failure-group-per-disk: `FG_SASMDISK1/2/3`).

This means `group_vars/all.yml`'s original `asm_redundancy: EXTERNAL` —
and its accompanying comment reasoning — was wrong from early in the
project (confirmed present since at least 2026-08-12), not something this
session introduced. `RECO01` was created with `EXTERNAL` redundancy on
both `usatclust1` (primary, already live, not touched) and `usatclust2`
(standby, mid-build) as a result.

**Fix:** `asm_redundancy` changed to `NORMAL`. `grid_silent_install`'s
RECO01-creation task rewritten to match: previously used
`asmca -createDiskGroup -disk ... -disk ... -redundancy {{ asm_redundancy
}}` (fine for `EXTERNAL`, no failure groups needed at all); switched to a
real `CREATE DISKGROUP ... FAILGROUP FG_<disk> DISK '...'` SQL statement
instead, one `FAILGROUP` clause per disk — `asmca`'s own documented CLI
reference doesn't clearly show assigning a *different* failure group to
each of several disks in one `-createDiskGroup` invocation (`-failuregroup`
only appears under `-diskList` mode in the docs), and guessing at
undocumented CLI behavior for a redundancy-critical setting wasn't worth
the risk — plain SQL's `FAILGROUP` clause is unambiguous. `au_size`/
`compatible.asm`/`compatible.rdbms` attributes for the new `RECO01` match
`DATA01`'s real, confirmed values exactly (`asmcmd lsattr -G DATA01 -l`:
`4194304`, `19.0.0.0.0`, `10.1.0.0.0`), not assumed defaults.

**Live fix on `oradbserv09`** (this only affects the standby build —
`usatclust1`'s existing `RECO01` is untouched, live, hosting the real
primary): `apexdb1` shut down, `RECO01` dropped
(`INCLUDING CONTENTS` — this destroys the standby's archived logs, second
control file copy, and FRA, all rebuilt by `DUPLICATE`), recreated as
`NORMAL` with `FG_SASMDISK4/5/6`, then `dataguard_duplicate` re-run —
third full `RMAN DUPLICATE` on this build. Cost of getting this fixed
before rather than after finishing the build.

Also worth naming plainly: this is the second time in this session I
asserted something about Oracle/storage behavior with more confidence
than the evidence supported and had to be corrected by James directly
(the first being `asmcmd`/`orapwd --dbuniquename`'s CRS dependency, #108).
Both times the fix was to verify against what's actually true in this
environment rather than reason from a general assumption.

## 111. `oracle` OS user missing `asmadmin`/`asmoper` group membership — `os_prep` only ever added `asmdba`

James found this by hand on the real `oradbserv09` (context: while chasing
#110's `RECO01` rebuild) and fixed it directly:

```
usermod -G dba,oper,backupdba,dgdba,kmdba,racdba,vboxsf,asmdba,asmadmin,asmoper oracle
```

Checked `os_prep`'s own `oracle_user` group task against this — it only
ever set `groups: "oinstall,dba,asmdba,oper,racdba,{{ vboxsf_group }}"`.
`asmadmin` and `asmoper` were never in that list at all; `asmdba` was
already there and correct (that's Oracle's documented minimum for a
database owner needing to connect to and use ASM-stored files).
`grid_user`'s own group task, right above this one in the same file,
already included all three (`asmadmin,asmdba,asmoper,dba,racdba,...`) —
this gap was specific to `oracle_user`'s line, not a project-wide miss.

Oracle's standard role-separated model normally reserves `asmadmin`
(SYSASM — full diskgroup administration) for the grid/ASM owner only, not
the database owner — but James hit a real, concrete failure that needed
it for `oracle` too, on this actual system, and that empirical result
takes precedence over the general documented convention. Not
second-guessed — added both `asmadmin` and `asmoper` to `oracle_user`'s
group list in `os_prep`, matching `grid_user`'s line exactly, so a future
full rebuild doesn't reintroduce the same gap. `backupdba`/`dgdba`/`kmdba`
deliberately left alone — those are created and populated by the
`oracle-database-preinstall-19c` RPM itself (same precedent already
documented for `oper`'s GID in `group_vars/all.yml`), not something
`os_prep` manages, and there's no evidence `oracle` was actually missing
from them.

Not yet re-verified against a fresh `os_prep` run (would only show up on
a full rebuild or a targeted re-run of `--tags os_prep`/
`--tags standby_os_prep`) — the live fix James already applied by hand
covers the current running nodes regardless.

## 112. Removed the ASM-based password file `pwcopy` chain from `dataguard_standby_prep` entirely — dead weight after #108, per James's direct request

A re-run of `--tags dataguard_standby_prep` (after #110/#111's fixes)
surfaced the full ASM `pwcopy` task sequence again — discover the
primary's password file name, copy it out to OS staging, fetch to the
control node, copy to `oradbserv09`, create
`+DATA01/apexdb_stby`/`.../PASSWORD`, copy back in to the standby's ASM.
James's direct instruction: remove all of it. Only the local
`orapw$ORACLE_SID` task (#108's actual, working fix) needs to remain.

This tracks: #108 already established that this entire ASM-based chain
was never what RMAN's `AUXILIARY` connection actually authenticates
against — `v$pwfile_users` stayed empty through it regardless of how the
ASM directory was named, because a plain `asmcmd pwcopy` never tags the
file for `db_unique_name` auto-discovery the way `asmcmd pwcreate
--dbuniquename`/`orapwd ... dbuniquename=` do, and neither of *those* can
even run before `apexdb_stby` has a CRS resource (which doesn't exist
until `DUPLICATE` creates the database). #108 originally left the ASM
copy in place anyway, reasoning it was "harmless" and might become a
useful starting point once CRS registration made proper tagging possible
later. In practice it was worse than harmless: it was the actual root
cause of three separate real bugs earlier in this project (#94's
`ORA-15046` OMF-suffix issue, #96/#97's `ORA-15173`/missing-parent-
directory issues, #99's `ORA-15005`-tolerance fix), all for a mechanism
that turned out not to matter — and it kept resurfacing on every re-run,
which is what actually prompted removing it now rather than leaving it as
inert legacy code.

**Removed:** "Discover the primary's ASM password file name" through
"Show pwcopy (OS -> standby ASM) output" — the entire block, roughly 130
lines, including the ASM `+DATA01/apexdb_stby` directory-creation block.
**Kept:** the local `$ORACLE_HOME/dbs/orapw$ORACLE_SID` check-then-create
task (#108), now the only thing this step does. Confirmed nothing
downstream in the role referenced any of the removed block's facts
(`dg_pwfile_name`, `dg_primary_pwfile_asm_path`, `dg_standby_pwfile_alias`,
etc.) before removing it. `high-availability/README.md`'s 7.2 section
updated to match — no longer describes an ASM copy that no longer
happens.

If a future phase needs a real, properly-tagged ASM password file once
`apexdb_stby` is CRS-registered, that's new work at that point, not a
matter of restoring this block — the whole mechanism it used was never
verified working in the first place.

## 113. Forgetting `-e sys_password=...` doesn't fail — it silently creates the standby's password file with the literal placeholder text as the real SYS password

Real, live mistake, my own: after #112's cleanup, I gave James the
re-run command for `--tags dataguard_standby_prep` and left off
`-e sys_password=...`. He ran it exactly as given. The
"Create the local password file for apexdb1 (orapwd)" task reported
`changed` — no error, no warning, nothing that looked wrong — and moved
on to the next task. James caught it not because anything failed, but
because he stopped to ask how the task could possibly know the real SYS
password if he'd never typed it anywhere in this run.

**Root cause:** `group_vars/all.yml` sets `sys_password:
"CHANGE_ME_sys_password"` as a default — a deliberate placeholder,
intended to be obviously wrong if you go looking at the variable's value.
But nothing actually enforced that it gets overridden. Ansible templates
`{{ sys_password }}` into the `orapwd ... password=...` command line
exactly like any other defined variable — a missing `-e sys_password=...`
doesn't produce an "undefined variable" error (the default satisfies
that), it just silently uses the placeholder text itself as the real
password. The task genuinely does succeed, genuinely does create a real,
working password file — just with the wrong password baked into it,
indistinguishable from a correct run in the Ansible output.

`dataguard_duplicate` has the same exposure, and worse: `sys_password` is
also used directly in the RMAN cmdfile's `CONNECT TARGET`/`CONNECT
AUXILIARY` lines — a forgotten override there wouldn't just create a
wrong password file, it would attempt the actual `DUPLICATE` against
wrong credentials.

**Fix:** added an `assert` task to the very top of both
`dataguard_standby_prep` and `dataguard_duplicate` —
`sys_password != "CHANGE_ME_sys_password"` — failing immediately, before
either role does anything else, with a message pointing at the missing
`-e sys_password=...`. Placeholder-default variables that get silently
templated into real commands are a pattern worth remembering for any
future variable of this kind in this project: a default that's merely
*conspicuous* isn't the same as a default that *fails loudly*.

**Live cleanup needed:** the password file `orapwd` created on
`oradbserv09` during the run that surfaced this has `CHANGE_ME_sys_password`
baked in as the real SYS password, not the actual value — needs
recreating by hand with `force=y` (the role's own idempotency check would
otherwise skip re-creating a file that already exists, correct or not):
```
orapwd file=/u01/app/oracle/product/12.2.0/db_1/dbs/orapwapexdb1 password=<real value> entries=10 format=12 force=y
```

## 114. Phase 6 (`dataguard_convert_rac`) design decisions — recorded before the first real run, per this project's own convention

Same convention as #92 (Phase 3) and #101 (Phase 4): write down the design
reasoning before the first real run against the lab, not after, so it's
possible to tell later whether a fix was actually needed or the design was
already right. Phase 4 finished in a genuinely messy state (see
`high-availability/README.md` Section 10's own honesty note — 8 more real
bugs, #106-#113, and a final phase that still isn't confirmed fully clean).
This entry originally called `dataguard_convert_rac` "Phase 5" — renumbered
to Phase 6 (James's call, #118's `dataguard_srl_cleanup` now runs first as
Phase 5) after this entry was written; left as-is below rather than
rewritten throughout, since the role name is the stable anchor. Not run for
real yet at all — everything below is a design, not a confirmed result.

**What "convert to RAC" actually means here — smaller than it sounds.**
`usatclust2` has been a real, fully-configured 2-node Grid Infrastructure
cluster since Section 9 (`grid_silent_install`) — `crsctl stat res -t` has
shown both `oradbserv09` and `oradbserv10` online for every cluster resource
since that section went green. The only thing that was ever single-instance
was the DATABASE, `apexdb_stby`, because RMAN `DUPLICATE ... FOR STANDBY`
necessarily creates one instance first (it has to connect `AUXILIARY` to
something). Phase 5 is "register the database with CRS and add a second
instance," not "build a cluster" — worth stating plainly since the phrase
"convert to RAC" invites assuming much more work than is actually left.

**Why not `rconfig`.** Oracle's documented `rconfig` XML-based converter
(`ConvertToRAC_AdminManaged.xml`, under
`$ORACLE_HOME/assistants/rconfig/sampleXMLs`) targets a plain single-instance
PRIMARY database — it has no concept of a database already in the physical
standby role, doesn't know to stop/restart managed recovery, and every
worked example found describes converting a primary. The standby-specific
procedure is manual, confirmed against a real-world writeup of exactly this
scenario: Jason Brown, "Convert a single instance standby (dataguard) into a
RAC Standby" (jasonbrownsite.wordpress.com, 2017) — stop MRP, add
per-instance parameters, register with `srvctl`, start each instance in
`MOUNT` (never `OPEN` — it's a standby), restart MRP once instance 1 is
CRS-managed, then bring instance 2 up. Cross-checked against Oracle's own
19c RAC Administration and Deployment Guide chapter, "Converting
Single-Instance Oracle Databases to Oracle RAC and Oracle RAC One Node,"
which confirms `rconfig`/DBCA/OEM are the three documented general-purpose
converters and none of the three specifically handle the standby-role case
the blog post above walks through by hand.

**Why this project's situation needs less than the generic guide describes.**
A comment thread on that same blog post points out the generic procedure
also needs, on the PRIMARY: `alter database add logfile thread 2`, `alter
database enable public thread 2`, and `create undo tablespace UNDOTBS2` —
i.e., thread 2 and a second undo tablespace don't exist yet and have to be
created from scratch. None of that applies here: `usatclust1` (the primary)
has been 2-node RAC since Phase 0 of this project, so thread 2 and its own
undo tablespace already exist as real, physical primary-side objects —
Phase 4's `DUPLICATE ... FROM ACTIVE DATABASE` already copied them onto the
standby along with everything else. `dataguard_convert_rac` doesn't create
either one; it queries `dba_tablespaces` on the standby itself to find the
real thread-2 undo tablespace name (not hardcoded — see the role's own
"discover" task) and points `apexdb2`'s parameters at what's already there.

**Why the spfile path is discovered, not assumed.** This project has
already been burned once this segment by assuming a spfile's location
instead of checking it (the `ORA-01565`/`spfileapexdb1.ora` dead end during
Phase 4 debugging, resolved outside this doc's numbered bugs since it
turned out to be a real-time state question, not a structural one — see the
chat history around the `ls -la` check that disproved the "stale file"
theory). `dataguard_convert_rac` runs `show parameter spfile` against the
live `apexdb1` instance and uses whatever path that actually returns for
`srvctl add database -p`, rather than assuming the OMF-generated ASM path
RMAN's `SET` clauses would typically produce.

**Sequencing: instance 1 fully up and applying before instance 2 starts.**
Matches the blog post's own order, not a symmetrical "start both" — start
`apexdb1` via `srvctl` in `MOUNT`, restart managed recovery, only then start
`apexdb2`. Worth stating plainly for anyone reading the role and expecting
parallel apply once both instances are up: in a standard Oracle Data Guard
physical standby, redo APPLY runs on a single designated instance regardless
of how many instances the standby database has — every instance can
transport/forward redo, but only one applies it. Adding `apexdb2` here is
about role services, session distribution, and being switchover-ready later,
not splitting apply work across nodes.

**Not yet run for real.** Everything above is a design justified against
real documentation and a real third-party account of this exact scenario —
none of it has been confirmed against `usatclust2` yet. Update this entry
(or add a new one) with whatever actually breaks on the first real run,
same as every other phase in this project.

## 115. `apexdb_stby`/`apexdb_stby_dg` can't use SCAN yet — the standby isn't CRS-registered until Phase 5, and log_archive_dest_2 was pointed at the wrong service name on both sides

Real, live fix — James diagnosed and tested this directly, then pasted the
definitive, working `tnsnames.ora` and the exact `ALTER SYSTEM` commands he
ran on both the primary and standby. Managed recovery confirmed working
afterward. This entry folds that fix back into the automation, same pattern
as every other hand-found fix in this project.

**Root cause.** `dataguard_net_config` (Phase 2) built `apexdb_stby`/
`apexdb_stby_dg` against `dg_standby_scan_fqdn`
(`scan-usatclust2.usat.com`) — the same SCAN-based pattern that already
works correctly for the primary's `apexdb`/`apexdb_dg`. The difference:
`usatclust1` (primary) has been a real, CRS-registered 2-node RAC database
since Phase 0, so PMON has always dynamically registered `apexdb`'s service
with every listener, SCAN included. `apexdb_stby` is not CRS-registered —
that's Phase 5 (`dataguard_convert_rac`), which hasn't run for real yet
(#114). With no CRS registration, nothing dynamically registers
`apexdb_stby`'s service with usatclust2's SCAN listeners at all — only the
plain per-node `LISTENER` on `oradbserv09` has a *static* entry for it
(#105/#106's fix, deliberately scoped that narrowly at the time). Any
connection routed through SCAN for `apexdb_stby` was therefore never going
to find the service, regardless of DNS/round-robin health — the same class
of gap #105 diagnosed for RMAN's `AUXILIARY` connection during `DUPLICATE`,
just resurfacing here for ordinary client connections and redo transport
once the standby was up and running.

**The fix — use the standby's own node hostname, not SCAN, until Phase 5.**
James's tested, working `tnsnames.ora`:

```
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
```

Two real changes from what `dataguard_net_config` had been generating:
`HOST` is the plain node hostname (`oradbserv09.usat.com`), not
`scan-usatclust2.usat.com`; and `apexdb_stby` now also carries `(UR = A)`
— previously only `apexdb_stby_dg` did. With that addition, the two
standby aliases are now functionally identical apart from their name — the
`_dg` suffix no longer buys anything the plain alias doesn't already have.
The primary side (`apexdb`/`apexdb_dg`, still SCAN-based) is unchanged —
this is a standby-only fix, exactly as James specified: *"We need to be
using the hostname for now on the standby by ONLY. The Primary database
stays the same."* `dataguard_net_config`'s `blockinfile` block now reads
from a new var, `dg_standby_node1_fqdn` (`oradbserv09.usat.com`), instead of
`dg_standby_scan_fqdn`. `dg_standby_scan_fqdn` is deliberately left defined
in `group_vars/all.yml`, not deleted — it's exactly what to switch back to
once Phase 5 has actually run and `apexdb_stby` is a real, CRS-registered,
dynamically-PMON-registered RAC database, the same way `apexdb` already
works today.

**Second, related fix — `log_archive_dest_2` was pointed at the now-redundant `_dg` alias on both sides.** With `apexdb_stby` itself now carrying
`(UR=A)`, there's no functional reason for `log_archive_dest_2` to keep
using the separate `_dg`-suffixed service name — and James's live testing
confirmed the plain alias works correctly for redo transport in both
directions:

```sql
-- Primary (apexdb), log_archive_dest_2 -> standby:
ALTER SYSTEM SET LOG_ARCHIVE_DEST_2 = 'service=apexdb_stby async valid_for=(online_logfiles,primary_role) db_unique_name=apexdb_stby' SCOPE=BOTH SID='*';

-- Standby (apexdb_stby), log_archive_dest_2 -> primary (for the standby's
-- own future primary role, post-switchover):
ALTER SYSTEM SET LOG_ARCHIVE_DEST_2 = 'service=apexdb async valid_for=(online_logfiles,primary_role) db_unique_name=apexdb' SCOPE=BOTH SID='*';
```

(previously `service=apexdb_stby_dg` on the primary side, and
`service=apexdb_dg` on the standby side's `DUPLICATE` `SET` clause.)
`dg_primary_redo_service`/`dg_standby_redo_service` (the two group_vars that
supplied the `_dg`-suffixed names) are removed from `group_vars/all.yml`
outright — same "remove, don't leave unused" precedent as #75/#112 — and
`dataguard_primary_prep`'s and `dataguard_duplicate`'s own
`log_archive_dest_2` lines now reference `dg_standby_db_unique_name`/
`db_unique_name` directly. `log_archive_config` needed no change on either
side — James's own SQL just confirmed the existing value
(`dg_config=(apexdb,apexdb_stby)`), which already matched what both roles
were already setting.

**Third, unrelated but folded in at the same time — Flashback Database
retention raised from 24h to 3 days.** James ran this by hand on both
databases after Phase 4:

```sql
ALTER SYSTEM SET DB_FLASHBACK_RETENTION_TARGET = 4320 SCOPE=BOTH SID='*';
```

`dataguard_primary_prep`'s flashback-retention logic used to be bundled
inside the same `when: 'YES' not in dg_flashback_check.stdout` guard as
turning Flashback Database on in the first place — meaning once flashback
was already enabled (true from the very first real run), a later change to
the retention target would never reach the primary on a re-run; the whole
block would just skip. Split into its own real check-then-act pair
(`select value from v$parameter where name = 'db_flashback_retention_target'`,
then `alter system set ... scope=both` only if it doesn't already match) so
the retention target stays correctly enforced independent of whether
flashback itself was just turned on or has been on for a while.
`dataguard_duplicate`'s `DUPLICATE ... SET` clause list didn't set this
parameter at all before — inherited whatever the primary's spfile said at
the moment of duplication — now sets it explicitly
(`set db_flashback_retention_target='{{ dg_flashback_retention_minutes }}'`)
so a future rebuild gets the real value from the start rather than needing
the same manual follow-up fix again. New shared var,
`dg_flashback_retention_minutes: 4320`, in `group_vars/all.yml`.

**What's still open.** This fix has been tested and confirmed working by
James directly (managed recovery running) — but only against the
already-running `apexdb_stby` instance, by hand. The automation changes
above haven't been run for real yet; if a future `--tags
dataguard_net_config`/`dataguard_primary_prep`/`dataguard_duplicate` run
surfaces anything different, update this entry. Also worth remembering:
once Phase 5 (#114) actually runs and `apexdb_stby` becomes a real
CRS-registered RAC database, revisit whether `apexdb_stby`/`apexdb_stby_dg`
should switch back to `dg_standby_scan_fqdn` — this fix is explicitly a
"for now" state, not a permanent design decision.

## 116. Standby password file should be a real COPY of the primary's, not an independently-generated one — `orapwd` demoted to an explicit fallback

Real, direct fix from James — a different, better mechanism than #108's
original conclusion, not a reversal of it. Kept the local-file *location*
#108 confirmed correct ($ORACLE_HOME/dbs/orapw$ORACLE_SID), changed how
that file's *content* gets produced.

**Why `orapwd` alone was never quite right, even though it worked.** #108
confirmed the classic local password file is what RMAN's `AUXILIARY`
connection (and the kernel generally) actually authenticates against on
this project's standby nodes — that finding stands, unchanged. What #108
didn't address: a password file `orapwd`'d fresh on the standby only ever
contains `SYS`, with whatever `password=` was passed at creation time. It
has no way to know about any other privileged-user grants
(`SYSDBA`/`SYSOPER`/`SYSBACKUP`/`SYSDG`/`SYSKM`) that may exist on the
primary's own password file. Oracle's own Data Guard documentation is
explicit about this: the recommended, supported procedure is to copy the
PRIMARY's password file to every standby whenever it changes, specifically
so the file (and every entry in it) stays identical across the whole
configuration — not to have each side generate its own independently. This
project's `orapwd` approach worked for what it was tested against (a bare
`SYS` connection for RMAN's `AUXILIARY`), but it was quietly the wrong
long-term mechanism.

**The fix — pull the primary's real password file out of its own ASM, scp
it to the standby's local filesystem.** James's tested procedure:

```bash
# On oradbserv05 (primary), as grid:
asmcmd pwget --dbuniquename apexdb
# -> +DATA01/APEXDB/PASSWORD/pwdapexdb.261.1241123369 (real path, varies by system)

asmcmd pwcopy +DATA01/APEXDB/PASSWORD/pwdapexdb.261.1241123369 /u01/app/oracle/staging/standby/orapwdapexdb

# As root, scp the staged file to both standby nodes' LOCAL filesystem
# (not ASM), at the same orapw$ORACLE_SID paths #108 already confirmed:
scp /u01/app/oracle/staging/standby/orapwdapexdb oradbserv09:/u01/app/oracle/product/12.2.0/db_1/dbs/orapwapexdb1
scp /u01/app/oracle/staging/standby/orapwdapexdb oradbserv10:/u01/app/oracle/product/12.2.0/db_1/dbs/orapwapexdb2

# Fix ownership on each standby node:
chown oracle:oinstall /u01/app/oracle/product/12.2.0/db_1/dbs/orapwapexdb1   # oradbserv09
chown oracle:oinstall /u01/app/oracle/product/12.2.0/db_1/dbs/orapwapexdb2   # oradbserv10
```

**Important — do not confuse this with the ASM-tagged `pwcopy`/`pwcreate`
chain #108/#112 already removed.** That earlier chain tried to make the
STANDBY's own ASM storage discoverable via `db_unique_name` tagging
(`asmcmd pwcreate --dbuniquename apexdb_stby`, or `asmcmd pwcopy` into a
`+DATA01/apexdb_stby/PASSWORD` directory) — both require a CRS resource for
`apexdb_stby` that doesn't exist pre-`DUPLICATE`/pre-Phase-5, which is
exactly why that chain never worked and was removed outright. This new
approach only ever touches the PRIMARY's ASM (`apexdb`, already
CRS-registered, already working — `asmcmd pwget --dbuniquename apexdb`
succeeds because `apexdb`'s CRS resource has existed since Phase 0) to
*read* a file, then writes the result to the standby's plain OS filesystem
— the exact same location the kernel already searches per #108, just with
real, primary-sourced content instead of freshly generated content.

**Automation.** Folded into all three roles that create the local password
file on a standby node — `dataguard_standby_prep` (apexdb1/oradbserv09,
the primary implementation), `dataguard_duplicate` (apexdb1/oradbserv09
again, duplicated for the same `--tags`-isolation reason #108 originally
established), and `dataguard_convert_rac` (apexdb2/oradbserv10 — James's
own manual example already named both nodes/SIDs, since a Phase 5 rebuild
needs this too). Each follows the same sequence: `asmcmd pwget
--dbuniquename apexdb` on the primary (delegated, no explicit
`environment:` needed — asmcmd resolves its own home and connects to the
local ASM instance without an `ORACLE_SID` override, confirmed against
`dataguard_primary_prep`'s own existing `asmcmd ls`/`mkdir` tasks, which
already work with no `environment:` block); `asmcmd pwcopy` that path to a
staging file under `{{ staging_dir }}/standby/`; `fetch` it to the control
node (same relay pattern `gi_db_home_clone` and `dataguard_standby_prep`
already use for cross-node file movement, rather than assuming root SSH
equivalence between nodes exists — it doesn't, only grid/oracle
equivalence does); compare its checksum against whatever's already on the
target node (`stat` with `checksum_algorithm: sha1`); `copy` it into place
(`oracle:oinstall`, mode `0640`) only if different; delete both staging
copies afterward (real password material, same cleanup discipline as the
RMAN cmdfile elsewhere in this project). Checksum-gated rather than
existence-gated on purpose — unlike `orapwd`'s "create once, then leave
alone" model, this file is supposed to track the primary's, so a changed
primary password should propagate on a later re-run, not be silently
skipped because *a* file already happens to exist.

**`orapwd` is kept, not deleted — an explicit, selectable fallback.**
New var, `dg_pwfile_method` (`group_vars/all.yml`), default
`copy_from_primary`; set `-e dg_pwfile_method=orapwd` to fall back to
#108's original mechanism if the copy approach ever can't run in some
environment. Both code paths live side by side in each role, gated by this
one variable, rather than the fallback being silently attempted on
failure — matches this project's general preference for explicit,
operator-driven choices over implicit fallthrough behavior.

**Not yet run for real.** Tested and working per James's manual walkthrough
— the automation above hasn't been exercised end to end yet. If a real run
surfaces anything different (a permissions gap on the `asmcmd pwcopy`
staging path, a checksum mismatch that shouldn't be there, `dg_pwfile_method`
not propagating correctly to a role that needs it), update this entry.

## 117. Pre-redo code audit — three real bugs found and fixed, plus two flagged risks left as-is

James asked for a full code audit of every role touched by the standby
build (`dataguard_net_config`, `dataguard_primary_prep`,
`dataguard_standby_prep`, `dataguard_duplicate`, `dataguard_convert_rac`,
plus `group_vars/all.yml` and `site.yml`) before attempting a redo, purely
by re-reading — no live host access this session. Three real bugs were
found and fixed; two more were identified and are documented here rather
than fixed blind, since neither has a cheap, obviously-correct fix without
a real run to verify against.

**Fixed #1 — flashback retention idempotency check was silently
always-true.** `dataguard_primary_prep`'s check compared
`(dg_flashback_retention_check.stdout | trim | int)` against the target
minutes. `set echo on` means `.stdout` holds the whole SQL*Plus transcript
(echoed command + result), not a bare number — Jinja's `int` filter doesn't
error on unparseable input, it silently returns `0`. So the check always
read "current retention = 0", always decided a change was needed, and
harmlessly-but-pointlessly re-ran the `alter system` every single time
regardless of the real value. Fixed with a dedicated `set_fact` that
extracts the pure-numeric line first: `stdout_lines | select('match',
'^[0-9]+) | list | first | default('-1')) | int`.

**Fixed #2 — templated `become`/`become_user` in a loop.** The original
password-file staging cleanup in `dataguard_standby_prep`,
`dataguard_duplicate`, and `dataguard_convert_rac` used one looped task with
`delegate_to: "{{ item.host }}"`, `become: "{{ item.become }}"`,
`become_user: "{{ item.become_user | default(omit) }}"` — a pattern never
exercised in a real run anywhere else in this project. Split into two plain,
explicit tasks (clean up on the primary, clean up on the control node) in
all three roles, matching how every other multi-host cleanup in this
project is written.

**Fixed #3 — `dataguard_duplicate`/`dataguard_convert_rac` missing from the
`rac_nodes` bootstrap-tags list.** Both roles delegate to the primary node
for password-file operations, but `site.yml`'s `rac_nodes` play (which
bootstraps `python3` etc. before any role needing it can run) didn't list
either tag. Added both to that play's tags list.

**Flagged, not fixed — `dataguard_convert_rac`'s CRS-registration sequence
isn't safely re-runnable from a partial failure.** The role's one
top-level gate (`dg_convert_rac_already_done`) only goes true once srvctl
shows *both* `apexdb1` and `apexdb2` registered. If a run fails between
`srvctl add database` and the second `srvctl add instance` — e.g. instance 2
fails to register because of a bad hostname — a retry re-attempts `srvctl
add database` against a database that's already registered, which fails
loudly (`PRCD-1121: already exists`). Recovery in that specific scenario is
manual: run `srvctl config database -d apexdb_stby` by hand to see what's
actually registered, then run only the missing `srvctl add instance`
command yourself before re-running the role (or comment out the tasks that
already succeeded for that one run). Not fixed automatically this session —
untangling per-resource idempotency here (separate checks for the database
resource vs. each instance resource) touches live CRS state directly, and
without a real cluster to verify against, a guessed fix risks being wrong
in a worse way than the current all-or-nothing gate. Worth doing before a
real redo if there's appetite for it, but the honest move was to flag it
rather than patch it blind.

**Flagged, not fixed — the project-wide "two known error codes else assume
success" idempotency idiom.** Several checks across these roles (e.g.
`dataguard_standby_prep`'s "is the auxiliary instance already started"
check) work by matching specific ORA-xxxx codes for the "not yet done"
case, then assuming "already done" for anything that doesn't match either
code — including an unrelated, unexpected error. In every case this
session found it, the very next task re-displays the raw SQL*Plus output
via `debug:`, so a human reviewing the run (all of these phases pause
for review anyway) would still see a real error surface in the output even
if the summary message next to it says "already done." Low risk given how
interactively these phases are run, but worth knowing about if any of this
is ever converted to a fully unattended pipeline.

## 118. apexdb_stby's standby redo logs came out multiplexed across +DATA01/+RECO01, not single-member like the project's own design — new `dataguard_srl_cleanup` role (Phase 5) removes the +DATA01 copy

James's request, to run only after the standby is confirmed working
(managed recovery applying, transport lag healthy).

**Root cause.** This project's own documented design for standby redo logs
is single-member, `+RECO01` only — see `group_vars/all.yml`'s `dg_srl_*`
block and `dataguard_primary_prep`'s SOP 5.5 section, which builds the
PRIMARY's own (future-switchback) SRLs exactly that way via explicit `ALTER
DATABASE ADD STANDBY LOGFILE ... ('+RECO01') SIZE 128M` statements, one
member each. `apexdb_stby`'s own SRLs were never built by that same logic —
Phase 4's RMAN `DUPLICATE ... FOR STANDBY` sets `standby_file_management=
'auto'` AND sets both `db_create_online_log_dest_1='+DATA01'` and
`db_create_online_log_dest_2='+RECO01'` (correctly needed so DUPLICATE
places the real datafiles/online redo logs across both diskgroups). Oracle's
documented behavior for `STANDBY_FILE_MANAGEMENT=AUTO` with two
`DB_CREATE_ONLINE_LOG_DEST_n` destinations set is to auto-create every new
redo-log-like file — standby redo logs included — multiplexed across both
destinations. That's what put a `+DATA01` member on every `apexdb_stby` SRL
group: a correct setting for the online redo logs, with an unintended side
effect on the standby redo logs specifically.

**The fix, James's own tested procedure, followed literally:**

```sql
column member format a50
select group#, member from v$logfile where type='STANDBY' order by 1,2;

set linesize 150
set pagesize 22
select 'alter database drop standby logfile member ''' || member || ''';'
from v$logfile where type='STANDBY' and member like '+DATA%';
-- run each generated statement
```

If `ORA-00261` fires on a specific member (the redo transport service is
still using it), the remedy is `alter system switch logfile;` run a few
times on each primary node, then retry the drop for just that member.

**Automation — `dataguard_srl_cleanup` (Phase 5, `--tags
dataguard_srl_cleanup`).** Sequenced before Phase 6 (`dataguard_convert_rac`)
— this is basic Data Guard hygiene on the single-instance standby DUPLICATE
just created, no CRS registration needed first. `hosts: standby_node1`, same as
`dataguard_duplicate` — `v$logfile`/`v$standby_log` read from the shared
standby control file, so querying/dropping from oradbserv09 alone is
correct regardless of which standby instance is currently up. Sequence: log
the baseline member list; generate the DROP statements via the exact
SPOOL-to-file technique above (member names are ASM-assigned, only knowable
at run time — same reasoning `dataguard_convert_rac` already uses for its
own undo-tablespace/spfile discovery); pause for review showing every
statement about to run; execute (no `WHENEVER SQLERROR EXIT` — deliberately
left at SQL*Plus's default of continuing past an individual `ORA-00261` so
every other member still gets dropped in the same pass); re-query the
`+DATA` member count. If anything is left, force 3 `alter system switch
logfile;` on EACH primary node (thread 1 and thread 2 map to different SRL
groups, so both nodes need to cycle — computed via `primary_nodes`, not
`nodes`, since this play runs on a standby-group host where `nodes` is
redirected to mean usatclust2's own list; same bug class as #86, avoided
here) and retry the whole generate-review-run sequence exactly once more.
If members are still stuck after that, the role stops with a `fail:` giving
the exact manual commands to finish by hand, rather than looping silently —
James asked directly for that fallback if the automation can't complete it.

**Not yet run for real.** Built from James's tested manual procedure, but
the automation itself hasn't been exercised end to end. If a real run
surfaces anything different — the `product` filter behaving unexpectedly
across the two primary nodes, the retry count needing to be higher than 3,
`v$logfile`'s member path format not matching `+DATA%` cleanly — update this
entry.

**Confirmed clean.** `dataguard_net_config` (TNS aliases, listener.ora
static entries, connectivity tests — all correctly using
`dg_standby_node1_fqdn` per #115), `dataguard_standby_prep`'s and
`dataguard_duplicate`'s password-file copy logic (checksum-gated, correctly
distinct control-node vs. target-node stat facts despite similar variable
names), `dataguard_convert_rac`'s undo-tablespace/spfile-path discovery
(indexes into the discovery list without a bounds check, but a mismatch
fails the task loudly rather than silently picking a wrong value — safer
than the in-code comment at the time implied), `group_vars/all.yml` and
`site.yml` (no orphaned references to the removed
`dg_primary_redo_service`/`dg_standby_redo_service` vars anywhere in
current, non-comment code), and `gi_db_home_clone`/`grid_silent_install`/
`os_prep` (spot-checked — the setuid fix (#107), RECO01 NORMAL-redundancy
diskgroup creation (#110), and asmadmin/asmoper group membership (#111) are
all present and intact).

## 119. Phase 5/6 re-ordered (SRL cleanup now runs before RAC conversion); Phase 6's srvctl syntax corrected, password file moved into ASM, and a CRS-config review gate added — all James's direct feedback

**Phase order swapped.** `dataguard_srl_cleanup` is now Phase 5 and
`dataguard_convert_rac` is Phase 6 (was the reverse) — James's call. Both
`site.yml` play order and `high-availability/README.md` Sections 11/12 were
swapped to match; #114 and #118 above were written under the old numbering
and are left as-is rather than rewritten (the role name is the stable
anchor in both), except for their headers and the one live "see Section 11"
cross-reference that would otherwise point at the wrong content.

**`srvctl add database` syntax corrected — James's own command, several
genuine fixes, not just long-form-flag style:**

```bash
srvctl add database -db apexdb_stby -oraclehome /u01/app/oracle/product/12.2.0/db_1 \
  -dbname apexdb -role PHYSICAL_STANDBY -startoption MOUNT -policy MANUAL \
  -diskgroup "DATA01,RECO01" -spfile <discovered path>
```

- `-dbname apexdb` — genuinely missing before, not just a style gap. `-db`
  is the db_unique_name (`apexdb_stby`); without `-dbname` set explicitly,
  srvctl defaults the CRS resource's `DB_NAME` attribute to match `-db`,
  which is wrong — the real `DB_NAME` in `apexdb_stby`'s control file is
  `apexdb`, same as the primary (has to match for any physical standby).
- `-policy MANUAL`, not `-y AUTOMATIC` — James's direct call, asked and
  answered in chat: `AUTOMATIC` means CRS restarts the database on its own
  after a node reboot or CRS bounce, no operator involved (same policy the
  primary runs under); `MANUAL` means CRS will not auto-start it — someone
  has to `srvctl start database` (and separately resume managed recovery)
  by hand. For a standby, that's a deliberate checkpoint so a reboot
  doesn't silently resume redo apply unattended. Trade-off worth keeping in
  mind: it also means an unattended cluster restart leaves the standby down
  until someone starts it.
- `-diskgroup "DATA01,RECO01"` — new, wasn't there before. Registers the
  real ASM dependencies with CRS for correct startup ordering/monitoring.
  Bare names, no leading `+` — that's srvctl's own documented format for
  this specific option (every other ASM path in this project does use `+`);
  James's own pasted example had a stray `+` on the first name only,
  dropped here as a correction, not a literal copy.
- `-spfile` keeps the *discovered* path (`show parameter spfile`, #114's own
  reasoning — queried, not assumed) rather than the literal example path
  James pasted; the long-form flag name was adopted, the value stays
  dynamic.
- `-db`/`-oraclehome`/`-role`/`-startoption` are equivalent to the
  short-form flags the role used before (`-d`/`-o`/`-r`/`-s`) — adopted for
  consistency with the rest of the command, and every other `srvctl`
  invocation in the role (`add instance` x2, `start instance` x2, the new
  `config database` check) was updated from `-d` to `-db` to match.

**Password file moved into ASM — James's direct question: "What about
putting the password file in ASM and pointing to it?"** Answer: yes, and
now is exactly the right point to do it. #108/#112 already tried an
ASM-tagged password file for `apexdb_stby` and found it couldn't work —
`asmcmd pwcreate --dbuniquename apexdb_stby` needs a CRS resource to tag
against, and none existed at that point in the build. That blocker is gone
as of this phase's `srvctl add database`/`add instance` tasks. It's also
the more correct, RAC-idiomatic design: the PRIMARY's own password file
already lives in ASM this same way (`asmcmd pwget --dbuniquename apexdb` on
oradbserv05 returns a real ASM path, not a local file — #116), shared
across both its instances rather than copied out to each node's local
filesystem by hand. New tasks, right after CRS registration: `asmcmd
mkdir -p` the ASM `PASSWORD` directory (harmless no-op if already there);
`asmcmd pwcopy` the already-verified local `orapwapexdb1` file (checksum-
matched against the primary by the existing `copy_from_primary` logic) into
ASM at `+DATA01/apexdb_stby/PASSWORD/pwdapexdb_stby`; `srvctl modify
database -db apexdb_stby -pwfile <that path>` to make it the CRS-registered
authoritative source. Explicit `srvctl modify -pwfile`, not reliance on
ASM's own `--dbuniquename` auto-discovery — `srvctl modify -pwfile` is what
CRS itself actually reads to find the password file at startup for a
CRS-managed instance, so pointing it there directly is the real fix
regardless of whether auto-discovery would also have found it. The local
per-node files (`orapwapexdb1`/`orapwapexdb2`) are left in place, not
deleted — same "keep the old working method as an explicit fallback"
precedent as `dg_pwfile_method: orapwd`.

**New review gate before starting either instance — James's request.**
Added `srvctl config database -db apexdb_stby` as its own task, output
shown via `debug`, followed by a `pause:` before the role starts `apexdb1`/
`apexdb2` — same pattern as the existing pause before `cluster_database=true`
(#114), just one step later, reviewing srvctl's own view of the
configuration (role, spfile, password file, policy, diskgroup dependencies,
both instances/nodes) rather than the SQL-level discovery output.

**Not yet run for real.** All of the above is new since the original
"not yet run for real" write-up (#114) — the `-diskgroup`/`-dbname`
corrections, the ASM password file migration, and the new pause/config-check
gate have not been exercised against `usatclust2` yet. In particular: the
exact `asmcmd pwcopy` destination-path syntax (whether ASM auto-generates an
OMF suffix or accepts the literal alias given) and whether `srvctl modify
-pwfile` accepts that path in the same run it was just created are both
unverified — confirm both on the first real run and update this entry with
whatever actually happens.

**SRL cleanup (Phase 5) — SQL formatting fix.** James caught this from real
`debug:` output he pasted: literal tab characters (`"\t11 +DATA01/..."`) and
a wrapped, truncated member value on its own line (`"\t   155"`). Root
cause: `dg_srl_cleanup_list.sql` was missing `tab off` (SQL*Plus's default
column padding uses real tab characters, not spaces, unless told otherwise —
every other SQL script in this project already sets `tab off`; this one,
written this session, was the one place it got missed), and `column member
format a50` wasn't wide enough for the real ASM path length, so SQL*Plus
wrapped the value onto a second physical line instead of truncating. Fixed:
`tab off` added to `dg_srl_cleanup_list.sql`, `dg_srl_cleanup_count.sql`,
and the `SPOOL` generator script in `drop_attempt.yml` (the last one
wasn't actually showing the bug, but a stray tab there would corrupt the
generated `alter database drop standby logfile member ...;` statements, so
fixed defensively); `column member format a50` widened to `a65`.

## 120. `dataguard_srl_cleanup` now stops and restarts managed recovery around the drop — James's own procedure, wrapped in block/always so it can't be skipped on failure

James's exact sequence, followed literally: `alter system set
standby_file_management=manual`, cancel managed recovery, verify MRP is
actually stopped (`v$managed_standby` returns no rows), drop the standby
logfile member(s), restore `standby_file_management=auto`, restart managed
recovery. The first version of this role (#118) went straight into the
drop with recovery still running — this version doesn't.

**Why this matters, not just "more thorough":** stopping managed recovery
before the drop removes one whole class of interference (MRP actively
reading/switching through standby log groups while a member is being
dropped from underneath it), on top of the log-transport-side ORA-00261
issue #118 already handles. The two are complementary, not redundant —
cancelling MRP stops redo *apply*, but the RFS process still writes
incoming redo into whichever SRL group is currently active regardless of
whether anything is applying it, which is why the log-switch-on-primary
remedy from #118 is still there and still needed even with recovery
cancelled for the duration of the drop.

**Restructured into `block`/`always`, not a flat task list.** This is the
real design change, not just inserting a few more tasks: the whole
baseline-through-drop sequence is now inside a `block:`, and the
restore-`AUTO`-and-restart-MRP sequence is in the matching `always:`.
Ansible guarantees `always:` runs whether the block's tasks succeeded or a
`fail:` fired inside it — including the existing "still stuck after two
attempts" failure from #118. Without this, a failed drop would have left
the standby with `standby_file_management=manual` and recovery cancelled
indefinitely, which is a worse outcome than a few leftover `+DATA` members
— the play still correctly reports failure to James (the `fail:` inside
`block:` isn't swallowed by `always:` running), but the standby itself is
never left worse off than when the role started, whether the drop succeeds
or not.

Idempotency note: `alter database recover managed standby database cancel`
errors (`ORA-16136`) if no MRP is running — matches this project's
established check-then-act idiom (`dataguard_convert_rac`'s own "cancel
managed recovery, only if it was actually running" task), so the cancel is
gated on the initial check finding an `MRP` row first, same pattern reused
here rather than invented fresh.

**Not yet run for real.** Same status as the rest of this role (#118) —
this whole sequence, including the `block`/`always` structure itself, has
not been exercised against `usatclust2` yet.

## 121. First real run of `dataguard_srl_cleanup` failed on a false-positive MRP check — the echoed SQL text itself contains "MRP", not just real result rows

James ran `--tags dataguard_srl_cleanup` for real. It correctly detected
MRP running, set `standby_file_management=manual`, and cancelled it
(`Database altered.`) — then failed at "Fail if MRP is somehow still
running after cancel", even though the query it had just run returned zero
rows (confirmed directly: James re-ran the identical query by hand
immediately after and got `no rows selected`).

**Root cause — the exact bug #117 already fixed once, missed here.** The
check script has `set echo on` (deliberate, everywhere in this project, so
the real transcript is visible in Ansible's `debug:` output). With echo on,
SQL\*Plus echoes the command text itself into stdout before running it:
`SQL> select process, status, thread#, sequence# from v$managed_standby
where process like '%MRP%';`. That echoed line contains the literal
substring `MRP` — it's part of the WHERE clause, `like '%MRP%'` — so
`'MRP' in dg_srl_cleanup_mrp_verify.stdout` was true *unconditionally*,
regardless of whether the query actually returned a row. Confirmed directly
from James's own pasted `debug:` output: `stdout_lines` shows the echoed
`SQL>` line and nothing else between it and `SQL> exit;` — no data, no `no
rows selected` (suppressed by `feedback off`), yet the substring check
still fired. Same underlying mistake as #117's flashback-retention bug
(matching against the whole transcript instead of a specific result line)
— written, ironically, by the same session that had already documented and
fixed that exact failure mode once.

**The same bug existed, undetected, in `dataguard_convert_rac` too** (not
yet run for real, so it hadn't fired) — its own "cancel managed recovery"
gate checked `'MRP' in dg_convert_rac_mrp_check.stdout` against a query
containing `where process like 'MRP%'`, identical root cause. Fixed
proactively at the same time, same way.

**The fix — match a real result row, not the transcript.** A real MRP row
is left-justified and starts with `MRP` (`MRP0  APPLYING_LOG ...`,
confirmed against James's own manual output); the echoed command line
starts with `SQL> select...`. Both roles now parse `stdout_lines |
select('match', '^MRP') | list | length > 0` into a `set_fact` right after
the check query, and every downstream `when:` references that fact instead
of the raw substring check. Also caught in the same pass:
`dataguard_convert_rac`'s own MRP-check script was missing `tab off` (same
class of gap as #119's SRL formatting fix) — added, since a leading tab
before a left-justified `MRP0` would have broken the new `^MRP` anchor
match the same way #119's `column member` wrapping bug happened.

**No damage done — the safety net worked exactly as designed.** This is
worth stating plainly: despite the false failure, the standby was not left
in a bad state. `always:` ran regardless (that was the entire point of
#120's `block`/`always` restructure) — `standby_file_management` was
restored to `AUTO` and managed recovery was restarted, both confirmed in
James's own pasted output (`Database altered.` on the restart, and his
follow-up manual check showed `MRP0  APPLYING_LOG`). The only cost was that
attempt 1 never got to run, so no `+DATA` members were actually dropped by
the automation on this pass. James continued by hand afterward (same
stop/cancel/verify/drop/restore sequence, run manually) and cleared group
13's `+DATA` member himself; group 12 was already single-member on
`+RECO01` before this run even started (from an earlier session, not from
this run's automation). Remaining as of this entry: groups 11, 14, 15, 16
still carry a `+DATA01` member and should be picked up cleanly by a re-run
now that the detection bug is fixed.

## 122. Second real run got further (#121's fix worked) but silently under-delivered — remaining-count regex never matched a right-justified `count(*)`, so the retry-with-log-switch logic never fired

James re-ran `--tags dataguard_srl_cleanup` after #121's fix. The MRP
detection worked correctly this time (`Fail if MRP is somehow still
running` correctly skipped) and attempt 1 dropped 3 of the 4 remaining
`+DATA` members (groups 11, 14, 16) cleanly. Group 15 hit `ORA-00261: log
15 of thread 2 is being archived or modified` — exactly the scenario the
retry logic exists for. But the retry never ran: the debug task titled
`"-1 +DATA member(s) still present — forcing log switches..."` was
*skipped*, along with the actual switch-logfile and attempt-2 tasks. The
play finished with `failed=0` and no success message either — a silent
gap, not a loud failure.

**Root cause.** `dg_srl_cleanup_remaining_1`/`_2` are parsed from
`count(*)` output via `select('match', '^[0-9]+$')` — matches only if the
*entire* line is nothing but digits. `count(*)` has no explicit `column ...
format` in this script, so SQL\*Plus prints it right-justified within its
default NUMBER column width: the real line is `"         1"`, not `"1"`.
The regex never matched, silently fell through to the `default('-1')`
sentinel, and `-1 | int > 0` is false — so the role behaved as if nothing
was left to retry, even though group 15 plainly still had a `+DATA` member
and the drop output plainly showed the `ORA-00261` error two tasks
earlier. The task name itself (`"-1 +DATA member(s) still present..."`)
was the tell — a literal `-1` in a debug message title is the sentinel
leaking through, not a real count.

**The same regex, and very likely the same live bug, existed in
`dataguard_primary_prep`'s flashback-retention check** (`known-risks.md`
#117) — written with the identical `'^[0-9]+$'` pattern, on a
`VARCHAR2(4000)` column with no `column ... format` either, meaning
default padding (trailing, for a left-justified VARCHAR2, rather than
leading) would have broken the match the same way. #117's fix was correct
in every way except that it was never actually verified against a real
SQL\*Plus transcript — it *looked* right and matched an established idiom,
but nothing forced a real run through this exact line until a different
role's identical pattern failed live, in this same session. Fixed
proactively at the same time as the confirmed live bug, same reasoning.

**The fix.** `'^[0-9]+$'` → `'^\s*[0-9]+\s*$'` in all three places
(`dg_srl_cleanup_remaining_1`, `dg_srl_cleanup_remaining_2`,
`dg_flashback_retention_current`). Tolerating leading/trailing whitespace
in the *match* is sufficient — the subsequent `| int` filter already parses
`"         1"` correctly regardless of padding; the only thing that needed
fixing was getting the `select('match', ...)` step to accept the padded
line as a hit at all.

**Broader lesson, worth stating plainly rather than filing away quietly:**
this is the third time this exact class of bug — matching against an
echoed transcript or an unformatted column's default padding, instead of a
precisely-shaped result line — has shown up in this project (#117, #121,
#122), and the second time a fix for one instance of it wasn't
cross-checked against the other instances of the same pattern already in
the codebase. Every `select('match', ...)`-based value extraction in this
project's Data Guard roles should be treated as unverified until it's
actually been run for real at least once — a regex that "looks right" and
matches an established idiom is not the same as one that has been checked
against a real SQL\*Plus transcript.

**Current real state, as of this entry:** groups 11, 14, 16 are confirmed
single-member (`+RECO01` only) per James's own pasted output. Group 15
still carries both members and is the only one left. A re-run should now
correctly detect it, attempt the drop, and — if `ORA-00261` recurs — retry
after switching logfile on both primary nodes, rather than silently
stopping short the way this run did.

**Update:** James re-ran to completion and confirmed all six SRL groups
(11–16) are now single-member (`+RECO01` only). `dataguard_srl_cleanup` is
done — no further open issues on this role.

## 123. First real run of `dataguard_convert_rac`'s discovery step hit two separate bugs — `dba_tablespaces` fails on a MOUNT-only standby, and `show parameter` silently drops a wrapped continuation line

James's first real run of `--tags dataguard_convert_rac` reached the
"Show discovery output (undo tablespaces + current spfile path)" task and
surfaced two distinct problems in the same script.

**Bug 1 — `ORA-01219` on the undo-tablespace query.** The discovery script
ran `select tablespace_name from dba_tablespaces where contents = 'UNDO'
order by tablespace_name;` against `apexdb1`. `apexdb1` at this point in
the role is a physical standby and is only ever MOUNTED — never OPEN, by
design, permanently. `DBA_TABLESPACES` is a dictionary view backed by the
actual data dictionary, which is only accessible when the database is
OPEN, so the query failed outright with `ORA-01219: database or pluggable
database not open: queries allowed on fixed tables or views only`. This
was a design bug, not a formatting one — every other query this project
runs against a MOUNT-only standby (`v$managed_standby`, `v$archived_log`,
`v$database`, etc., throughout `dataguard_srl_cleanup` and
`dataguard_standby_prep`) already correctly uses `V$` fixed views for
exactly this reason; this one script was the one place that reached for a
`DBA_` view instead. Because the query errored rather than returning zero
rows, `dg_convert_rac_undo_ts1`/`_ts2` silently fell through to their
hardcoded `default('UNDOTBS1')`/`default('UNDOTBS2')` — plausible, and
probably even correct, but never actually verified against the real
tablespace names the way the task's own name and comments claimed.

**Fix:** query `V$TABLESPACE` instead — a control-file-backed fixed view,
available while MOUNTED — filtering on `name like 'UNDOTBS%'` rather than
`contents = 'UNDO'`, since `V$TABLESPACE` carries tablespace `NAME` but not
`CONTENTS`. This trades "any undo tablespace, by type" for "any tablespace
matching Oracle's default undo-naming convention," which is not a new
assumption — it's the exact convention this script's own fallback defaults
already relied on — but it is now a live query result instead of a silent
fallback.

**Bug 2 — `show parameter spfile` wrapped its value onto a second physical
line, and only the first line was parsed.** The real output looked like:

```
spfile                               string      /u01/app/oracle/product/12.2.0
                                                 /db_1/dbs/spfileapexdb1.ora
```

`SHOW PARAMETER`'s VALUE column wraps at its own internal width when the
value is long — a `SHOW PARAMETER`-specific quirk, independent of
`set linesize` (unlike ordinary `SELECT` column output, which this project
already controls via explicit `column ... format`). The existing parsing —
`select('match', '^spfile') | list | last).split()[-1]` — only ever sees
the *first* physical line (the only one starting with `spfile`); the
wrapped continuation line starts with whitespace and never matches. James
caught this directly at the pause-for-review gate: "Discovered current
spfile path: /u01/app/oracle/product/12.2.0" instead of the full
`/u01/app/oracle/product/12.2.0/db_1/dbs/spfileapexdb1.ora`.

**Fix:** stop using `show parameter` for this value entirely. Replaced it
with `select value from v$parameter where name = 'spfile';` plus an
explicit `column value format a150`, matching the pattern this project
already uses everywhere else to avoid SQL\*Plus default-formatting
surprises. Parsing changed to `select('match', '^/') | list | last |
default('') | trim` — the spfile here is a local filesystem path under
`$ORACLE_HOME/dbs` (RMAN `DUPLICATE` placed it there in Phase 4, not in
ASM), so matching lines that start with `/` cleanly picks out the real
value and skips the echoed `SQL>` text and blank lines. `default('')`
rather than a hardcoded path default, since there's no safe made-up
fallback for a dynamically-generated spfile path — an empty value will be
visibly wrong at the pause-for-review step rather than silently plausible.

**The pause-for-review gate worked exactly as designed here.** Both bad
values were caught by James reading the discovery output at the existing
"Pause for review... before this role sets cluster_database=true" step,
before `cluster_database=true` was set or `apexdb1` was touched. No damage
done — this is the same safety pattern already validated in #121 for
`dataguard_srl_cleanup`'s `block`/`always` wrapper, now validated again for
a completely different failure mode.

**Not yet confirmed by a real run** — this fix has not yet been exercised
against real output the way #121/#122's fixes were before being reported
back. Per the broader lesson in #122, treat both regexes here as unverified
until James's next `--tags dataguard_convert_rac` run confirms the
discovery output shows real, correctly-formed undo tablespace names and a
complete, unwrapped spfile path.

## 124. `asmcmd mkdir -p` doesn't exist — ASMCMD has no recursive-create flag, and isn't idempotent either

The next task in the same run — creating the ASM `PASSWORD` directory for
`apexdb_stby` before copying the password file into it — failed outright:

```
ASMCMD-9412: Invalid option: p
usage: mkdir <directories...>
```

**Root cause.** ASMCMD's `mkdir` is not Unix `mkdir` — it has no `-p`
option at all on this Grid Infrastructure home, recursive or otherwise.
The task had assumed GNU-mkdir semantics (`-p` creates parent directories
as needed and no-ops if the target already exists) that ASMCMD simply
doesn't implement. James caught this directly from the real failure output
and correctly identified both the missing flag and the fact that the
parent directory almost certainly already exists: `+DATA01/apexdb_stby`
was created back in Phase 4 by RMAN `DUPLICATE ... FROM ACTIVE DATABASE`
to hold the `DATAFILE`/`CONTROLFILE`/`ONLINELOG` subdirectories, so a plain
two-call `mkdir +DATA01/apexdb_stby` then `mkdir
+DATA01/apexdb_stby/PASSWORD` would very likely fail on the first call too
— ASMCMD errors on an existing directory rather than treating it as a
no-op, unlike Unix `mkdir -p`.

**The fix.** Replaced the single `mkdir -p` task with this project's
standard check-then-act idiom, applied twice (once per directory level):
`asmcmd ls <path>` first, `failed_when: false` so a missing directory
doesn't fail the play, then `asmcmd mkdir <path>` only `when:` that check's
`rc != 0`. This correctly handles all three real states: parent exists +
`PASSWORD` missing (the expected case here — only the second `mkdir`
fires), parent missing entirely (both fire, in order), and a full re-run
after this role has already completed once (neither fires, both checks
succeed, no error). The original comment claiming `-p` "is idempotent — no
failed_when override needed, unlike a plain mkdir" was wrong on both
counts and has been removed.

**Not yet confirmed by a real run** — same status as #123, reported in the
same batch of output from James's first live pass through
`dataguard_convert_rac`. Next run should confirm both `asmcmd ls` checks
correctly detect the pre-existing parent directory and only create
`PASSWORD`.

## 125. Second real run of `dataguard_convert_rac`: "already registered with CRS" isn't the same thing as "already running" — the role skipped instance startup and its own verification query correctly reported `ORA-01034`

James's #123/#124 fixes went into a real run. `srvctl config database`
showed `apexdb_stby` already registered with both `apexdb1` and `apexdb2`
listed, so `dg_convert_rac_already_done` was `true` and the role skipped
straight to the final verification query — 46 tasks reported `skipping`,
including every task from CRS registration through both `srvctl start
instance` calls. The verification query then failed:

```
SQL> select instance_name, host_name, status, database_role from gv$instance ...
ERROR at line 1:
ORA-01034: ORACLE not available
```

"Connected to an idle instance" a few lines above confirms it: neither
`apexdb1` nor `apexdb2` had an SGA up. Play recap showed `failed=0` — no
loud failure, just a verification query correctly reporting that nothing
was actually running.

**Root cause.** `dg_convert_rac_already_done` is set from `srvctl config
database` succeeding and listing both instance names — that only proves
apexdb_stby is *registered* with CRS, not that either instance is
currently *started*. Every task under `when: not
dg_convert_rac_already_done` was gated on registration state, including
the two `srvctl start instance` tasks and the MRP restart between them —
so a re-run where the instances happen to be down for any reason (and they
will be: this role deliberately registers apexdb_stby with `-policy
MANUAL`, precisely so CRS does *not* auto-start it after a reboot or CRS
bounce — see #119) skips startup entirely and walks straight into a
verification query with nothing to verify.

**The fix.** Added an unconditional `srvctl status database -db
{{ dg_standby_db_unique_name }}` check right before the startup section,
independent of `dg_convert_rac_already_done`, parsed into
`dg_convert_rac_inst1_running`/`dg_convert_rac_inst2_running` via a direct
substring match on `"Instance <SID> is running"`. (This is not the
echoed-transcript collision bug from #121 — `srvctl status` isn't SQL\*Plus
and doesn't echo the command it was given, so a substring match here is
safe as long as it's anchored to the specific instance name, which it is.)
The four downstream tasks — start `apexdb1`, write the MRP-restart script,
run it, start `apexdb2` — now gate on `not dg_convert_rac_inst1_running` /
`not dg_convert_rac_inst2_running` instead of `not
dg_convert_rac_already_done`. This check runs with no `when:` guard at all
deliberately: by the time execution reaches it, apexdb_stby is registered
with CRS on every possible path through the role (either just now, on a
first-time run, or already, on a repeat run), so `srvctl status database`
always has a real, meaningful answer.

**Net effect on idempotency, stated explicitly:** a full first-time run
behaves exactly as before (both instances report not-running, both start).
A true no-op re-run (registered *and* both instances already up) still
skips startup, matching the old behavior. The new case this fixes is
registered-but-down: previously silently skipped and misreported as a
successful no-op via a passing-looking `ok=9 failed=0` recap; now correctly
detected and started.

**James's follow-up, same finding pushed one step further:** he asked why
this didn't pause for manual review the way section 8 already does before
starting anything, and pointed out the role itself had shut apexdb1 down
during the first run (section 3's "Shut down apexdb1" task) — so the
second run had every reason to already know it was down, not just
stumble into `ORA-01034` at the verification step. Both points were right,
and pointed at the same root cause as the paragraph above: section 8's
"Check the CRS configuration" / "Show the CRS configuration" / "Pause for
review... before starting either instance" tasks were *also* gated on
`not dg_convert_rac_already_done`, so on the registered-but-down re-run
they were silently skipped too (visible in the recap as three more
`skipping: [localhost]` lines) — the operator got no review checkpoint at
all before this role went on to restart production-adjacent instances.

**Second half of the fix.** Moved the `srvctl status database` check (and
its `dg_convert_rac_inst1_running`/`_inst2_running` facts) earlier, to run
unconditionally right before section 8, and added
`dg_convert_rac_needs_start` (`true` if either instance is down). Section
8's three tasks — config check, show, pause — are now gated on
`dg_convert_rac_needs_start` instead of `not dg_convert_rac_already_done`,
so the review-and-pause fires on every run where anything is about to be
started, first-time or recovery alike. The pause prompt itself now also
reports live `{{ sid_prefix }}1/2 running` state, and — specifically when
`dg_convert_rac_already_done` is true — adds an explicit note that this is
a registered-but-down recovery path, not first-time setup, and that the
operator should confirm they know why the instance is down (a failed prior
run after shutdown, a reboot with `-policy MANUAL` not auto-starting it, or
an actual crash) before pressing on.

**Not yet confirmed by a real run.**

## 126. Manual `srvctl config database` check after the #124/#125 fixes found two more real bugs, and both trace back to the same root cause: CRS registration succeeding isn't the same thing as this role being finished

James checked `apexdb_stby`'s CRS configuration by hand, directly on
`oradbserv09`, rather than through another Ansible run:

```
$ srvctl config database -d apexdb_stby
...
Spfile: /u01/app/oracle/product/12.2.0/db_1/dbs/spfileapexdb1.ora
Password file:
...
```

Two things are wrong. `Spfile:` is a local filesystem path, not the ASM
path James's own original spec called for
(`+DATA01/apexdb_stby/PARAMETERFILE/spfileapexdb.ora`, from the very first
`srvctl add database` command he provided — see #119). `Password file:` is
blank — the ASM password file migration this role is supposed to perform
apparently never registered anything with CRS at all. James also asked a
sharper question underneath both: "When did it register it? I didn't
confirm it" — pointing out that CRS registration had clearly already
happened, without any pause asking him to review it first.

**Root cause, tying all three observations together.** This role's only
top-level idempotency gate, `dg_convert_rac_already_done`, checks one thing
only: does `srvctl config database` show apexdb_stby registered with both
instance names. That condition can become permanently true after section
5's three registration tasks (`add database`/`add instance` x2) succeed,
*even though* sections 6 (ASM password file + spfile migration) and 7
(apexdb2 node prep) haven't run yet — exactly what happened on James's own
first real run, which died in section 6 on the `asmcmd mkdir -p` bug
(#124), *after* registration but *before* the password file was copied
into ASM or registered, and before any spfile-into-ASM step existed at
all. Once registered, every later re-run's `not dg_convert_rac_already_done`
gate skipped sections 1 through 8 entirely — including the now-fixed #124
mkdir logic and the `srvctl modify database -pwfile` call — permanently,
on every future run, regardless of whether that work had actually finished.
This is the same class of gap as #125 (registration state and running
state are independent), just reaching one step further: registration state
and *migration-into-ASM* state are independent too.

The original `srvctl add database` command also had a real design bug of
its own, independent of the gating issue: its `-spfile` argument used
`dg_convert_rac_spfile_path`, the *discovered current* spfile path from
section 2 — wherever RMAN `DUPLICATE` happened to leave it (a local file
under `$ORACLE_HOME/dbs`). James's original spec never asked for that path
to be discovered and registered as-is; it asked for the spfile to be
*migrated into ASM* first, the same way the password file already was, and
*that* ASM path registered. The role only ever built the password-file half
of that pattern.

**The fix, in three parts.**

*Independent completion facts, not one coarse flag.* Right after
`dg_convert_rac_already_done` is set, two more facts are parsed from the
same `srvctl config database` output already captured at the top of the
role: `dg_convert_rac_spfile_asm` (true if the registered `Spfile:` value
starts with `+`) and `dg_convert_rac_pwfile_registered` (true if
`Password file:` is non-blank). A third, `dg_convert_rac_spfile_copy_source`,
resolves to whatever spfile path is *currently* registered (even a wrong
local one — it's still a real, readable file) or, if nothing's registered
yet, Oracle's own predictable default local-spfile naming
(`$ORACLE_HOME/dbs/spfile<SID>1.ora`) — so the ASM copy step has a correct
source on every path, first-time or remediation.

*Section 6 now does both migrations, each independently gated.* Split into
6a (password file, gated on `not dg_convert_rac_pwfile_registered`,
functionally unchanged from before) and 6b (spfile, new): create
`+DATA01/apexdb_stby/PARAMETERFILE` (same check-then-act `asmcmd mkdir`
idiom as #124, since `asmcmd` still has no `-p`), copy the current spfile
into it as `spfileapexdb.ora` via `asmcmd cp` (not `CREATE SPFILE`, which
only supports `FROM PFILE`/`FROM MEMORY` — there's no direct
spfile-to-spfile clause), then `srvctl modify database -spfile <ASM path>`.
The parent `+DATA01/apexdb_stby` directory check is shared and gated on
`(not dg_convert_rac_pwfile_registered) or (not dg_convert_rac_spfile_asm)`
— needed if either migration is still pending. `-spfile` was removed from
the original `srvctl add database` task entirely — it's now set exclusively
via this dedicated `modify database` call, deliberately mirroring how
`-pwfile` was already handled, which has a real second benefit: because
it's gated on `not dg_convert_rac_spfile_asm` rather than
`not dg_convert_rac_already_done`, it *self-heals* a previously-wrong
registration (James's actual observed bug) on the next run, not just
first-time registrations.

*Section 7 (apexdb2 node prep) dropped its `dg_convert_rac_already_done`
gate entirely.* It sits after section 6 in file order, so it was exactly as
exposed to "registration succeeded, this didn't" as section 6 was — every
task in it already carries its own real idempotency condition (a `stat`
check, a checksum comparison, or `lineinfile`'s inherent idempotency), so
the coarse outer gate was pure liability there with no benefit.

*The remaining pause's wording was made explicit about what it authorizes.*
James's "I didn't confirm it" question wasn't really about a missing gate —
there genuinely is only one pause before this role commits (section 2's,
before `cluster_database=true` and shutdown) — it was that the pause's own
prompt didn't say registration was included in what pressing Enter there
authorized. Reworded to spell out the full unattended sequence that follows
that single pause: set parameters, shut down, register with CRS, migrate
password file and spfile into ASM — all the way through to section 8's
separate pause before either instance actually starts.

**Not yet confirmed by a real run.**

## 127. #126's fixes still left one silent path — James flagged it before running anything again: "fully done" produced zero output and zero pause

Before running the #126 fixes for real, James pushed back on the design
directly: this role must never proceed without showing what it found and
pausing for review — not just in the states already covered. Checking the
actual gating logic confirmed a real remaining gap, not a hypothetical one:
the `srvctl config database` display, the running-state display, and the
pause in section 8 were all gated on `dg_convert_rac_needs_start`. That
correctly fixed the two states #125/#126 found, but there was a third
state neither of those runs had exercised yet: **registered AND both
instances already running** — the state this role reaches after a fully
successful run (or once #125's own auto-start fix brings a down instance
back up). In that state, `dg_convert_rac_needs_start` is `false`, so
section 8's config display and pause were both skipped, and the only
other message on that path was a single generic one-liner ("conversion
already done, skipping to verification") with no configuration and no
running state shown at all — the exact "no pauses, no information" gap
James called out, and one he'd flagged as a risk before it ever produced a
real run's output.

**The fix.** Moved instance-running-state detection (`srvctl status
database`) to the very top of the role, before section 1, unconditional —
nothing before section 9 changes whether an instance is running, so the
facts stay valid for the entire run. Immediately after it, four
unconditional tasks now run on *every* invocation, regardless of state:
the raw `srvctl config database` output (or, if `rc != 0`, an explicit
"not registered yet" message — not registered is itself real information,
not silence); current running state for both instances plus ASM
migration state (password file, spfile); a state-specific summary
explaining in plain language what this run will and won't do — for the
first-time case, everything; for registered-but-down, an explicit list of
which checks are being skipped (MRP stop/check, undo tablespace/spfile
discovery, cluster_database parameter changes, shutdown, CRS registration)
and which ASM/start work will still run; for fully-done, an explicit "no
changes will be made" statement; and finally a pause, unconditional,
requiring Enter (or Ctrl+C then A to abort) before section 1 even begins.
Section 8's own config-check/pause remains as a second, later checkpoint
(still gated on `dg_convert_rac_needs_start`, since it's showing the
*post*-registration/ASM-migration config right before instances actually
start) — it's now a second look at fresher state, not the only look.

**Net effect:** every run of this role now shows real configuration and
real running state and pauses for acknowledgment before doing anything, in
all three states — first-time, registered-but-down, and fully-done —
where before only two of the three ever produced visible output. Not yet
confirmed by a real run.

## 128. Real run hit `ORA-32001: write to SPFILE requested but no SPFILE is in use` on every single `scope=spfile` statement — apexdb1 was still running on a plain pfile

James ran `--tags dataguard_convert_rac` for real after #127's fixes and
got past the new acknowledgment pause cleanly, but section 3 ("Set
cluster_database=true and per-instance parameters") failed outright — all
seven `alter system ... scope=spfile` statements hit the identical error:

```
SQL> alter system set cluster_database=true scope=spfile sid='*';
ERROR at line 1:
ORA-32001: write to SPFILE requested but no SPFILE is in use
```

**Root cause.** `scope=spfile` requires an spfile to already be *in use* by
the running instance — not merely present somewhere on disk. Phase 3
(`dataguard_standby_prep`) started apexdb1 with `startup nomount
pfile='{{ staging_dir }}/standby/initapexdb.ora'`, a plain text pfile, and
neither Phase 3 nor Phase 4's RMAN `DUPLICATE` ever switched the running
instance onto an spfile afterward. `v$parameter('spfile')` was genuinely
blank — this wasn't a formatting or parsing bug like #123, the value
really was empty. James's own framing: "big limitation. If spfile is not
in use then create it and use that spfile."

**The fix.** New section 1b, between MRP-cancel and the undo/spfile
discovery: query `v$parameter('spfile')` (same left-anchored
`^[/+]`-match idiom as the rest of this role, since a NULL value prints as
a blank row rather than being absent from the output — matching a real
path distinguishes "in use" from "blank" or the echoed `SQL>` text). If
blank: `CREATE SPFILE='{{ db_home }}/dbs/spfile{{ sid_prefix }}1.ora' FROM
PFILE='{{ staging_dir }}/standby/initapexdb.ora'` (explicit source and
destination — the source is the exact pfile Phase 3 used, not a guessed
default location, since this project's staging-directory convention means
the OS-default pfile location may not even exist). Creating the file alone
doesn't make the *running* instance use it — `v$parameter('spfile')` is
only set at STARTUP time — so this is followed by `SHUTDOWN IMMEDIATE` /
`STARTUP MOUNT` (MRP was already confirmed stopped by section 1, so this
restart is clean; MOUNT not OPEN, apexdb1 is a physical standby). A plain
`STARTUP` with no explicit clause auto-discovers `spfile<SID>.ora` in
`$ORACLE_HOME/dbs` ahead of a plain pfile — Oracle's own documented default
search order — so no explicit `SPFILE=`/`PFILE=` clause is needed on the
restart; placing the new file at exactly that default path is what makes
the auto-discovery work. Finally, re-verifies `v$parameter('spfile')` is
now non-blank and fails loudly with an explicit message if it somehow
isn't, rather than let section 3 hit the identical `ORA-32001` a second
time with a much less obvious error trail.

Gated the same as sections 1-2 (`not dg_convert_rac_already_done`) — this
is one-time pre-registration setup, never re-run once registered. The
top-of-role state summary (#127) and the discovery pause (section 2) were
both updated to mention this step explicitly, so it's visible rather than
an invisible extra step wedged in between two already-documented ones.

**Not yet confirmed by a real run** — this exact fix hasn't been exercised
yet; the error above is what prompted it.

## 129. HIGH SEVERITY, LIVE INCIDENT — CRS went unreachable on oradbserv09 mid-run; the role shut down apexdb1 and attempted CRS registration anyway, leaving the standby down and CRS broken at the same time

James re-ran `--tags dataguard_convert_rac` after #128's spfile fix. It got
past the new spfile-creation logic, the discovery pause, and
`cluster_database`/per-instance parameter setting (all `System altered.`)
cleanly. Then:

- "Shut down apexdb1" ran and succeeded (`ORACLE instance shut down`).
- "Register apexdb_stby with CRS as a PHYSICAL_STANDBY database"
  (`srvctl add database`) failed:
  ```
  PRCR-1035 : Failed to look up CRS resource Generic for Generic
  PRCR-1070 : Failed to check if server pool Generic is registered
  CRS-0184 : Cannot communicate with the CRS daemon.
  ```

James checked directly on oradbserv09 and confirmed crsd was genuinely
unreachable there:

```
$ crsctl check crs
CRS-4638: Oracle High Availability Services is online
CRS-4535: Cannot communicate with Cluster Ready Services
CRS-4529: Cluster Synchronization Services is online
CRS-4533: Event Manager is online
```

OHASD, CSSD, and EVMD are up; **crsd specifically is not** — a classic
"crsd crashed or was evicted" signature, not a general host/network
failure. From oradbserv10's view (`crsctl stat res -t`), the cluster
agrees: every resource with a per-node instance
(`ora.ASMNET1LSNR_ASM.lsnr`, `ora.DATA01.dg`, `ora.RECO01.dg`, `ora.asm`,
`ora.asmnet1.asmnetwork`) shows node 1's copy OFFLINE and only node 2's
ONLINE, and `ora.oradbserv09.vip` shows `FAILED OVER,STABLE` on
oradbserv10 — oradbserv09 has effectively been evicted from the cluster's
perspective, even though the host and OHASD are still up and ASM's own
PMON process (`asm_pmon_+ASM1`) is still running standalone, orphaned from
crsd. `srvctl config all` from oradbserv10 shows `ora.apexdb_stby.db` DID
get created in the cluster's shared config (OCR, in `+DATA01`) despite the
local command reporting failure — so the resource now exists in a
half-registered state: `SPFILE` shows the correct local path, but
`Password file: unknown` and a `PRCD-1254: Password file attribute does
not exist for database apexdb_stby` error.

**Root cause of why the role let this happen.** The very first task this
role runs — `srvctl config database -db apexdb_stby`, to determine whether
this is a first-time or repeat conversion — almost certainly *already*
returned a `CRS-0184`-flavored error at the very start of this run too
(crsd was probably already unreachable on oradbserv09 before the role even
began, or became unreachable very early), but the role's error handling
only ever asked one question of that result: did it return the two SID
substrings, yes or no. Any failure — "genuinely not registered yet"
(`PRCD-1120`/`PRCR-1001`, a completely benign, expected condition seen
earlier this project when checking a real not-yet-registered database by
hand) and "crsd itself is unreachable" (`CRS-0184`, a serious
infrastructure problem) — got treated identically: "not registered,
proceed as first-time conversion." The role then went on to shut down
apexdb1 (an action only safe to take if CRS is healthy enough to bring it
back under CRS management afterward) and only discovered CRS was broken
when the *next* CRS-dependent command failed too. This is a real, work
"gap" this project had already correctly generalized `select('match', ...)`
scrutiny (known-risks.md #121/#122) toward SQL echo-text collisions, but
had not yet applied to **plain command failures with meaningfully different
causes** — not every non-zero `rc` from an `srvctl`/`crsctl` command means
the same thing, and this role's logic wasn't distinguishing between them
before taking an irreversible-in-practice action.

**Whether this run *caused* crsd to become unreachable, or merely exposed
a pre-existing problem, is not yet established** — nothing in sections 1-3
(SQL*Plus operations against the database instance only) touches
Clusterware directly, so it's more likely CRS was already unhealthy on
oradbserv09 (from resource pressure in the lab, or a leftover effect of
this project's own recent Clusterware work) and this run simply reached
the first task that actually needed crsd to be reachable. This distinction
matters for root-causing the underlying CRS issue, but doesn't change what
the role should have done differently: check first, don't find out by
failing partway through a destructive sequence.

**The fix.** New unconditional preflight, before every other task in this
role including the "already registered?" check itself: `crsctl check crs`
on both `dg_convert_rac_node1` and `dg_convert_rac_node2`, looped, and an
explicit `fail:` — not a pause, a hard stop — if `CRS-4537` (Cluster Ready
Services is online) doesn't appear in either node's output. The failure
message names the specific unhealthy node, points at the real crsd/ohasd
log paths, and explains why this role won't proceed until CRS is
confirmed healthy on both nodes.

**Immediate remediation needed on oradbserv09 — separate from the code
fix, and not yet resolved:**
1. Check `$GRID_HOME/log/oradbserv09/crsd/crsd.log` (and `crsdOUT.log`)
   for the actual reason crsd stopped/became unreachable — this is the
   single most useful diagnostic and hasn't been reviewed yet.
2. Check `$GRID_HOME/log/oradbserv09/ohasd/ohasd.log` too, since ohasd is
   what's supposed to keep crsd running.
3. From oradbserv09's own `+ASM1` instance, confirm whether `DATA01`/
   `RECO01` are actually mounted locally (`asmcmd lsdg`) — node 2's view
   shows both diskgroups' node-1 copies OFFLINE, which would explain crsd
   being unable to read/write OCR (stored in `+DATA01`) and might be
   upstream cause rather than downstream symptom.
4. `crsctl stat res -t -init` on oradbserv09 queries OHASD-managed
   resources directly (bypassing crsd) and will show whether `ora.crsd`
   itself is even attempting to start.
5. Once the root cause from logs is understood, a clean `crsctl stop crs
   -f` / `crsctl start crs` (as root) is the standard recovery path for a
   stuck crsd — deliberately not recommended blind, before the log review
   above, since a forced restart without understanding the cause risks
   masking or compounding whatever actually happened.

**Current real state, as of this entry: apexdb1 is shut down, CRS is
broken on oradbserv09, and `apexdb_stby` is a half-registered CRS resource
missing its password file attribute.** This needs to be resolved on the
infrastructure side before any further `dataguard_convert_rac` run —
re-running now would immediately hit the new preflight fail, correctly,
until oradbserv09's CRS is confirmed healthy again.

**Update: resolved.** James rebooted oradbserv09 and confirmed `+ASM1` came
back healthy. CRS itself recovered from the reboot — the new preflight
guard from this entry was not what caught anything here since CRS was
healthy again by the time he re-ran, but the underlying infrastructure
problem is cleared.

## 130. Immediately after #129's recovery, `asmcmd mkdir`'s check-then-act guard turned out to be unreliable — the check reported "missing" for directories that demonstrably already existed, letting `mkdir` run anyway and fail fatally

With CRS healthy again, James re-ran `--tags dataguard_convert_rac`.
Registration had already happened on a prior (interrupted) attempt, so the
role correctly skipped straight to section 6 (ASM migration) — but failed
there:

```
TASK [... Create the ASM PARAMETERFILE subdirectory for apexdb_stby if it doesn't already exist]
fatal: ...
  cmd: asmcmd mkdir +DATA01/apexdb_stby/PARAMETERFILE
  rc: 255
  stderr: |-
    ORA-15032: not all alterations performed
    ORA-15005: name "+DATA01/apexdb_stby/PARAMETERFILE" is already used by an existing alias (DBD ERROR: OCIStmtExecute)
```

`ORA-15005` means exactly what it says: the directory already existed.
James manually removed it (`asmcmd rm -rf PARAMETERFILE/`) and re-ran to
see what would happen — and hit the *identical* failure one level up, on
the PARENT directory this time:

```
TASK [... Create the apexdb_stby ASM directory if it doesn't already exist]
fatal: ...
  cmd: asmcmd mkdir +DATA01/apexdb_stby
  stderr: |-
    ...
    ORA-15005: name "+DATA01/apexdb_stby" is already used by an existing alias (DBD ERROR: OCIStmtExecute)
```

`+DATA01/apexdb_stby` demonstrably already existed — it's held
DATAFILE/CONTROLFILE/ONLINELOG since Phase 4's RMAN `DUPLICATE`, plus the
already-registered PASSWORD subdirectory. James's own framing, plain and
correct: "Ansible should be able to continue even if the directory is
present. It should not fail." He also flagged the downstream consequence:
because the mkdir task failed *fatally*, the play stopped right there —
the `asmcmd cp`/`srvctl modify database -spfile` tasks after it never got
a chance to run, so the spfile was still not in ASM despite #128's fix
being otherwise correct.

**Root cause.** The `asmcmd ls`-based "check whether the directory already
exists" guard added in #124/#126 turned out not to be a reliable way to
detect ASM directory existence in practice — it reported `rc != 0`
("missing") for directories that were demonstrably present, on two
separate real runs, at two different directory levels. Whatever the exact
ASMCMD quirk (a version-specific `ls` behavior on a directory alias
containing only subdirectory entries and no plain files is a plausible
candidate, given the accompanying Perl warning in the second failure —
`Use of uninitialized value in concatenation ... asmcmdshare.pm line
5233` — pointing at ASMCMD's own internal handling, not anything this role
controls), the practical lesson is the same one already stated plainly in
#122's "broader lesson": a check that "looks right" isn't the same as one
that's been verified against real output, and this one wasn't reliable
under real conditions twice in a row.

**The fix.** Stopped checking first entirely. Each of the three ASM
`mkdir` tasks (`+DATA01/apexdb_stby`, its `PASSWORD` subdirectory, its new
`PARAMETERFILE` subdirectory) now just attempts the `mkdir` directly, with
`failed_when: rc != 0 and 'ORA-15005' not in stderr` — an existing
directory is treated as success, not a failure, matching Unix `mkdir -p`
semantics without needing ASMCMD to actually support `-p` (#124) or
needing a separate, apparently-unreliable existence check first. This is
simpler than what it replaces (three `ls`-check tasks removed entirely,
not just three `mkdir` tasks fixed) and matches James's own stated
requirement directly.

**Not yet confirmed by a real run** — this specific fix hasn't been
exercised; the two failures above are what prompted it. Once it runs
clean, the `asmcmd cp` and `srvctl modify database -spfile` tasks
immediately after should finally get a chance to execute and put the
spfile in ASM for the first time.

**One more thing James noticed while investigating, not itself a bug:**
the ASM alias for the password file resolves to an internally-generated
path with a generic name — `pwdapexdb_stby =>
+DATA01/DB_UNKNOWN/PASSWORD/pwddb_unknown.266.1241392981`. This is
expected, not a problem: `asmcmd pwcopy`/`cp` are plain file-copy
operations and don't tag the underlying system-generated ASM file with a
database name the way `pwcreate --dbuniquename` would (#108/#112) — only
the alias path (`+DATA01/apexdb_stby/PASSWORD/pwdapexdb_stby`, which is
what `srvctl config database` and CRS actually reference) needs to be
correct, and it is. Worth stating explicitly so it isn't mistaken for
something broken on a future review.

## 131. James's question — "What happens if the password file is already there?" — exposed a real fragility: the primary-ASM round-trip ran unconditionally, and a real run's `asmcmd pwget` returned an empty path with no check catching it

Real run, next task after #130's mkdir fix: apexdb2's local password file
provisioning (the `copy_from_primary` chain, which copies apexdb1's real
password file out of the PRIMARY's own ASM to compare against/replace
whatever's on oradbserv10) failed:

```
TASK [... Export the primary's real password file from ASM to a local staging file (asmcmd pwcopy)]
fatal: ...
  cmd: [asmcmd, pwcopy, /u01/app/oracle/staging/standby/orapwdapexdb]
  stderr: |-
    usage: pwcopy [ --dbuniquename <string> | --asm ][-f][--local]
            <source_path> <destination_path>
```

Only ONE path argument reached `pwcopy` — the SOURCE argument was missing
entirely. The immediately preceding task, `asmcmd pwget --dbuniquename
apexdb` (registered as `dg_convert_rac_pwfile_asm_path`), had succeeded
(`rc=0`, no failure) but returned **empty stdout** — the templated command
`asmcmd pwcopy {{ ...stdout | trim }} {{ dest }}` collapsed the blank
source into nothing, and `pwcopy` correctly rejected the malformed
one-argument invocation, just with a confusing generic usage message
instead of a clear "no source path" error.

James's question, asked directly rather than just reporting the failure:
"What happens if the password file is already there?" — pointing at the
real design gap underneath the immediate bug: this entire
discover/remove-stale/ensure-dir/export/fetch/compare round-trip through
the PRIMARY's own ASM ran **unconditionally on every single pass**,
regardless of whether apexdb2 already had a usable local password file —
purely so the final copy step could checksum-compare and decide whether to
overwrite. That's expensive (round-trips through ASM on a completely
different host) and, as this run showed, a second real point of fragility
layered on top of a step (`asmcmd pwget`) that isn't essential once a
local copy already exists.

**The fix, two parts.**

*Short-circuit the whole chain if a local copy already exists.* Added
`and not dg_convert_rac_pwfile_stat.stat.exists` to the `when:` of all
seven `copy_from_primary` tasks (discover, remove-stale, ensure-dir,
export, fetch, copy, both cleanups) — `dg_convert_rac_pwfile_stat` was
already computed earlier in this section (a plain `stat` on
`orapw{{ sid_prefix }}2` on oradbserv10) but was previously only consulted
by the final copy step's checksum-diff logic, not used to gate whether the
whole expensive/fragile round-trip was attempted at all. This directly
answers James's question: with this fix, if apexdb2 already has a local
password file, none of this chain runs — existence is treated as
sufficient, the same idempotency philosophy already used for the ASM
password/spfile migration in section 6a/6b (registered/present is enough,
not re-verified byte-for-byte every run). This is a reasonable trade
specifically because this local per-node file was always documented as a
fallback/convenience copy — the file CRS/srvctl actually uses to start
apexdb2 is the ASM-registered one from section 6a, not this one. The final
copy task's checksum-diff condition became unreachable-when-not-needed and
was simplified accordingly (nothing to compare against, by construction,
whenever this chain actually runs).

*Fail loudly if `pwget` genuinely returns nothing.* Even with the
short-circuit, the chain can still run on a real first-time need (apexdb2
has no local file yet), and `asmcmd pwget` returning empty is still a
real, if rare, possible outcome — root cause not yet established (worth
checking by hand: `asmcmd pwget --dbuniquename apexdb` on oradbserv05,
outside Ansible, if this recurs). Added an explicit `fail:` immediately
after the discover task, checking for empty/whitespace-only stdout, with a
clear message pointing at the exact command to re-check by hand — same
"verify, don't assume a command's success implies a *useful* result"
lesson already applied repeatedly in this project (#121, #122, #125,
#126), now extended to plain command output, not just SQL\*Plus parsing.

**Not yet confirmed by a real run.**

**Superseded by #132, immediately after, before any run happened:** the
`fail:` behavior described above was replaced with an automatic fallback
to `orapwd` — see #132 for the reasoning and the final design. Left this
section intact rather than rewritten, since the short-circuit-on-existing
fix above is still exactly what shipped; only the "then fail" tail changed
to "then fall back."

## 132. James's question — "What happens if the password file is already there?" plus his own dbuniquename check — led to a graceful-fallback redesign, applied to all three roles that share this exact pattern, not just the one that failed

Following up on #131, James manually confirmed which `dbuniquename` actually
resolves where, testing directly on oradbserv09 (standby):

```
$ asmcmd pwget --dbuniquename apexdb
(nothing)
$ asmcmd pwget --dbuniquename apexdb_stby
+DATA01/apexdb_stby/PASSWORD/pwdapexdb_stby
```

Worth stating plainly since it's easy to misread: this does **not** mean
`dataguard_convert_rac`'s failing task delegated to the wrong host. The
actual failure transcript from #131 showed `fatal: [localhost ->
oradbserv05(192.168.56.181)]` — the task correctly ran on oradbserv05 (the
PRIMARY, `groups['rac_node1'][0]`), querying `--dbuniquename apexdb` (the
PRIMARY's own name, `db_unique_name` from `group_vars/all.yml`), which
#116 previously confirmed works there. James's test instead confirms the
general, useful fact that `apexdb` (the primary's name) is naturally not
found by querying the STANDBY cluster's own separate ASM (usatclust1 and
usatclust2 are independent clusters with independent ASM diskgroups, not
shared storage) — a genuinely different ASM instance from the one this
task actually queries. Root cause of #131's specific empty result is still
not established; this is a clarification of what *isn't* the cause, not a
fix for what is.

James's actual instruction, plain and direct: "go through all the scripts
for future builds and check in advance. My take is if the password check
didn't return a value it should then create a password file because one
does not exist." Two concrete asks: (1) audit every role with this same
pattern, not just the one that happened to fail first; (2) change the
response to an empty `pwget` result from a hard failure (#131's own fix,
just added) to an automatic fallback.

**Audit result: the identical `copy_from_primary` password-file pattern
exists in three roles** — `dataguard_standby_prep` (apexdb1, Phase 3),
`dataguard_duplicate` (apexdb1, Phase 4 — a deliberate duplicate of
`dataguard_standby_prep`'s own logic, so a `--tags dataguard_duplicate`-only
run is self-sufficient), and `dataguard_convert_rac` (apexdb2, Phase 6).
All three had the exact same two gaps: the whole discover/export/fetch
round-trip through the primary's ASM ran unconditionally, regardless of
whether the target node already had a usable local password file, and
none of them checked for `pwget` returning empty before using its result.
Only `dataguard_convert_rac`'s copy (apexdb2) had actually been exercised
against a real failure so far — `dataguard_standby_prep` and
`dataguard_duplicate`'s copies (apexdb1) hadn't hit it live yet, but carry
identical code and would hit the identical bugs.

**The fix, applied identically to all three roles.** Both changes from
#131 (short-circuit if a local file already exists) plus the new
fallback-on-empty behavior:

1. Every task in the `copy_from_primary` chain (discover, remove-stale,
   ensure-dir, export, fetch, copy, both cleanups) is gated on the target
   node's local password file NOT already existing — unchanged from #131,
   now applied to all three roles instead of just one.
2. New: right after the `pwget` discovery task, a fact
   (`dg_*_pwfile_asm_empty`, named per-role) checks whether the returned
   path is blank. If so, a `debug` reports the fallback is happening (not
   silent — this project's now-consistent "never proceed without saying
   so" theme) and the rest of the `copy_from_primary` chain is skipped via
   `and not dg_*_pwfile_asm_empty` on each remaining task.
3. The `orapwd` fallback task's `when:` changed from `dg_pwfile_method ==
   'orapwd'` to `dg_pwfile_method == 'orapwd' or dg_*_pwfile_asm_empty` —
   it now fires either because the operator explicitly chose that method,
   or because `copy_from_primary` was selected but came back empty. This
   is James's fallback, implemented directly: an empty password-file
   lookup no longer fails the role, it creates one.

**Trade-off, stated explicitly:** a fallback-generated `orapwd` password
file won't carry the primary's exact SYS password hash or any other
privileged-user grants beyond what `orapwd` itself creates — only matters
if something downstream specifically relies on that (nothing in this
project currently does; the ASM-registered, CRS-managed password file from
`dataguard_convert_rac` section 6a is the authoritative one both instances
actually use to start). The fallback debug message says this explicitly
each time it fires, so it's visible rather than a quiet behavior change.

**Not yet confirmed by a real run** in `dataguard_standby_prep` or
`dataguard_duplicate` — only `dataguard_convert_rac`'s version has real
run history behind the bugs this fixes.

## 133. First clean end-to-end `dataguard_convert_rac` run — one cosmetic bug left in the final verification query (`ORA-00904` on `database_role`)

James ran `dataguard_convert_rac` again after the `ORA-01078` investigation
in #132's aftermath (see the diagnostic session referenced there — both
nodes' `crsd_oraagent_oracle.trc` showed only the bare, unchained
`ORA-01078: failure in processing system parameters`, and `CREATE PFILE
FROM SPFILE` against the ASM-resident spfile succeeded cleanly on both
nodes, ruling out spfile corruption or an ASM access problem). No code
change was made in this project in response to that error — it did not
recur on this run. `apexdb1` and `apexdb2` both started via `srvctl` in
`MOUNT` without incident, and managed recovery restarted successfully
(`MRP0` showing `APPLYING_LOG`). Root cause of the one-off `ORA-01078` is
therefore still not established; if it recurs, re-run the same manual
`STARTUP MOUNT` bypass (bypassing `srvctl`/CRS to get Oracle's full,
unchained error stack, which the CRS agent trace doesn't capture) before
assuming it's the same issue.

The one real bug this run surfaced: the final verification query in
section 10 failed with

```
ORA-00904: "DATABASE_ROLE": invalid identifier
```

`database_role` is a `v$database` column, not a `gv$instance` column — the
original query (`select instance_name, host_name, status, database_role
from gv$instance ...`) was simply wrong, mixing columns from two different
views into one `SELECT` against only one of them. Fixed by cross-joining
`gv$instance` to `v$database` and selecting each column from the view that
actually has it:

```sql
SELECT
    i.instance_number,
    d.dbid,
    d.name,
    d.log_mode,
    d.open_mode,
    i.instance_name,
    i.host_name,
    i.version,
    i.status,
    TO_CHAR(i.startup_time, 'YYYY-MM-DD HH24:MI:SS') AS startup_time
FROM   gv$instance i CROSS JOIN v$database d
ORDER BY i.instance_number;
```

`v$database` is instance-independent (one row, not per-instance), so the
`CROSS JOIN` against `gv$instance` correctly repeats `dbid`/`name`/
`log_mode`/`open_mode` alongside each instance's own row rather than
needing a `database_role` column that was never on `gv$instance` in the
first place. This is purely cosmetic — the second query in the same
script (`gv$managed_standby`, showing `MRP0 APPLYING_LOG`) already proved
the conversion itself worked; this only fixed the summary display.

**With this fix, Section 12 (`dataguard_convert_rac`) is confirmed clean
end-to-end** — see `high-availability/README.md` Section 12, updated to
🟩.

## 134. James's live failover test exposed a real gap: `apexdb_stby`'s TNS aliases were still pinned to a single node hostname after Phase 6 made it a real RAC standby — `dataguard_net_config` now decides SCAN vs hostname at run time instead of hardcoding either

James tested the whole point of Phase 6 directly: shut down `oradbserv09`
(one of `apexdb_stby`'s two RAC nodes) to confirm redo would still ship to
and apply on `oradbserv10`, the surviving node. It didn't — the primary's
alert log showed:

```
Error 1034 received logging on to the standby
ARCH: Attempting destination LOG_ARCHIVE_DEST_2 network reconnect (1034)
ARCH: Destination LOG_ARCHIVE_DEST_2 network reconnect abandoned
```

**Root cause.** `dataguard_net_config` (Phase 2) built `apexdb_stby`'s
`tnsnames.ora` entry pointing at `dg_standby_node1_fqdn`
(`oradbserv09.usat.com`) — correct **at the time Phase 2 runs**, since
`apexdb_stby` isn't CRS-registered yet and SCAN dynamic registration
genuinely doesn't work for it (`known-risks.md` #115). But that value was
never revisited once Phase 6 (`dataguard_convert_rac`) actually completed
and made `apexdb_stby` a real, CRS-registered, dynamically-PMON-registered
2-node RAC database — #115's own closing note flagged this exact follow-up
("switch back to SCAN once Phase 5 has actually run") and it never
happened. With `log_archive_dest_2`/this TNS alias still pointing at one
specific node, killing that node doesn't fail over to the other one — it
just breaks redo transport outright, which is precisely the opposite of
what converting the standby to RAC was supposed to buy.

James also did a manual, hands-on test of the fix: edited `tnsnames.ora` by
hand to point `apexdb_stby`/`apexdb_stby_dg` at `scan-usatclust2.usat.com`
instead, confirmed it, and asked for the final merged file to carry exactly
one clean entry per alias (no leftover duplicate block from his manual
edit) on every node.

**The fix — made the target dynamic instead of just flipping the hardcoded
value.** A hardcoded switch to SCAN would just recreate the same bug in
the other direction (wrong before Phase 6, right after) — a future rebuild
that reaches Phase 2 again would get an alias pointing at SCAN before
`apexdb_stby` exists. `dataguard_net_config` now checks the real state
first, same check-then-act idiom used everywhere else in this project:

1. `srvctl config database -d apexdb_stby`, delegated to
   `groups['standby_nodes'][0]` (`oradbserv09`) — only usatclust2's own
   CRS/OCR knows this; the primary nodes are a genuinely separate cluster
   and can't query it at all. `failed_when: false`, `rc == 0` means
   registered.
2. `dg_net_config_standby_host` is set to `dg_standby_scan_fqdn`
   (`scan-usatclust2.usat.com`) if registered, `dg_standby_node1_fqdn`
   (`oradbserv09.usat.com`) if not — both vars already existed in
   `group_vars/all.yml`; `dg_standby_scan_fqdn` was previously "kept
   defined for later, not deleted." It's the target now.
3. A `debug` reports which target this run picked and why, before writing
   anything — not silent.

Practical effect: a fresh Phase 2 run (before Phase 6) still gets the
hostname-based alias, correctly. Re-running `--tags dataguard_net_config`
any time *after* Phase 6 has completed now correctly upgrades the standby
aliases to SCAN. This isn't wired to fire automatically at the end of
`dataguard_convert_rac` itself — `dataguard_net_config` runs against
`dg_db_nodes` (both clusters, its own dedicated play), and
`dataguard_convert_rac` runs as `hosts: localhost` with `delegate_to`;
cleanly invoking one from inside the other wasn't worth the added
complexity when a documented manual re-run tag achieves the same result.
See `high-availability/README.md` Section 12 for that instruction.

**Also split the `tnsnames.ora` managed block in two**, per James's own
request — one `blockinfile` block for the primary aliases
(`apexdb`/`apexdb_dg`), a separate one for the standby aliases
(`apexdb_stby`/`apexdb_stby_dg`), each with its own `# {mark} ... DB - Data
Guard TNS aliases` marker instead of one combined `ANSIBLE MANAGED BLOCK`.
Two direct benefits: the standby block can be regenerated on its own
(exactly what the SCAN switch above needs) without touching the primary
block at all, and the final file reads as two clearly-separated,
single-entry-per-alias sections — matching what James confirmed by hand
was the correct end state, instead of the risk of a stray duplicate block
from a manual edit landing alongside the Ansible-managed one.

**Not yet re-run for real** — the code change is in place
(`dataguard_net_config/tasks/main.yml`, `group_vars/all.yml`) but hasn't
been exercised by an actual `--tags dataguard_net_config` run since Phase 6
completed. Next real run should show `apexdb_stby`/`apexdb_stby_dg`
pointing at `scan-usatclust2.usat.com` in the "Show rendered tnsnames.ora"
task output, and the `debug` task right before the standby block should
report `apexdb_stby IS CRS-registered`.

## 135. James's direct call: drop the static `_DGMGRL` listener entry from Phase 2 — it's dead configuration until Broker is actually built

Section 6.2 of `dataguard_net_config` (Phase 2) was adding **two** `SID_DESC`
entries to each node's static `SID_LIST_LISTENER` stanza: a plain
(no-suffix) entry and a `_DGMGRL`-suffixed one, on the reasoning that
Broker connections need a static entry too, same as the plain service does
for RMAN's pre-MOUNT `AUXILIARY` connection (#103). James's direct
instruction: limit the static listener entry to what Data Guard actually
needs right now, without the broker — add the `_DGMGRL` entry later, when
Section 13 (Broker configuration, still ⬜ Planned, not built) actually
happens.

**Why this is the right call, not just a simplification.** The plain
SID_DESC earns its place today — it's the only reason `dataguard_duplicate`
Phase 4's RMAN `AUXILIARY` connection can reach `apexdb1` before it's even
`MOUNT`ed, and `dataguard_convert_rac` Phase 6 depends on the same
mechanism for `apexdb2`. The `_DGMGRL` entry, by contrast, exists to let
`DGMGRL`/Broker connect to an instance's `DMON` process by a well-known net
service name — and there is no Broker configuration anywhere in this
project yet (`dg_broker_start=true` is set on both databases, Phase 1 step
10 and Phase 3's pfile, but nothing has actually run `DGMGRL> CREATE
CONFIGURATION` or registered either database with it). A static entry with
nothing on the other end to connect to is just configuration that has to be
carried, tested, and reasoned about for no current benefit — and worse,
carries a real risk of drifting out of sync with whatever Broker's own
setup actually needs by the time Section 13 gets built, since nobody will
have touched or re-verified it in the meantime.

**The fix.** Removed the `_DGMGRL` `SID_DESC` block entirely from the
`blockinfile` content — the managed block now writes exactly one
`SID_DESC` (the plain service). Renamed the marker from `ANSIBLE MANAGED
BLOCK - Data Guard static DGMGRL listener entry` to `... Data Guard static
listener entry` (dropped `DGMGRL` — it's no longer accurate) and updated
the preflight duplicate-stanza check, the verification task names, and the
role's own header comment to match. Whatever role eventually builds
Section 13 is the right place to add the `_DGMGRL` `SID_DESC` back in —
at that point there'll be an actual Broker configuration for it to serve,
and it can be added as its own clearly-scoped change rather than
pre-built speculatively.

**Not yet re-run for real** — same as #134, this needs a fresh
`--tags dataguard_net_config` run to confirm `listener.ora` on all 4 nodes
now shows exactly one `SID_DESC` per node and `lsnrctl services` no longer
lists an `apexdb_DGMGRL`/`apexdb_stby_DGMGRL` service.

## 136. Phase 8 built — Data Guard role-based services (`apexdb_rw`/`apexdb_ro`), on both clusters, ahead of Phase 7 (Broker)

James pasted the real SOP text for role-based services directly (`srvctl
add service` with `-role PRIMARY`/`-role PHYSICAL_STANDBY`, on both
`apexdb` and `apexdb_stby`) and asked which phase this falls under, since
it wasn't obvious from the README alone. Answer, from the project's own
history rather than a guess: `dg_primary_role_service_rw`/`_ro`
(`apexdb_rw`/`apexdb_ro`) were reserved as named variables back in #76,
when the whole SOP naming convention was laid out — before Broker or role
services existed. Separately, #98 and #99 both refer to Broker
configuration as "Phase 7" in this project's own numbering. The README's
own top summary has said "Phases 7-8 are not yet built" for a while now —
two remaining phases, one already consistently called Phase 7 elsewhere.
By elimination, and matching the pre-reserved names exactly, this is
**Phase 8**.

**Built ahead of Phase 7 on purpose, not by accident.** The `srvctl add
service`/`start service`/`stop service` commands James pasted are
self-contained — they don't need Data Guard Broker to exist to register
and start correctly today. What Phase 7 actually adds on top: **automatic**
role-based start/stop *during* a live switchover/failover. Without Broker,
`-policy AUTOMATIC` + `-role` only means a service starts alongside its
instance if the database is *already* in the matching role at that
moment — it will not, on its own, flip `apexdb_rw` off and `apexdb_ro` on
mid-switchover. That live-flip behavior needs Broker actually configured
and a real switchover exercised against it, which hasn't happened yet.
Stated plainly in the role's own pause-for-review prompt, not left as a
silent gap.

**New role: `dataguard_role_services`**, `hosts: localhost` +
`delegate_to` per database (same pattern as `dataguard_convert_rac`/
`dataguard_net_config`, since this role genuinely touches both clusters —
`apexdb` via `groups['rac_node1'][0]`, `apexdb_stby` via
`groups['standby_nodes'][0]`). Design choices worth stating explicitly:

- **The database's role is queried live via SQL (`select database_role
  from v$database`), never assumed.** `apexdb` being `PRIMARY` and
  `apexdb_stby` being `PHYSICAL STANDBY` is true today, but hardcoding
  that would silently go stale and mis-start services after any future
  switchover — a re-run of this role should always reflect whatever the
  database's role actually *is* at that moment, not what it was when the
  role was written. This is the same "verify real state, don't assume"
  idiom this project has used everywhere else (spfile/password-file
  checks, CRS registration state, running-instance state).
- **Idempotent on both axes** — `srvctl config service` checked before
  `add service` (only adds what's missing), `srvctl status service`
  checked before `start`/`stop` (only changes what's not already in the
  right state).
- **One combined pause for review**, showing both clusters' real current
  role and the full plan (what will be added, what will start, what will
  stop) before anything is touched — matching this project's "nothing
  proceeds silently" pattern, not a pause per loop iteration.
- **Preflights that both databases are actually registered and reachable**
  via `srvctl config database` before touching either — this role assumes
  nothing about `apexdb`/`apexdb_stby` being up, since a broken
  precondition here would otherwise fail confusingly deep inside the
  service-add logic instead of with a clear message up front.

Registered in `site.yml` as its own play (`tags: [dataguard_role_services]`),
added to both python3-bootstrap plays' tag lists (it delegates to a
`rac_nodes` host *and* a `standby_nodes` host, same reasoning as
`dataguard_convert_rac`/`dataguard_srl_cleanup` before it, #117/#118).

**Not yet run for real** — this is newly built code, not yet exercised
against the live lab. First real run should confirm: `apexdb_rw`/
`apexdb_ro` both register cleanly on `apexdb` and `apexdb_stby`; the
plan's reported role matches reality (`PRIMARY` for `apexdb`, `PHYSICAL
STANDBY` for `apexdb_stby`); `apexdb_rw` ends up running on `apexdb` and
stopped on `apexdb_stby`, `apexdb_ro` the reverse.

**Update — James's follow-up: apexdb_stby must be OPEN READ ONLY before
its services are touched, checked and fixed explicitly, not assumed.**
`srvctl start service` has nothing to actually serve against a MOUNT-only
standby — the underlying database resource needs to be OPEN, in some mode,
for a service to come up meaningfully. Added a precondition, standby-only
(the primary is trivially OPEN READ WRITE by definition once it's PRIMARY,
so this doesn't apply there):

1. `SELECT inst_id, open_mode, database_role, protection_mode FROM
   gv$database ORDER BY inst_id;` — checked first, real state, not
   assumed.
2. If `OPEN_MODE` isn't already `READ ONLY`: reports why (not silent),
   then `ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;` followed
   immediately by `ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING
   CURRENT LOGFILE DISCONNECT FROM SESSION;` in the same script — `CANCEL`
   failing because no MRP was running isn't treated as fatal, SQL\*Plus's
   default behavior (no `whenever sqlerror exit`) just continues to the
   restart statement either way, same tolerance idiom `dataguard_srl_
   cleanup` uses for `ORA-00261`.
3. Verifies `MRP0`/`RFS` are actually running (`v$managed_standby`) before
   opening anything.
4. `ALTER DATABASE OPEN READ ONLY;`, then re-runs step 1's exact query to
   confirm it actually landed — hard `fail:` if it still isn't `READ ONLY`
   after all of that, rather than plowing ahead and starting `apexdb_ro`
   against a database that isn't really open.
5. If step 1 already showed `READ ONLY`, none of steps 2-4 run — this
   whole precondition is itself idempotent, safe to re-run.

**This is a durable state change worth naming plainly, not a one-off
fix-up.** `USING CURRENT LOGFILE DISCONNECT FROM SESSION` is real-time
apply — different from the plain `DISCONNECT FROM SESSION` managed
recovery Section 12 (`dataguard_convert_rac`) left running, which only
applies from complete archived logs. From this role onward, `apexdb_stby`'s
normal resting state changes from `MOUNTED` (apply-only) to `OPEN READ
ONLY` with real-time apply — Active Data Guard, not just a physical
standby. Every future phase that touches `apexdb_stby` (Broker
configuration, Phase 7; FSFO testing) should expect to find it in that
state, not `MOUNTED`.

**Update — first real run, and three real problems found from it.** James
ran the role for real and reported the actual transcript plus his own manual
`srvctl` diagnostics. Three explicit concerns, verbatim: "it doesn't provide
enough output of the commands including srvctl commands," "SQL formatting
still has the `\t`," and "open the database readonly in both nodes not just
oradbserv09" — plus a real failure: `srvctl start service -db apexdb_stby
-service apexdb_ro` failing with `ORA-44304: service apexdb_ro does not
exist`, confirmed independently via his own manual commands, which also
showed `srvctl config database -d apexdb_stby` listing `apexdb_ro` as
registered (`Services: apexdb_ro,apexdb_rw`) and `srvctl status service`
reporting it simply "is not running" — i.e. registered but unable to start,
not missing.

1. **`tab off` was missing from this role's own SQL scripts.** Same bug
   class as #122, just not yet applied here — added to all of
   `dataguard_role_services`'s `SET` lines (`dg_role_services_check_role.sql`,
   `dg_role_services_check_open_mode.sql`, `dg_role_services_open_read_
   only.sql`, `dg_role_services_verify_mrp.sql`, `dg_role_services_open_
   ro.sql`, `dg_role_services_primary_switch.sql`).

2. **The OPEN READ ONLY precondition only ever touched instance 1
   (`oradbserv09`).** `GV$DATABASE.OPEN_MODE` is backed by the shared
   control file, so instance 2's row can misleadingly *appear* `READ ONLY`
   once instance 1 opens, without instance 2 having completed its own open
   transition — each RAC instance genuinely needs its own `ALTER DATABASE
   OPEN` issued in its own session. Fixed: a new `dg_role_services_standby_
   instances` fact (built from `groups['standby_nodes']`, paired with
   `sid_prefix ~ (index + 1)`) drives a per-instance loop for the actual
   `ALTER DATABASE OPEN READ ONLY` step — both `oradbserv09`/`apexdb1` and
   `oradbserv10`/`apexdb2` now get their own open attempt (an already-open
   instance throwing a harmless `ORA-01507`-class error here is expected and
   tolerated, same per-statement SQL\*Plus tolerance idiom as `CANCEL`
   above). The "already done" and final hard-fail checks were also
   tightened to require **no `MOUNTED` row anywhere** in `gv$database`'s
   output, not just a `READ ONLY` match anywhere — a mixed result (one
   instance open, one still mounted) was previously read as "already done,"
   which was wrong. `dg_role_services_verify_mrp.sql` was also switched from
   `v$managed_standby` to `gv$managed_standby` (with `inst_id`), since MRP
   can legitimately be running on either standby instance in RAC.

3. **Root cause of `ORA-44304`, confirmed via research, not guessed.**
   `srvctl add service -role PHYSICAL_STANDBY ...` on the standby's own
   cluster only creates a CRS/OCR-level resource shell — a write to the
   database's actual service dictionary requires a write to the data
   dictionary, which a standby (even Active Data Guard, read-only) cannot
   perform locally. The service's real definition only exists once it has
   been started (even briefly) on the **primary** and shipped to the
   standby via redo apply — confirmed against two independent real-world
   sources describing the identical failure signature and fix:
   [blog.iarsov.com](https://blog.iarsov.com/oracle/active-services-on-physical-standby-database/)
   and a 2013 post
   ([dbakalyan.wordpress.com](https://dbakalyan.wordpress.com/2013/10/22/database-service-with-physical-standby-role-option-in-11gr2/))
   showing the exact same `ORA-44304`/`ORA-44317` pair and prescribing:
   start on primary, log switch(es), let the standby catch up, stop on
   primary, then start on standby. Fixed **reactively**, not unconditionally
   — the standby's own `srvctl start service` is still attempted first
   (the normal path, and the only thing that runs once this has succeeded
   once); only if that specific attempt fails does the role now: start
   `apexdb_ro` on the primary (`srvctl start service -db apexdb -service
   apexdb_ro` — a manual start overrides `-role`/`-policy`, so this works
   even though the role never matches on the primary), force `alter system
   switch logfile;` on the primary so the definition ships immediately, stop
   it again on the primary, then retry the standby's start up to 3 times,
   20 seconds apart (same bounded-retry shape as #122's log-switch retry),
   to cover any residual redo-application lag. A clear `fail:` with manual
   recovery steps fires only if all 3 retries are exhausted.

4. **Every `srvctl` command in the role now has a matching `debug` task**
   showing its raw `stdout`/`stdout_lines` — preflight, both registration
   checks, both `add service` calls, the pre-start status check, the
   start/stop results, and the new primary-bootstrap start/switch/stop —
   directly addressing "doesn't provide enough output."

Not yet re-run for real against the lab with these four fixes in place —
that's the next real-run milestone for this role.

**Update — second real run, against the above fixes: a hang, and the real
root cause of `ORA-44304`, found by James's own manual testing.**

The re-run hung indefinitely on `TASK [Open apexdb_stby read only — once per
instance]`, `oradbserv09` succeeding (`READ ONLY`) and `oradbserv10` never
returning. Root cause: the `copy` task that writes `dg_role_services_open_
ro.sql` still only delegated to `dg_role_services_standby.node` (a single
node), left over from before the OPEN step became a per-instance loop — the
script simply didn't exist on `oradbserv10`. `sqlplus @<missing file>`
printed `SP2-0310` and dropped to an interactive `SQL>` prompt with no
`exit;` ever reached; Ansible's SSH channel doesn't close the remote
process's stdin on its own, so it sat there indefinitely — a well-known
Ansible/`sqlplus` gotcha, not a database-level hang. `apexdb_stby`'s actual
state (`apexdb1` READ ONLY, `apexdb2` still MOUNTED) was fine and expected
given the bug; nothing needed undoing. Fixed: the `copy` task now loops over
`dg_role_services_standby_instances` too, so the script lands on both nodes
before the per-instance OPEN loop runs.

Separately — and this is the substantive one — James tested the sequence by
hand and found the actual root cause behind `ORA-44304`, which the two blog
sources hadn't made clear (or which got misread): **opening a standby read
only silently terminates whatever managed-recovery process was running
before the open.** The role's original order — cancel, restart real-time
apply, verify MRP, *then* open — throws that just-started apply process
away the instant `ALTER DATABASE OPEN READ ONLY` runs. From that point
`apexdb_stby` sits at a bare `READ ONLY` with no apply running at all; no
redo — including any service definition already sitting in the standby
redo logs from the primary bootstrap — ever gets applied, no matter how
many times `srvctl start service` is retried. This is *why* the first
run's retry logic didn't actually fix anything durable: retrying `start
service` can't work if nothing is applying redo in the background.

James's own tested, working sequence (paraphrased from his notes): create
`apexdb_rw`/`apexdb_ro` on both clusters; on the primary, confirm both
exist in `dba_services`, start both, then stop the standby-role one; on the
standby, `ALTER DATABASE OPEN READ ONLY`, *then* `ALTER DATABASE RECOVER
MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION` —
`v$database.open_mode` should now read `READ ONLY WITH APPLY`, not bare
`READ ONLY`; do a few log switches on the primary; confirm `apexdb_ro` now
shows up in the standby's own `dba_services`; then start the correct
service on the standby.

Two small readings of James's raw notes were reconciled against the
project's own established role-based design rather than implemented
literally, since implementing them literally would contradict the whole
point of role-based services: "stop service apexdb_rw" on the primary is
implemented as stopping `apexdb_ro` instead — `apexdb_rw` is the one that's
supposed to stay running on the primary; stopping the wrong-role one it was
just bootstrapped alongside is what actually matches the rest of his own
sequence. Likewise "start the service apexdb_rw on the standby" is
implemented as starting `apexdb_ro` — the standby's real queried role is
`PHYSICAL STANDBY`, so `apexdb_ro` is the one that belongs running there;
the existing role-matching start logic (queries the real role, never
assumes) already does this correctly once the underlying apply-ordering bug
is fixed, no new task was needed for it.

Fixes applied to `dataguard_role_services`:

1. **Reordered the standby precondition**: cancel any current recovery →
   `ALTER DATABASE OPEN READ ONLY` on each instance individually → *then*
   restart real-time apply (`USING CURRENT LOGFILE DISCONNECT FROM
   SESSION`) → verify `MRP`/`RFS` (`gv$managed_standby`) → re-verify. The
   desired end-state is now explicitly `READ ONLY WITH APPLY`, checked via
   `dg_role_services_open_mode_check.stdout is search('READ ONLY WITH
   APPLY')` (and still `is not search('MOUNTED')`) — a bare `READ ONLY`
   match is no longer treated as "already done."
2. **Fixed the missing-script hang**: `dg_role_services_open_ro.sql`'s
   `copy` task now loops over both standby nodes.
3. **Added dictionary-level verification**, straight from James's own SOP
   — `SELECT name, network_name FROM dba_services WHERE name IN
   ('apexdb_rw','apexdb_ro')`, run on the primary right after the services
   are added, and on the standby as part of the `ORA-44304` remediation
   block (after the primary bootstrap's log switches, before the retry) —
   a direct read of the actual data dictionary, stronger evidence than
   `srvctl config`/`status`, which only ever reflected CRS/OCR state (the
   same distinction that caused the original `ORA-44304` confusion:
   `srvctl` said "registered," the dictionary said otherwise).
4. **Bumped the primary-bootstrap log switch from 1 to 3**, matching this
   project's own established dose for "push stuck/queued redo through"
   (#122) — now meaningful, since the standby is genuinely applying at that
   point instead of sitting with a dead MRP.

Not yet re-run a third time with these fixes in place.

**Update — third real run: the reordering fix actually worked, but the role
still reported failure, plus a real gap James caught in his own manual
testing.**

`apexdb_stby` genuinely reached `READ ONLY WITH APPLY` on both instances —
James's own `SELECT open_mode, database_role FROM v$database;` confirmed it
directly. The role's own hard-fail task disagreed, showing the real
`gv$database` output with the value visibly split across two lines:
`READ ONLY WITH A` / `PPLY`. Root cause: `column open_mode format a16` is
only 16 characters wide, but `'READ ONLY WITH APPLY'` is 21 — SQL\*Plus
word-wrapped the overflow onto a second output line, so the literal
substring never appeared contiguously in `stdout`, and every `is
search('READ ONLY WITH APPLY')` check in the role failed despite the real
database state being exactly right. Fixed: widened `open_mode` to `a25`
(and `database_role`/`protection_mode` to `a20` for matching headroom).

Second, more substantive: James reported the services were created on the
primary but never started — "if you do not start the services it will not
be created inside the database." This is real Oracle behavior, not a
misunderstanding: `srvctl add service` only registers a CRS/OCR resource
shell; the `dba_services` row only gets written once `DBMS_SERVICE` is
actually invoked, which only happens on a real start. `-policy AUTOMATIC`
doesn't retroactively start a service against an instance that's already
running when the service is added — it only auto-starts a service alongside
a *future* instance startup. So both `apexdb_rw` and `apexdb_ro` were
sitting registered-but-never-started on the primary, meaning there was
nothing to ever propagate to the standby via redo, no matter how correct
the standby-side apply logic now was.

Fixed with a new, **mandatory** (not reactive) block, right after the
services are added and before any standby work: start both `apexdb_rw` and
`apexdb_ro` on the primary, verify both now show up in `dba_services` (hard
fail if not), then stop `apexdb_ro` again (`apexdb_rw` stays running — its
role matches). Gated on the existing `dba_services` check, so once this has
succeeded, repeat runs skip straight past it — idempotent, matching the
project's own established idiom, not a one-time fixup. The old
reactive-only-on-failure `ORA-44304` remediation block is kept, downgraded
to a lightweight fallback (one more forced log-switch push + bounded
retry) for the standby's own start — it shouldn't normally trigger anymore
now that the primary side is guaranteed correct up front, but costs nothing
to keep as a defensive backstop.

Not yet re-run a fourth time with these fixes in place.

**Update — fourth real run: CONFIRMED clean, end to end.** James's confusion
about `srvctl status service -db apexdb ...` returning `PRCD-1120`/`ora.
apexdb.db does not exist` on `oradbserv09` was also resolved first — not a
role bug, just `srvctl` querying the wrong cluster's OCR (`apexdb` is only
registered in usatclust1; `oradbserv09` is usatclust2, where only
`apexdb_stby` exists). With all four fixes in place, the role ran clean
top to bottom with no manual intervention:

- Preflight, registration checks, and role queries all correct on both
  clusters.
- `apexdb_rw`/`apexdb_ro` added on both `apexdb` and `apexdb_stby`.
- Mandatory primary bootstrap fired (`dba_services` was empty beforehand),
  started both services on `apexdb`, re-verified both now present
  (`apexdb_ro`/`apexdb_rw` both listed), stopped `apexdb_ro` again.
- Standby precondition fired (`apexdb_stby` was `MOUNTED` on both instances
  beforehand): cancel recovery (tolerated `ORA-16136`, nothing was running),
  opened both instances read only, restarted real-time apply, confirmed
  `MRP0 APPLYING_LOG` + active `RFS` via `gv$managed_standby`, re-verified
  `READ ONLY WITH APPLY` on both instances (column-width fix held, no more
  wrapped output).
- **The generic "start role-matching service" step found both services
  already running** — `apexdb_rw` on `apexdb`, `apexdb_ro` on
  `apexdb_stby` (both instances) — and skipped. `-policy AUTOMATIC`
  auto-started `apexdb_ro` on the standby on its own once the database
  reached `READ ONLY WITH APPLY` and the role genuinely matched; the
  ORA-44304 fallback block never had to fire.
- Final state confirmed by `srvctl status service`: `apexdb` running
  `apexdb_rw` only, `apexdb_stby` running `apexdb_ro` only (both instances,
  both databases) — exactly the intended end state.

Phase 8 is now **built and confirmed working** against the live lab.
Remaining known gap, stated plainly and not yet addressed: no automatic
role-flip during a live switchover — that needs Data Guard Broker (Phase 7,
still not built).

## 137. Phase 7 built — Data Guard Broker configuration (`apexdb`/`apexdb_stby`, MaxAvailability), closing the gap #136 left open

James supplied his own draft workflow for the Broker build (`CREATE
CONFIGURATION`/`ADD DATABASE`/`ENABLE CONFIGURATION`, MAA properties,
protection mode, static-identifier validation), plus two real ASM
directory listings from `oradbserv06` proving `+DATA01/apexdb/` and
`+RECO01/apexdb/` had no `/DG` subdirectory yet — the gap #98/#99 flagged
and #135 explicitly deferred. That draft was combined with current Oracle
MAA documentation into a written plan first (no code), then revised twice
more against two of James's own follow-up calls before any Ansible was
written:

**1. TNS alias rename: `_dg` → `_DGMGRL`.** James's own reasoning: the
dedicated Broker-connectivity TNS aliases (`apexdb_dg`/`apexdb_stby_dg`,
built back in `dataguard_net_config` for redo transport, `UR=A`) read as
confusingly close to `dg_broker_config_name` (`apexdb_dg` in
`group_vars/all.yml` — the Broker **configuration's** own name, a
completely different namespace, but visually identical once a real Broker
configuration entered the picture). Renamed to `apexdb_DGMGRL`/
`apexdb_stby_DGMGRL` throughout `dataguard_net_config`, `group_vars/
all.yml`'s comments, and `dataguard_duplicate`'s own comment referencing
them. `dg_broker_config_name` itself was deliberately left as `apexdb_dg` —
that's the standard real-world DGMGRL configuration-naming convention, not
a mistake, and group_vars already had its own comment saying so before this
change.

**2. The static `_DGMGRL` listener entry, deferred by #135, is added for
real now** — but by `dataguard_net_config` itself, not by the new Broker
role. Oracle allows only one `SID_LIST_LISTENER` stanza per listener name
(the exact reason #135's own preflight check exists), so the `_DGMGRL`
`SID_DESC` had to join the SAME managed `blockinfile` block as the existing
plain-service `SID_DESC`, not live in a second, independently-marked block.
Known, explicitly-flagged limitation: `dataguard_net_config` now owns this
content going forward — if it's ever re-run standalone, it still writes
both `SID_DESC` entries (the second isn't conditional on Broker actually
existing), so there's no regression risk, but any future listener-block
change should extend this same task, not create a new one.

**3. Protection mode: MaxAvailability, not MaxPerformance** — James's
direct follow-up call, plus a direct factual question: does MaxAvailability
just silently degrade to MaxPerformance-like behavior under lag/failure?
Answered plainly rather than hand-waved: yes, functionally — Oracle waits
up to the `NetTimeout` property (30 seconds, left at default) for the
standby's SYNC acknowledgment; past that, Data Guard stops waiting on that
destination and the primary keeps committing without blocking, exactly like
MaxPerformance's async behavior, for as long as the standby stays behind or
unreachable. The protection mode *label* itself doesn't change (`SHOW
CONFIGURATION` still reports `MaxAvailability`) — only the transport
behavior temporarily degrades, resuming true SYNC automatically once the
standby catches up. This graceful degrade-and-resync is exactly why MAA
recommends MaxAvailability over MaxProtection (which instead stalls the
primary if no viable SYNC standby remains). One direct consequence this
surfaced and had to be corrected: James's own draft used
`LogXptMode='ASYNC'`, copied from an earlier (now-superseded) MaxPerformance
plan — MaxAvailability cannot be enabled at all while transport is async,
so `LogXptMode` was changed to `'SYNC'` on both database objects, and is set
*before* the protection-mode edit in the role (order matters — Broker
validates transport capability against the mode change).

**New role: `dataguard_broker`**, `hosts: localhost` + `delegate_to` per
database (`apexdb` via `groups['rac_node1'][0]`, `apexdb_stby` via
`groups['standby_nodes'][0]`) — same pattern as `dataguard_convert_rac`/
`dataguard_role_services`. Covers, in order: ASM `/DG` subdirectory
check-then-create on BOTH diskgroups on BOTH clusters (only the `DG/`
subdirectory itself was missing — DBCA already created the parent
`{{ db_unique_name }}/` directory on both diskgroups, confirmed via James's
own `asmcmd ls` output, so this isn't a multi-level walk, just one
check-then-create step per diskgroup, per his own "no `mkdir -p` in ASM"
reminder); relocating the **primary's** `dg_broker_config_file1/2` onto the
new `/DG` path via the disable → set → enable dance (#81's established
pattern — DMON locks the live path the instant `dg_broker_start=true`); the
**standby's** spfile already pointed at `/DG` (baked in by Phase 4's RMAN
`DUPLICATE ... SPFILE SET`, `dg_broker_start='true'` included) — only the
ASM directory itself was the real gap there, so no standby-side relocation
SQL was needed, just a confirmation query and an alert-log check for any
stale DMON/`ORA-16573` errors from the directory having been missing; a
PAUSE before touching `log_archive_dest_2`/creating the configuration;
clearing `log_archive_dest_2` on both databases (check-then-clear,
idempotent); `CREATE CONFIGURATION`/`ADD DATABASE`/`ENABLE CONFIGURATION`
gated on a `SHOW CONFIGURATION` check (`ORA-16532` = no configuration
exists yet — the standard Broker error for this, not yet confirmed against
a real run); MAA properties (`LogXptMode='SYNC'` both,
`StandbyFileManagement='AUTO'` standby, `FastStartFailoverTarget` both,
prep-only — Fast-Start Failover itself is deliberately NOT enabled by this
role); the protection-mode change (gated on current mode, not
unconditional); `VALIDATE STATIC CONNECT IDENTIFIER` for both databases;
`SHOW CONFIGURATION VERBOSE`/`SHOW DATABASE VERBOSE` as a final health
check. A real switchover test is built into the same role but **off by
default** (`dg_broker_test_switchover`, gated behind its own PAUSE) —
switchover briefly makes the primary unavailable while roles flip, and has
no business running on every idempotent re-run.

**Credential hygiene**: every DGMGRL script opens with `CONNECT sys/
<password>@apexdb_DGMGRL` as its first line, written to a 0600 file via a
`no_log`'d `copy` task — same convention as every SQL\*Plus/RMAN script
elsewhere in this project. One honestly-flagged uncertainty rather than an
assumption: unlike SQL\*Plus (which never echoes an unset-`ECHO` script's
input lines), DGMGRL's exact default echo behavior for an in-script
`CONNECT` line isn't something I'm fully grounded on — as a defense-in-depth
safety net regardless of the answer, every `debug` task that displays
DGMGRL output runs it through a `regex_replace` that strips the literal
live `sys_password` value first. Also flagged rather than assumed: DGMGRL
has no documented `whenever sqlerror exit failure` equivalent, so a task
"not failing" isn't proof every command inside its script actually
succeeded — the real output is always shown, and should be read on the
first real run, not just the task's pass/fail state.

**SYS password sync**: not a new step here — Phase 4's RMAN `DUPLICATE`
already copied the primary's real password file onto the standby verbatim
(#116), which is exactly what Broker requires across every database in a
configuration.

Registered in `site.yml` as its own play (`tags: [dataguard_broker]`),
placed after the Phase 8 play (matching Phase 8's own precedent of being
numbered lower than Phase 7 but built/positioned after it), added to both
python3-bootstrap plays' tag lists (delegates to a `rac_nodes` host *and* a
`standby_nodes` host, same reasoning as every other cross-cluster role
before it).

**Update — first real run: `dgmgrl @file` is not valid DGMGRL syntax, and
the false-positive it caused.** The role's real first run hit a wall
immediately: every DGMGRL invocation printed "Invalid option." right after
the welcome banner, then "not logged on" for every subsequent command.
Root cause: `dgmgrl @{{ path }}` (the RMAN/SQL\*Plus convention for running
a script file) is simply not valid DGMGRL command-line syntax — nothing in
any of the scripts actually executed. This included the very first `SHOW
CONFIGURATION` check, whose garbled output never contained the literal
string `ORA-16532`, which made `dg_broker_config_exists` evaluate to a
false positive (the role concluded a configuration already existed). James
proved this directly with his own manual `dgmgrl` session — bare `dgmgrl`,
then typed `connect sys/sys@apexdb_DGMGRL as sysdba`, then `show
configuration` — which returned the real, correct `ORA-16532: ... does not
exist`. Fixed: every DGMGRL invocation switched from a `@file` argument to
shell input redirection (`dgmgrl < {{ path }}`) — the standard, documented
way to script DGMGRL non-interactively, and the exact mechanism James's own
working manual sequence implied (stdin instead of a keyboard). `AS SYSDBA`
was also added explicitly to every `CONNECT` line rather than relying on it
being optional per the syntax reference.

**Update — second real run: two more real Oracle errors, one dropped
feature, and an idempotency-gate bug found before it could bite.** With the
invocation fixed, DGMGRL actually started running commands for real:

1. **`ORA-16571: Oracle Data Guard configuration file creation failure`
   on `ADD DATABASE`.** The primary's `CREATE CONFIGURATION` succeeded (its
   own broker file was freshly created right after this role's own
   disable/set/enable relocation dance, which bounces DMON as a side
   effect) — but adding the standby failed, cascading into every later
   step (`Object "apexdb_stby" was not found` on the properties edits,
   `ORA-16860` on the `FastStartFailoverTarget` property, `ORA-16627` on
   the protection-mode change, since MaxAvailability needs a standby member
   to support it). Root cause: the standby's `dg_broker_config_file1/2`
   have pointed at `/DG` since Phase 4 with `dg_broker_start='true'` baked
   in — DMON has been running since instance startup and had almost
   certainly already failed once against a `/DG` path that didn't exist in
   ASM until earlier in that same run. DMON doesn't retry in the
   background; it only reattempts when `dg_broker_start` transitions
   state. The primary got that bounce for free from its own relocation
   dance; the standby never did.
2. **A second, deeper layer under the same symptom.** A plain
   `dg_broker_start=false`/`true` toggle on the standby (no file
   re-statement) still wasn't enough — James's own follow-up diagnosis
   (`ORA-16525: The Oracle Data Guard broker is not yet available` on a
   retried `ADD DATABASE`, `show parameter dg_broker_start` reading
   `FALSE`, and the standby's own alert log) found that `dg_broker_start=
   true` was being silently rejected and reset back to `FALSE`, with the
   alert log stating plainly: "One or both of the files specified by the
   dg_broker_config_file[1|2] initialization parameters cannot be
   written... DG_BROKER_START has been set to FALSE" — even though the ASM
   directory itself was confirmed real (`asmcmd ls -l`). Toggling
   `dg_broker_start` alone, without RE-ISSUING the `dg_broker_config_file1/2`
   `SET` statements (even to the exact same paths), wasn't sufficient for
   DMON to successfully open the file. James confirmed the real fix by
   hand: re-set both file parameters, *then* `dg_broker_start=true` —
   succeeded cleanly. Fixed: the standby's restart step now does the same
   three-step dance (disable → re-set file1/file2 → enable) the primary's
   relocation already used, rather than the shortcut this role originally
   assumed was safe (that the standby could skip the "set" step since its
   path wasn't changing — wrong; Oracle needs the `SET` restated as part of
   any `dg_broker_start` re-enable, not just implicitly reused).
3. **`VALIDATE STATIC CONNECT IDENTIFIER` dropped — wrong on both
   attempts, verified rather than guessed a third time.** First attempt
   (`VALIDATE STATIC CONNECT IDENTIFIER FOR <db>`) failed with a DGMGRL
   syntax error; a second attempt at the "corrected" word order (`VALIDATE
   DATABASE <db> STATIC CONNECT IDENTIFIER`) failed with the *identical*
   error. A web search (not another guess) confirmed the original wording
   was in fact the real, correct DGMGRL syntax — but the command was
   introduced in Oracle Database 18c, and this lab's DGMGRL is 12.2.0.1.0
   (confirmed from every DGMGRL banner in every real run). No wording fix
   could have made it work on this release. Dropped outright, with the
   role's own comment explaining why and noting that `dataguard_net_config`'s
   existing `tnsping` + real `sqlplus` login against `apexdb_DGMGRL`/
   `apexdb_stby_DGMGRL` is the practical equivalent already covered on this
   version.
4. **Idempotency-gate bug caught before it became a real problem**: the
   original single `dg_broker_config_exists` gate governed `CREATE
   CONFIGURATION`, `ADD DATABASE`, and `ENABLE CONFIGURATION` together —
   but the second real run left the configuration genuinely existing (just
   with `apexdb` as its only member, no standby, `MaxPerformance` by
   default), which would have made that single gate permanently skip `ADD
   DATABASE` on every future run. Split into three independently gated
   steps: `CREATE CONFIGURATION` gated on whether a configuration exists at
   all; `ADD DATABASE` gated separately on whether the standby specifically
   is already a member (checked by searching the `SHOW CONFIGURATION`
   output for its `db_unique_name`); `ENABLE CONFIGURATION` always
   attempted last (harmless against an already-enabled configuration).

**Update — third real run: CONFIRMED clean, end to end.** With all of the
above in place, the role ran clean top to bottom: standby broker restart
succeeded (file paths re-set, `dg_broker_start=true` held this time);
`CREATE CONFIGURATION` recognized the already-existing configuration and
skipped cleanly; `ADD DATABASE` succeeded against a properly-started
standby broker; `ENABLE CONFIGURATION` confirmed; MAA properties applied
correctly against a real standby member (`LogXptMode='SYNC'` both,
`StandbyFileManagement`, `FastStartFailoverTarget` prep-only); protection
mode reached **MaxAvailability**; final health check showed both databases
with `SUCCESS` status. Phase 7 is now **built and confirmed working**
against the live lab, closing the automatic-role-flip-on-switchover gap
`known-risks.md` #136 left open. Remaining known gap, stated plainly and
not yet addressed: Fast-Start Failover and its Observer are deliberately
NOT configured by this role (Section 15, still not built) — the
`dg_broker_test_switchover`-gated switchover test in this role also hasn't
been exercised yet, so the automatic service role-flip claim itself is
still unverified against a real role change, only against a static,
enabled configuration.

**Update — switchover test extracted into its own standalone role.** James
ran `--tags dataguard_net_config,dataguard_broker` without setting `-e
dg_broker_test_switchover=true`, and (correctly, by design) every
switchover-related task reported `skipping: [localhost]` — but a flag that
has to be remembered on the command line for a genuinely disruptive,
briefly-primary-unavailable operation is easy to forget, and arguably
doesn't belong reachable from this role's normal idempotent re-run path at
all. Pulled the whole switchover block out of `dataguard_broker` into a new
standalone role, `roles/dataguard_switchover_test`
(`--tags dataguard_switchover_test`, wired into `site.yml` as its own play
right after the Phase 7 play, and added to both python3-bootstrap plays'
tag lists the same way every other cross-cluster role is). Design notes:

- **Direction-agnostic**, not hardcoded to "switch apexdb to apexdb_stby":
  it runs `SHOW CONFIGURATION` first and parses which database currently
  reports `- Primary database` to decide direction, so the exact same
  role/tag switches over on one run and switches back on the next — no
  separate undo role, no direction variable.
- **Connects via the CURRENT PRIMARY's `_DGMGRL` alias** to issue
  `SWITCHOVER TO <standby>` — verified via web search rather than assumed,
  since this project has already been burned twice by guessing DGMGRL
  syntax (the `dgmgrl @file` bug and the `VALIDATE` word-order guess
  earlier in this same entry). DGMGRL's documented behavior is that
  `SWITCHOVER TO` must be issued from a session connected to the current
  primary; it then coordinates the standby side automatically.
- Reuses the fixed `dgmgrl < file` stdin-redirection invocation, `AS
  SYSDBA`, `no_log`'d 0600 script writes, and the `regex_escape`-protected
  password redaction — all established in this same role's earlier fixes
  above.
- Post-switchover verification is real SQL against `v$database`
  (`database_role`/`open_mode`), not just DGMGRL's own "Switchover
  succeeded" message — delegated to each database's own owning node using
  local OS-authenticated `sqlplus -s / as sysdba`, matching
  `dataguard_role_services`' own established convention (no password
  needed for a plain `SELECT`, unlike the DGMGRL scripts).
- Then checks `srvctl status service` for `apexdb_rw`/`apexdb_ro` on both
  clusters and reports plainly whether they actually followed the new
  roles automatically — the actual point of the exercise, and still
  unverified until James runs it for real.

Not yet run. Once it is, this entry (or a new one) should record the real
result — confirmed automatic flip, or not.

**Update — run for real (2026-08-18), CONFIRMED end to end.** James ran
`--tags dataguard_switchover_test -e sys_password='...'` against the live
lab. Full result, task by task:

- `SHOW CONFIGURATION` correctly detected the pre-switch state (`apexdb -
  Primary database`, `apexdb_stby - Physical standby database`) and set
  the switchover direction from that, not a hardcoded assumption.
- The interactive `PAUSE` worked as designed — stopped and waited for
  Enter before touching anything.
- `SWITCHOVER TO apexdb_stby`, issued while connected via `apexdb_DGMGRL`
  (the then-current primary's alias, per this entry's earlier note on
  DGMGRL requiring a primary-side connection for `SWITCHOVER TO`),
  succeeded cleanly: `Switchover succeeded, new primary is "apexdb_stby"`,
  and the post-switch `show configuration;` in the same script showed the
  `Members:` list correctly reversed (`apexdb_stby - Primary database`,
  `apexdb - Physical standby database`).
- Real SQL against `v$database` on both instances (local OS-authenticated
  `sqlplus -s / as sysdba`, not a DGMGRL claim) independently confirmed the
  new roles: `apexdb: PHYSICAL STANDBY|READ ONLY WITH APPLY`, `apexdb_stby:
  PRIMARY|READ WRITE`. No daylight between what DGMGRL reported and ground
  truth.
- The actual point of the whole exercise: `srvctl status service` on both
  clusters afterward showed `apexdb_rw` stopped on apexdb (new standby) and
  running on apexdb_stby (new primary); `apexdb_ro` running on apexdb (new
  standby) and stopped on apexdb_stby (new primary) — with no manual
  `srvctl start`/`stop` anywhere in this role. Section 13's `-policy
  AUTOMATIC` role-based services flipped on their own during a real
  switchover, exactly as designed.

Section 13/14's automatic-role-flip claim is now **verified against a real
role change**, not just a static enabled configuration — the gap this
whole standalone role existed to close. Remaining known gap, unchanged:
Fast-Start Failover and its Observer (Section 15) are still not built.

One loose end from this same run, unrelated to the switchover result
itself: James asked to keep `dg_switch_switchover.dgc` on disk after the
run instead of deleting it (for reference — see the role's own header
comment on this deliberate deviation from the usual password-script
hygiene convention). This particular run still shows the old
delete-after-use behavior in its output, meaning that edit likely lands on
the NEXT invocation rather than this one — worth confirming on his end
before the switch-back run, rather than assuming.

## 138. Phase 9 built — Fast-Start Failover and Observer (`oemserver01`), closing README.md Section 15's gap

New role `roles/dataguard_fsfo` (Data Guard Phase 9, `--tags dataguard_fsfo`),
coordinating three hosts in one play (`rac_node1`, `standby_node1`,
`observer_nodes`) — same `hosts: localhost` + `delegate_to` pattern as
`dataguard_broker`/`dataguard_role_services`. What it does: closes a real
Flashback Database gap found on `apexdb_stby` (Section 5.3 only ever
enabled it on the primary — confirmed by reading `dataguard_standby_prep`,
not assumed), bootstraps `oemserver01` under Ansible management for the
first time ever, builds an Oracle Wallet there for password-less Observer
reconnection, sets `FastStartFailoverThreshold`, enables FSFO, and starts
the Observer itself.

**oemserver01 is a genuinely different kind of host for this project.**
Every other Data Guard role targets `rac_nodes`/`standby_nodes` — cloned,
identical-architecture nodes this project built from scratch. `oemserver01`
is the pre-existing OEM 13.5 VM (project baseline), explicitly called out
in `inventory/hosts.ini`'s `[time_master]` comment as "not otherwise
managed by this phase" — until now. It runs its own unrelated 19.3.0
Oracle Client (19.19 DGMGRL, confirmed live), not the 12.2.0.1 `db_home`
every other node shares. Bootstrapping Ansible access to it required the
same one-time manual `ansible` OS-user + `ssh-copy-id` dance documented in
`docs/ansible-on-windows.md` #4 (nothing can SSH in as `ansible` before the
account and key exist — not something Ansible itself can do), plus the same
missing-`/usr/bin/python3` bootstrap play every other node needed the first
time (#17) — confirmed live: a first `ansible -m ping` against `oemserver01`
failed with exactly that error.

**First real run — a genuine Ansible variable-scoping bug, not a DGMGRL
issue.** `fsfo_dir`, `fsfo_wallet_dir`, `observer_oracle_home`, and
`dg_observer_name` were originally defined in a new
`group_vars/observer_nodes.yml`, following `group_vars/standby_nodes.yml`'s
own per-group redirection pattern exactly. First delegated task failed:
`'fsfo_dir' is undefined`. Root cause: `group_vars/<group>.yml` only
auto-loads for hosts actually IN that inventory group — this role is
`hosts: localhost`, and `localhost` is not a member of `observer_nodes`, so
the file never loaded for this play at all, even though the task itself
correctly delegated to and ran on `oemserver01`. Every var that already
worked from this same kind of localhost-hosted, delegate_to role
(`db_home`, `sid_prefix`, `oracle_user`, `staging_dir`) only does so
because those live in `group_vars/all.yml`, which loads for every host
including `localhost`. Fixed by moving all four variables into `all.yml`
instead (new, dedicated names, still not reusing `db_home`/`staging_dir` —
those would be actively wrong for oemserver01's different Oracle version
and path). `group_vars/observer_nodes.yml` kept in place, deliberately
empty, with the full explanation, rather than deleted.

**James's explicit instruction mid-build: stop deleting password-bearing
scripts, and show every command and its output, not just final results.**
Previously every DGMGRL/SQL*Plus script embedding `sys/{{ sys_password }}`
got deleted right after use (established convention across every prior Data
Guard role). James asked to keep them on disk instead (warn, don't delete —
he'll clean up by hand) specifically so he could inspect exactly what ran.
Applied project-wide within this one role: every `.dgc`/`.sql` script stays
on disk, no task uses `no_log` anymore, and every `command`/`shell` task
that previously only showed its output now also shows the literal command
line invoked. This surfaced a real gap while doing it: several `mkstore`
wallet tasks (`-create`, `-listCredential`, both `-createCredential` calls)
had no `register`/debug pair at all — James caught this directly ("I only
know that the wallets have been created... What commands did you use and
what was the output") — fixed by adding registers and command+output debug
tasks to all of them, plus explicit "skipped, already present" reports on
every idempotency branch so a bare `skipping: [localhost]` never appears
without an explanation next to it.

**Second real run: `START OBSERVER` syntax error, and DGMGRL's own
false-positive problem bit again.** `start observer <name> in background
file is '<path>' logfile is '<path>';` — no `CONNECT IDENTIFIER` clause —
returned `Syntax error before or at ";"`, but DGMGRL exited 0 anyway (no
`whenever sqlerror` equivalent, same gap #137 already documented for
`dataguard_broker`), so the Ansible task showed `changed` while nothing had
actually started. Only the follow-up `SHOW FAST_START FAILOVER`'s own
`Observer: (none)` caught it — a second layer of verification doing exactly
its job. First fix attempt guessed the quoted file paths were the problem
and dropped the quotes; that guess was wrong — James ran the corrected
command by hand interactively and confirmed the quoted form works fine.
Verified against that real, working transcript instead of guessing a third
time: the only thing actually missing was an explicit
`CONNECT IDENTIFIER IS apexdb_DGMGRL` clause, which turns out not to be
optional for a *backgrounded* observer specifically — it's how the detached
process knows what to reconnect to later, separate from the `CONNECT` that
just opens the authoring session. Quotes restored to match the confirmed
transcript exactly. Also added a real success check (searches stdout for
`Submitted command "START OBSERVER"`) instead of trusting rc, so this exact
class of false positive can't slip through silently again.

**Third real run: CONFIRMED.** Flashback correctly detected already-`YES`
on `apexdb_stby` and skipped the apply-off/enable/apply-on sequence
cleanly. Wallet and both credentials already present from the prior run,
detected and skipped correctly. `FastStartFailoverThreshold=30` set,
`ENABLE FAST_START FAILOVER` succeeded. The observer-process idempotency
check found nothing running (the process from an earlier manual test had
since stopped) and correctly re-ran `START OBSERVER`, which this time
returned `Submitted command "START OBSERVER" using connect identifier
"apexdb_DGMGRL"` — the real success message. Final `SHOW OBSERVERS`
confirmed `oemserver01_observer` live and pinging.

One real, live wrinkle surfaced during this same testing window, worth
recording honestly even though it wasn't this role's own bug: `SHOW
OBSERVERS` briefly showed a SECOND, stale entry —
`"oemserver01.usat.com"(19.48.0.0.0) - Backup"` with `Last Ping: (unknown)`
on both lines, no live process behind it — and at one point that dead
entry was marked `(*)` MASTER while the real, live, correctly-named
`oemserver01_observer` was relegated to backup. Root cause: an earlier
manual `dgmgrl` test during this same debugging session registered an
observer under the default hostname (no explicit name given that time),
and the broker's persistent config doesn't automatically drop a dead
observer registration just because its process exited — it has to be
stopped explicitly (`STOP OBSERVER 'oemserver01.usat.com';`). James
confirmed this was his own manual-testing artifact, not something this
role produces on a fresh run, and cleaned it up by hand. Worth knowing
about if `SHOW OBSERVERS` ever shows an unexpected extra entry again: check
whether it corresponds to a live process before assuming the role is
broken.

Also worth recording: a real wallet password (`dg_observer_wallet_password`)
was briefly pasted directly into `high-availability/README.md` as scratch
content during this same session, before the write-up pass replaced it —
flagged and removed rather than carried into the final doc. Given this
project's whole point is eventually publishing these pages, worth a
standing reminder to never paste real `-e` invocations with live secrets
into any doc file, scratch or final.

Remaining known gap, stated plainly: the induced-failover test — actually
killing the primary and watching the Observer auto-promote `apexdb_stby` —
lives in its own planned, standalone role (`roles/dataguard_fsfo_test`,
`--tags dataguard_fsfo_test`, same separation-of-concerns reasoning as
`dataguard_switchover_test`) and hasn't been built or run yet. Everything
confirmed above is FSFO *armed*, not yet exercised against a real outage.

## 139. Section 16 confirmed — Swingbench-driven switchover validation exposed a real client-side connect-string bug, not an Application Continuity gap

Closes `high-availability/part3-post-checks.md` Section 16, the last honest
gap in the Data Guard series. Unlike every other Data Guard section, this one
isn't Ansible-automated — James ran it manually from his own Windows PC using
Swingbench 2.8.0.1630, per his explicit call that this should be a manual,
interactive exercise so he could watch the live throughput chart.

**Real prerequisite chain, confirmed step by step, not assumed:** Java 26
(Swingbench 2.7+ requires 17+; the PC's default `java` resolved to 1.8.0_431
until `JAVA_HOME`/`PATH` were corrected — confirmed via a fresh terminal
after the fix, not the one that was already open), DNS/connectivity to both
clusters' SCAN listeners (confirmed for real via `sqlplus system/system@
apexdb_rw` and `@apexdb_ro` landing on the correct hosts — `oradbserv05` and
`oradbserv10` respectively — stronger evidence than the `Test-NetConnection`
originally suggested), and the SOE schema loaded onto `apexdb` via
`oewizard`, connected through the role-based service (`apexdb_rw`) rather
than a bare SID.

**First real switchover-under-load attempt: total, permanent failure —
root-caused as a connect-string bug, not an Application Continuity gap.**
Swingbench was configured with `//scan-usatclust1.usat.com:1521/apexdb_rw`
— a connect string naming only ONE cluster's SCAN listener. This lab's Data
Guard setup spans two genuinely separate clusters (`usatclust1` for the
primary, `usatclust2` for the standby), each with its own SCAN — not one
shared SCAN the way a lot of single-cluster Data Guard reference examples
work. The moment a real switchover relocated `apexdb_rw` onto `usatclust2`,
`scan-usatclust1.usat.com`'s listener no longer had that service registered,
and every one of Swingbench's reconnect attempts kept hitting the same dead
end forever — an unbounded `SQLRecoverableException` loop, confirmed still
looping even well after the database side had fully settled (a separate
`dg_monitor` run 30+ minutes later showed both instances healthy,
`READ ONLY WITH APPLY`, no gaps — the database was fine the whole time).
This was diagnosed carefully rather than assumed: `srvctl status service`
checked directly on both clusters first, confirming `apexdb_rw` genuinely
was running on the new primary (`apexdb_stby` at that point) — which ruled
out a service-relocation bug and pointed squarely at the client-side connect
string instead.

**Fix: a proper two-address connect descriptor**, listing both clusters'
SCAN listeners under one `DESCRIPTION`, so Oracle Net's own connect-time
failover tries each address until it finds the one currently holding the
service — the same pattern any real client (including the eventual NestWise
app) needs for this two-cluster topology. Written up by James directly and
committed as [`high-availability/tnsnames-application.ora`](../../high-availability/tnsnames-application.ora):

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

Also switched Swingbench's benchmark config from a generic Order Entry
workload to `SOE_Client_Side_AC` — the config built specifically to exercise
Application Continuity's replay/reconnect behavior — once James recognized
the originally-selected workload wasn't the right tool for what this section
is actually trying to demonstrate.

**Confirmed clean run.** `dataguard_switchover_test` (switching back to
`apexdb` as primary) completed with `failed=0` — real SQL confirmed the role
flip, and this run's own `srvctl status service` checks (Part 2's existing
verification step) confirmed `apexdb_rw`/`apexdb_ro` both landed on the
correct cluster automatically. Swingbench's `SOE_Client_Side_AC` chart shows
a real dip in TPS/DML operations/response time starting almost exactly when
the switchover was triggered (~14:57), recovering on its own with no manual
reconnect by ~14:59 — correlated against the Ansible run's own timestamps,
not just eyeballed. Stated honestly in the write-up: this is not a
zero-impact switchover — there's a real, roughly one-minute dip on the chart
— but it is a bounded, self-healing one, which is the actual, defensible
claim the evidence supports.

**One thing this run did NOT hit, that an earlier run did — worth tracking,
not yet fixed.** An earlier `dataguard_switchover_test` run hit
`ORA-01507: database not mounted` on its post-switchover real-SQL
verification query, because Clusterware was still mid-restart of the
demoted primary when the check fired — the role correctly failed loudly
rather than trusting DGMGRL's own "succeeded" message, exactly as designed.
This confirmed run didn't hit the same issue, with no code changes between
the two — consistent with a timing race, not a structural bug. Still open:
`dataguard_switchover_test`'s post-switchover verification query has no
wait/retry before it runs, unlike the `ORA-44304` retry logic already built
into `dataguard_role_services` (#136) for exactly this class of "the
database needs a moment to finish transitioning" timing gap. Worth adding
the same pattern here so this doesn't depend on being lucky about timing on
a given run.

## 140. Real induced-failover drill — closes the gap #138 left open, confirmed manually, `dataguard_fsfo_test` still not built as its own role

Everything #138 confirmed was FSFO *armed* — Broker enabled, threshold set,
Observer running — but explicitly not yet exercised against a real outage.
James closed that gap by hand: a genuine `srvctl stop database -d apexdb -o
abort` against the live primary, not a graceful shutdown, with
Swingbench's `SOE_Client_Side_AC` (same config as #139) running against it
the whole time. No `roles/dataguard_fsfo_test` Ansible role exists yet — this
was a manual drill, same relationship Section 10's first RMAN duplicate had
to `dataguard_duplicate` before it was automated. Worth being precise about
that distinction in any write-up: the *mechanism* is now proven end to end,
the *automation* of proving it again on demand is still open.

**Baseline confirmed healthy first**, via the standing monitoring scripts
(#139's `monitor_dataguard.sh` on both clusters,
`montor_manage_observer.sh status` for the Observer) — everything green,
Observer `HEALTHY`, pinging both sides within single-digit seconds.

**The abort landed at 17:32:29.** The Observer's own log shows the real
FSFO decision sequence, not a paraphrase of it: an initial `"Fast-Start
Failover is not possible because primary last contacted the standby within
FastStartFailoverThreshold seconds"` warning at `17:33:41` — the Observer
correctly refusing to react to a single missed ping — followed by
`"Fast-Start Failover started..."` at `17:33:44` once the outage was
confirmed genuine, and `"Failover succeeded, new primary is 'apexdb_stby'"`
at `17:33:58`. Independently confirmed via `gv$fs_failover_stats` afterward
(`LAST_FAILOVER_REASON: Primary Disconnected`, both instances agreeing,
`LAST_FAILOVER_TIME` a few seconds off DGMGRL's own log timestamp — expected,
different subsystems recording the same event).

**RPO/RTO, same framing as #139, now for a real unplanned failover instead
of a planned switchover:** RPO zero — `Primary Disconnected` is not a
lag-based failover reason, and `Lag Limit: 30 seconds (not in use)` in the
Broker's own config confirms this ran in genuine Zero Data Loss Mode, not a
lag-limited fallback. RTO roughly a minute and a half, abort to confirmed
new primary (`17:32:29` → `17:33:58`) — close to the planned-switchover RTO
from #139 despite this being a real crash, not a coordinated role swap; the
Observer's own 30-second confirmation window accounts for most of the
difference.

**The old primary needed manual reinstatement — expected, not a bug.**
`FastStartFailoverAutoReinstate = 'TRUE'` is set, and an automatic
reinstate attempt did fire (`17:34:07`), but failed with `ORA-12514`
because the old primary's instances were still down from the abort — an
auto-reinstate can't attach to a target that isn't listening yet. `SHOW
CONFIGURATION VERBOSE` afterward correctly reported `Configuration Status:
WARNING` (not `ERROR`) with `apexdb ... (disabled), ORA-16661: the standby
database needs to be reinstated` — an honest, actionable status, not a
broken one. `SHOW DATABASE apexdb StatusReport` returned a genuine minor
rough edge, `ORA-16548: Message 16548 not found` (an empty message-catalog
lookup against the disabled old primary) — noted, not chased further.
Reinstated manually and cleanly: `REINSTATE DATABASE apexdb;` →
`"Reinstatement of database 'apexdb' succeeded."`

**Confirmed, follow-up:** `REINSTATE DATABASE` does not start a down instance
on its own — Broker's reinstate workflow resyncs a mounted instance via
Flashback Database, but has nothing to attach to if the instance isn't even
mounted. `oradbserv05`/`oradbserv06` needed an explicit manual
`srvctl start database -d apexdb -o mount` (run at 18:31:32, ~57 minutes
after the failover) before `REINSTATE DATABASE` would succeed —
`FastStartFailoverAutoReinstate=TRUE` covers the resync, not the restart.
Worth remembering as a standing step for any future real drill: bring the
old primary's instances up in `MOUNT` (not `OPEN`) first, then reinstate.

**`roles/dataguard_fsfo_test` — explicitly put on hold, James's call.** Not
an oversight or something still being scoped: the induced-failover mechanism
itself is now proven end to end by hand (this entry), and automating the
drill into its own repeatable role is deliberately deferred rather than
treated as an immediate next step.

## 141. Consolidating `cross_cluster_ssh_trust` into `ssh_equivalence` silently converted the play's host loop from *parallelism* into *duplication* — the same mesh built twice, concurrently, both forks appending to the same `authorized_keys`

Phase 7a needed `oracle@oradbserv05 → oracle@oemserver01` so the OEM repository
RU zip could be `rsync`'d directly instead of routed through the Ansible
controller. Two roles already existed that could almost do it. `ssh_equivalence`
built the bidirectional `grid` + `oracle` mesh across a cluster for the Grid
Infrastructure prerequisite; `cross_cluster_ssh_trust` was that same logic
hardcoded to one pair (`oradbserv05 → oradbserv09`) for Phase 6's software copy.

James's call was to stop maintaining two: *"instead of recreating this ssh trust
all the time, why don't you rework the `ssh_equivalence` tasks and I give it
source and target, and if I need it both ways I say bidirectional."* Correct on
the merits — every hard-won detail in these roles (PEM-format keys for
`gridSetup.sh`'s bundled Java client, #16; no pre-seeded IP entry, #62; no
`UserKnownHostsFile /dev/null`, #63; `CheckHostIP` off, #64) had to be remembered
twice, and the two had already drifted on whether `known_hosts` was written
additively or wholesale.

**What the rewrite had to change, and the consequence that came with it.** The
old mesh implementation could not express `oradbserv05 → oemserver01` at all, and
not for a superficial reason. It relied on the play's own host loop plus
`hostvars`: the play targeted `rac_nodes`, every host published its public key as
a fact, and a later task read peers' facts back out. That only works when every
host involved is *in the current play* — which is exactly why #61's
`groups['rac_nodes']` bug silently skipped every iteration when run under
`--tags standby_ssh_equivalence`. So the rewrite made every task
`delegate_to`-driven instead, with no dependency on play membership.

That is the right shape, and it introduced the bug. Once nothing in the role
depends on which host the play is iterating, the play's host loop stops being
parallelism and becomes pure repetition. A play with `hosts: rac_nodes` — which
is precisely what `site.yml`'s `ssh_equivalence` play is — would fork twice, and
*both forks would build the entire mesh*. Not merely wasteful: both forks run
`lineinfile` against the **same** `/home/grid/.ssh/authorized_keys` on the
**same** delegated target at the **same** time. `lineinfile` is
read-modify-write via a temp file and a rename, so two concurrent writers can
each read the pre-existing file and the second rename can discard the first's
addition. The lost entry is a missing authorized key, and a missing authorized
key is #6: `gridSetup.sh` hangs indefinitely with no output rather than failing.

Caught before it ran, from James's question about a *different* thing — "how
would it know the server that I am targeting?" — which forced actually reading
`site.yml` rather than assuming the invocation I had just recommended was sound.
The honest answer to his question is that the tag selects nothing about hosts;
the play's `hosts:` line does. But arriving at that answer meant looking at
`hosts: rac_nodes` sitting above a now-fully-delegated role, which is where the
duplication became obvious.

**Fix:** `tasks/main.yml` is now a one-task wrapper that `include_tasks` the real
work (`configure.yml`) under

```yaml
when: >
  not (ssh_equiv_run_once | bool)
  or inventory_hostname == ansible_play_hosts[0]
```

with `ssh_equiv_run_once: true` in `defaults/main.yml`. Three deliberate choices
in that one line:

- `ansible_play_hosts`, not `ansible_play_hosts_all` — the former excludes hosts
  already failed or unreachable, so if the first inventory host is down the mesh
  is still built from the next live one rather than skipped entirely.
- `include_tasks` with a `when`, not `meta: end_host` — `end_host` would end the
  host for the **whole play**, silently skipping any role listed after this one.
  This gate is scoped to this role.
- A variable rather than a hardcoded gate, purely as an escape hatch. Nothing in
  this project sets it false.

**What did *not* change:** `defaults/main.yml` reproduces the original mesh
exactly (every host in `nodes`, both users, both directions, self included), so
`site.yml`'s `ssh_equivalence` and `standby_ssh_equivalence` plays are untouched.
`cross_cluster_ssh_trust` survives as a deprecation shim forwarding to the new
interface, so `upgrade-19c-rolling.yml`'s call site keeps working until it is
updated and re-tested.

**Still unconfirmed.** Both the delegation rewrite and this gate are reasoned,
not observed. This is a load-bearing GI prerequisite whose failure mode is a
silent hang, so run `--tags ssh_equivalence` and `--tags standby_ssh_equivalence`
on their own and read the per-pair verification output before the next
`grid_infrastructure` run — do not discover it inside a four-hour build.

## 142. Reading patch 39472050's actual README found six things wrong in the Phase 7a runbook and role — and the biggest one was a correct finding about a *different* patch, generalised

James pasted the real Oracle README for Database Release Update 19.32.0.0.260721
(patch 39472050). Everything Phase 7a had been built on until then was reasoned
from this project's own 12.2 GI experience plus general Oracle practice. Six
discrepancies, worth recording individually because they fail in different ways:

**1. The "System Patch" assumption — the serious one.** Both the runbook (§0.5,
§4) and the role's comments said to expect plain `opatch prereq` and `opatch
apply` to be refused with *"This command doesn't support System Patch"*, citing
`patching-strategy.md`'s confirmed 12.2 finding, and to fall back to
`opatchauto`.

That finding is real and it is about a different patch. **39467003, the combo, is
the system patch. 39472050, the Database RU component inside it, is not.** And
39472050 is what this home actually gets, because `oemserver01` has no Grid
Infrastructure, so the combo's ACFS / Tomcat / DBWLM components are out of scope
entirely. Oracle's README for 39472050 documents plain `opatch apply` (§3.2,
non-RAC path) with no mention of `opatchauto`.

The error was not the original finding. It was generalising "the 12.2 GI combo
needed opatchauto" into "expect the same here" without noticing that "here" is a
component of a combo, not the combo.

**2. The conflict check could not fail.** The task ran
`CheckConflictAgainstOHWithDetail ... || true`, justified in its own comment by
#1's assumption: if a refusal is expected, swallowing the return code looks
reasonable. With #1 corrected, it stops being reasonable — a conflict check that
cannot fail is decoration. Now gated by `oem_repo_conflict_check_fatal` (default
true), with an override for the case where a human reads the report and decides
the conflict is ignorable, per Oracle's KB145571 pointer.

**3. Wrong flag: `-ph`, not `-phBaseDir`.** Oracle documents `-phBaseDir` for
this prereq. `-ph` and `-phBaseDir` are not synonyms. This is the kind of thing
that either errors loudly or, worse, checks something other than what was
intended.

**4. `CheckMinimumOPatchVersion` was missing entirely** (README §3.1.3 step 3).
This also resolves an open question that had been sitting in `group_vars/all.yml`
next to `oem_repo_opatch_zip`: *"check 39472050's own README for the minimum
OPatch version it requires."* The README names **no version number at all** — the
check is programmatic. There was never anything to look up.

**5. No CDB branch, and Oracle's procedure has one.** README §3.3.2's Table 2
gives two datapatch procedures, and the multitenant one has a step the non-CDB
one does not: `ALTER PLUGGABLE DATABASE ALL OPEN` **before** datapatch. Without
it, datapatch patches `CDB$ROOT` and whatever PDBs happen to be open, leaving
closed PDBs on an unpatched dictionary — silent until that PDB is opened or
unplugged.

The role had a bare `STARTUP`. Rather than guess, the role now asks
(`SELECT cdb FROM v$database`) and branches.

**Answered the same day, against the live database: `CDB` is `NO`.** `OEMCDB` is
a non-CDB, despite the name. So the bare `STARTUP` was in fact correct *today* —
which is precisely why this is worth an entry rather than a silent fix. It was
correct by luck, not by check, and it had an expiry date: Phase 7d converts this
database, and from that moment a hardcoded non-CDB path would silently patch only
`CDB$ROOT` and leave every PDB on an unpatched dictionary.

The detection stays for that reason, not collapsed back into a variable now that
the answer is known. It costs one query against an already-running instance, it
prints the answer into every run log, and it makes the day 7d lands a non-event.

Two follow-ons from the confirmation, both recorded in
`monitoring/phase-7a-repository-db-ru32.md` rather than here:

- Non-CDB architecture was deprecated in 12.1 and is desupported from Oracle
  Database 21c. If that holds, Phase 7d's conversion is a **hard prerequisite for
  taking this database past 19c**, not a tidiness exercise. Verify against current
  Oracle documentation before planning around it — desupport specifics move.
- Whether EM 24ai's repository itself requires a CDB is a separate question this
  project has not established. It belongs in Phase 7b's scoping, not in the middle
  of an OMS upgrade.

**6. `utlrp.sql` instead of `catcon.pl`.** Oracle documents
`catcon.pl -n 1 -e -b utlrp -d $ORACLE_HOME/rdbms/admin utlrp.sql`. On a non-CDB
the bare form is equivalent, so this would have "worked" — and would have stopped
being equivalent the moment Phase 7d converts the database, because the bare form
only recompiles the container it is connected to. A latent bug with a scheduled
detonation date.

(Phase numbering: the CDB conversion is **7d**, not 7c. 7c is administration
groups and the agent golden image. Earlier drafts of this entry and of
`monitoring/phase-7a-repository-db-ru32.md` collided the two — the original
scoping had RU32 at 7b and the conversion at 7c, and everything shifted when RU32
moved to 7a as a hard prerequisite for the OMS upgrade. Corrected 2026-08-31.)

**Also added, both absent and both documented:** `datapatch -sanity_checks`
before `-verbose` (README calls it optional, then says Oracle highly recommends
it), and `chown root` / `chmod 4750` on `$ORACLE_HOME/bin/extjob` (§3.3.5).
`extjob` is the delayed-failure one: relinking during an RU can reset its owner
and setuid bit, and the symptom — `DBMS_SCHEDULER` external jobs failing — shows
up days later with nothing obviously tying it to the patch.

**And the rollback order was inverted.** The runbook rolled the dictionary back
first (`datapatch -rollback`) then the binaries. README §4.1/§4.2 does the
opposite: `opatch rollback` with everything down, *then* start the database and
run plain `datapatch` as the documented post-deinstallation step — no `-rollback`
flag needed, since with the binaries gone datapatch works out what to undo.

**The generalisable lesson**, and the reason this entry is long: every one of
these came from a *plausible* inference. The System Patch one was even backed by
a real, confirmed, correctly-recorded finding from this same project. What made
it wrong was scope — the finding was about the combo, the role applies a
component. A patch README is two pages and takes five minutes; none of this
needed to be inferred at all.

**Still unconfirmed.** All six fixes are from reading Oracle's document, not from
a run. The preflight tag is read-only and safe at any time — run
`--tags oem_repo_patch_preflight` and confirm the CDB determination, the
`CheckMinimumOPatchVersion` result and the conflict report before booking a
window.

## 143. A Jinja `{%` at column 0 inside a `shell: |` block does not sit "outside the SQL" — it ends the YAML string, and the playbook will not parse at all

The CDB branch added in #142 was written like this:

```yaml
  shell: |
    sqlplus -s / as sysdba <<'SQL'
    STARTUP
{% if oem_repo_is_cdb | bool %}
    ALTER PLUGGABLE DATABASE ALL OPEN;
{% endif %}
    SQL
```

James ran `--tags oem_repo_patch_preflight` and got:

```
ERROR! We were unable to read either as JSON nor YAML
Syntax Error while loading YAML.
  found character that cannot start any token
The offending line appears to be:
    STARTUP
{% if oem_repo_is_cdb | bool %}
 ^ here
```

**Root cause.** A YAML block scalar's indentation is fixed by its first non-empty
line, and **any subsequent line at a shallower indent terminates the block**. The
shell body sits at four spaces, so `{%` at column 0 is not merely un-indented
text inside the string — it is *outside the string*. YAML then tries to parse it
as the next node, sees `{`, and reads it as the start of a flow mapping. Hence
"found character that cannot start any token", and hence the whole file failing
to load rather than the task failing at run time.

**Fix:** indent the Jinja tags to match the rest of the shell body. That is the
only change needed, and it works on both passes: YAML strips the common
four-space indent, so Jinja still sees the tag at the start of its own line, and
Ansible's `trim_blocks` (#70) removes the newline after `%}` so the tag line
disappears rather than leaving a blank one.

**The part worth being uncomfortable about.** The column-0 placement was not a
slip. It carried a comment asserting it was deliberate, explaining a rationale
about `trim_blocks` and leading whitespace, and instructing the reader **"Do not
'tidy' this."**

The reasoning was half-right, which is what made it convincing: `trim_blocks`
does eat the newline after `%}`, and the concern about stray whitespace on the
tag line is a real one — it is simply solved by YAML's indent-stripping, which
the argument never accounted for. Reasoning carefully about the templating pass
while forgetting there is a YAML pass in front of it produced a confident,
specific, wrong instruction that would have survived review precisely because it
looked considered.

A comment telling future readers not to fix a bug is worse than the bug. The
replacement comment states the rule (a shallower-indented line ends the block)
rather than the conclusion, so the next person can check it.

**Same rule, second application.** Heredoc terminators depend on this identically.
`<<'SQL'` needs its terminator at column 0 *of the resulting string*, which means
at the block's base indent in the file. A terminator indented one level deeper is
a heredoc that never closes. Audited across the repository: 16 openers, 16
terminators, all at base indent, in `oem_repo_patch`, `dbca_noncdb` and
`rolling_postupgrade`. Clean.

**Audit run at the same time**, over all 40 task files and playbooks — no tabs, no
unquoted `{{ }}` opening a YAML value, no other column-0 Jinja. Two other findings:
`ssh_equivalence/tasks/per_user.yml` is orphaned dead code left by the #141
rewrite and should be `git rm`'d, and `oem_repo_is_cdb` had a partial-tag hazard
(its `set_fact` resolves false when preflight has not run, silently selecting the
non-CDB path on a CDB) which now fails loudly instead.

**Standing lesson:** `--syntax-check` only parses files a playbook actually
reaches. Parse every `*.yml` directly as well — a role task file that no play
currently includes will otherwise carry a YAML error until the day something
includes it. The commands are in `monitoring/phase-7a-ansible.md`.

## 144. `echo "... \\"` — a backslash before an end-of-line quote is valid YAML, valid bash, and breaks Ansible's argument splitter, failing the entire playbook

Immediately after #143's fix, `bash syntax-check.sh` reported YAML parsing clean
across all 46 files and then failed `oem-repo-patch.yml` on:

```
ERROR! failed at splitting arguments, either an unbalanced jinja2 block or quotes
```

pointing at `- name: Close the run log with a summary` while dumping the whole
shell body — the usual "the error is somewhere in this block" report.

**Root cause.** The summary task's last-but-one line was:

```yaml
    echo " diff -u {{ oem_repo_log_dir }}/baseline_pre_{{ oem_run_ts }}.txt \\"
    echo "         {{ oem_repo_log_dir }}/baseline_post_{{ oem_run_ts }}.txt"
```

The `\\` was there to print a shell line-continuation into the suggested `diff`
command, so the operator could copy a two-line command out of the log. In a YAML
literal block those are two literal backslashes, and bash inside double quotes
renders them as one. Correct on both of those passes.

The pass it is not correct on is Ansible's own. `split_args` tracks quote state
with `_get_quote_state`, which treats a quote character preceded by `\` as
escaped and therefore *not* closing the string. The closing `"` on that line is
preceded by a backslash, so as far as Ansible is concerned the double quote opens
and never closes, and every subsequent line is inside it. The unbalanced-quote
error is raised for the whole task.

**Fix:** stop needing the escape. The diff suggestion is one long line now. Trying
to escape it "correctly" is the wrong instinct — there is no spelling of
backslash-then-quote that satisfies YAML, bash and `split_args` simultaneously
without more cleverness than a log banner deserves.

**What this says about the checking, which is the useful part.** #143's lesson was
that `--syntax-check` is insufficient because it only parses files a playbook
reaches. This is the same lesson from the opposite direction: **raw YAML parsing
is insufficient too**, because this construct is *valid YAML*. It parsed fine in
check 1 and was caught only by check 2.

Neither check subsumes the other:

| | catches | misses |
|---|---|---|
| `yaml.safe_load` on every file | malformed YAML anywhere, including unreferenced files | anything valid as YAML but invalid to Ansible |
| `ansible-playbook --syntax-check` | Ansible-specific parse errors like this one | any file no play currently reaches |

Both are now in `ansible/syntax-check.sh`, along with a dedicated grep for
backslash-before-end-of-line-quote (check 6), because a targeted grep names the
offending line directly rather than dumping a 20-line shell body and pointing at
the task header.

**Scope check:** one occurrence in the repository, in code added this session.
Every other `shell:` block across the 46 files is clean.

## 145. #48 recurred — `connection: local` re-added to a new `hosts: localhost` play, breaking every delegated task in exactly the documented way

The first real run of `oem-repo-patch.yml --tags oem_repo_patch_preflight` got
past both syntax bugs (#143, #144), reached the trust play, resolved its pairs
correctly, and then died on the first delegated task:

```
TASK [ssh_equivalence : [oradbserv05 -> oemserver01] Ensure oracle's .ssh exists on the source]
fatal: [localhost -> oradbserv05]: FAILED! =>
  msg: Failed to set permissions on the temporary files Ansible needs to create
       when becoming an unprivileged user (rc: 1, err: chmod: invalid mode:
       'A+user:oracle:rx:allow')
```

**Cause: `connection: local` on the play.** Set explicitly at play level it pins
every task to a local connection, *including delegated ones* — `delegate_to` does
not override it, because Ansible only resolves a delegated task's connection from
the delegate's inventory vars when the play has not already pinned one, and
`oradbserv05` carries no explicit `ansible_connection` to win that argument.

So the task ran on the WSL2 control node while the output read
`[localhost -> oradbserv05]`. `chmod A+user:oracle:rx:allow` is Ansible's Solaris
ACL fallback, reached after `setfacl` failed, trying to hand a temp file to an
`oracle` user that does not exist on the controller. The error names a become
problem; the actual problem is that it never left the laptop.

**None of this was new.** It is `#48`'s third update, verbatim, and the fix — drop
the keyword, keep `hosts: localhost` — was already written out in comments above
**four** existing plays and roles: `gi_db_home_clone`, `dataguard_standby_prep`,
`dataguard_convert_rac`, and site.yml's Phase 4 play. `upgrade-19c-rolling.yml`'s
`cross_cluster_ssh_trust` play — the direct predecessor of the play that broke —
gets it right, with `hosts: localhost` and no `connection:` line.

**Why it recurred anyway, which is the part worth fixing.** Adding
`connection: local` under `hosts: localhost` is the *obvious* thing to write. It
reads as clarifying intent, and it is what most Ansible documentation shows for a
control-node play. The knowledge that it is wrong here lived only in comments
attached to the plays that already avoid it — so it was reachable when reading
existing code, and invisible when writing new code. A comment on the correct
implementations cannot warn the person writing a new one.

**Fixes:**

1. Dropped `connection: local` from `oem-repo-patch.yml`'s trust play, with the
   full reasoning inline rather than a cross-reference, so the next person editing
   *that* file sees it without needing to know #48 exists.
2. Added check 7 to `ansible/syntax-check.sh`: warn on any file containing both
   `connection: local` and `delegate_to`. A warning rather than a failure —
   `clone-node.yml` legitimately uses `connection: local` for VBoxManage and
   delegates nothing — and per-file rather than per-play, which the output says
   out loud so a WARN gets read rather than dismissed.

Audited at the same time: `clone-node.yml` is the only remaining
`connection: local` in the repository, and it is correct.

**The general lesson for this project's documentation habit.** Recording a trap
next to the code that avoids it is necessary but not sufficient — it documents the
cure where only the already-cured can see it. Traps that are easy to re-introduce
need a mechanical check, not just a comment. #143, #144 and #145 are all now greps
in `syntax-check.sh` for that reason.

## 146. Reviewing `oem_repo_patch` against this document — which should have happened before it was ever handed over — found four more issues, one of them a check that would have failed a successful backup

James's challenge after #145, and it is the correct one: *"if these issues are
already resolved in known-risks.md, why don't you check the doc to see if your
design has any issues we have fixed before submitting the files for execution?
We shouldn't be repeating issues we have spent hours debugging."*

Three consecutive failed runs (#143, #144, #145) on code written without once
consulting a 145-entry register of this project's own hard-won findings. #145 was
not merely documented — the fix was spelled out in comments above four separate
plays. The review below is what should have preceded the handover.

**1. `'RMAN-' in stdout` would have failed a healthy backup.** The RMAN backup
task failed the play if the substring `RMAN-` appeared anywhere in stdout. RMAN
emits informational `RMAN-08xxx` messages during entirely normal operation, so a
successful backup would have aborted the maintenance window — after the blackout
was up and the OMS was down, which is the worst possible place to stop.

This is #109's lesson exactly: check a positive completion marker, not the absence
of an error-shaped string, and confirm the thing being searched can actually reach
the stream being searched. Now requires `Recovery Manager complete.` and treats
only `RMAN-00569` — the header of RMAN's real error stack — as failure. A comment
warns against adding `log=` to the invocation without rewriting the condition,
since that is precisely what made #109 unfalsifiable.

**2. Six `sqlplus -s` calls, against a standing convention.** #80 records James
asking for full transcript-style output on every task, and states the rule for all
future phases: *"always full transcript-style output, always a `debug` task right
after, never silent."* `-s` dropped from all six.

Partially resolved, and recorded as such in
`docs/ansible-preflight-checklist.md`: dropping `-s` restores the banner, the
`SQL>` prompts and the results, but not the statement text, because #82 established
that `SET ECHO ON` does not echo heredoc stdin — only scripts run with `@`. Meeting
the convention fully means writing each block to a `.sql` file, as
`dataguard_primary_prep` does. Not done. Stated rather than quietly skipped.

**3. `groups['rac_nodes'][0]` in the role, `groups['rac_node1'][0]` in the
playbook.** Both resolve to `oradbserv05` today, so the trust would be established
from the host the copy then runs on — by coincidence, not construction. #61's bug
class. Unified on `rac_node1`.

**4. A partial-tag hazard** already covered under #142: `oem_repo_is_cdb` resolving
to a safe-looking `false` when its preflight source task had not run. Now fails
loudly.

**The process change, which is the actual point.** A checklist —
`docs/ansible-preflight-checklist.md` — grouped by play structure, shell/SQL\*Plus
construction, result checking, variables and tags, idempotency, and a handover
gate. Each item names the entry it comes from.

It exists because of #145's diagnosis: a trap recorded as a comment on the code
that avoids it is invisible to whoever writes the next role. Comments reach readers
of the cured; a checklist reaches the author of the next patient. Where a check can
be mechanised it belongs in `syntax-check.sh` instead — the checklist is for the
judgement calls that cannot be grepped.

**Honest scope note:** this review covered `oem_repo_patch`, `ssh_equivalence` and
`oem-repo-patch.yml` — the code written in this session. It is a read of the code
against the register, not a run. Items 1 and 3 are fixed and unverified; item 2 is
partially fixed by design and the remainder is recorded as an outstanding
deviation.

## 147. `delegate_to` resolved to the hostname "1" and Ansible tried to reach 0.0.0.1 — an inner `loop:` silently rebound `item` out from under the include's lazily-evaluated vars

The trust play got further than ever before: pairs resolved, the keypair was
found, the target's host keys were scanned. Then:

```
[WARNING]: The loop variable 'item' is already in use.
failed: [localhost -> 1] (item=|1|xp3QRk...=|FabD6r...= ecdsa-sha2-nistp256 AAAA...)
  msg: 'Failed to connect to the host via ssh: ssh: connect to host 0.0.0.1 port 22: Connection refused'
fatal: [localhost -> {{ ssh_pair_source }}]: UNREACHABLE!
```

Two tells in that output. Ansible is delegating to a host literally named `1`
(resolved as `0.0.0.1`), and the final line reports the delegate as the raw,
un-rendered string `{{ ssh_pair_source }}`.

**Root cause.** `configure.yml` loops over user × pair and passes the parts into
`pair.yml` as include vars:

```yaml
  include_tasks: pair.yml
  vars:
    ssh_pair_source: "{{ item.1.0 }}"
  loop: "{{ ssh_equiv_users | product(ssh_equiv_pairs) | list }}"
```

Those vars are **lazy** — re-evaluated at each point of use inside `pair.yml`, not
captured once at include time. And the known_hosts task inside `pair.yml` has a
`loop:` of its own, over `ssh-keyscan` output lines. For the duration of that task,
`item` is the keyscan line.

So `ssh_pair_source` was re-evaluated as `"<keyscan line>.1.0"`. Jinja does not
object: `item[1]` on that string is the character `1`, and `'1'[0]` is `'1'`.
`delegate_to` therefore received `"1"`, which Ansible resolved to `0.0.0.1`.

Every earlier task in `pair.yml` worked precisely because none of them has an inner
loop — `item` still held the outer element, so `.1.0` gave `oradbserv05` as
intended. The failure appears at the first inner loop and nowhere before it. Ansible
does warn, but only as a WARNING, and then does the wrong thing anyway.

**Fix:** `loop_control: loop_var: ssh_equiv_item` on the include, with the three
vars, the label and the `when:` all switched to it. Now nothing an included task
does to `item` can reach them.

**James's question was the right one:** *"you did this 05 to 09 and copied files
over. What is the difference here?"*

The difference is the generalisation, and it is worth being precise rather than
defensive about it. `cross_cluster_ssh_trust` handled exactly one pair and one
user. It had no outer loop, so `item` inside it always belonged to whichever inner
loop was running, and there was nothing to collide with. Parameterising the role
over (users × pairs) — the right change, and the one James asked for — introduced
an outer loop, and with it a variable-shadowing hazard that simply did not exist in
the code being replaced.

That is a normal cost of generalising: the new failure modes are not in the diff,
they are in the interaction between the new structure and code that was already
there. The lesson is not "do not generalise" — it is that a rewrite from
"one hardcoded case" to "a loop over cases" should be reviewed specifically for
what the new loop shadows.

**Mechanised** as check 8 in `ansible/syntax-check.sh`: any `include_tasks` /
`include_role` / `import_tasks` carrying a `loop:` without a `loop_var:` fails the
check. This is the fourth defect in this sequence (#143, #144, #145, #147) to
become a grep rather than only a comment, which is the pattern #145 argued for.

**Note for the next role in this project that uses this pattern:** the include-with-
lazy-vars idiom is common here. Any role passing `vars:` derived from `item` into an
included file is exposed to this the moment someone adds a loop inside that file —
even years later, even in a task unrelated to the vars. `loop_var` on every looping
include is cheap insurance, which is why the check fails rather than warns.

## 148. `become: false` on the patch play meant every task ran as the login user — and fixing it exposed two more identity bugs that had not run yet

With #147 fixed, the SSH trust play succeeded end to end for the first time
(`oracle@oradbserv05 -> oemserver01: OK`). The second play then failed on its
first real task:

```
TASK [oem_repo_patch : Ensure the log and staging directories exist]
failed: [oemserver01] (item=/u01/app/oracle/logs/oem_repo_patch)
  msg: 'There was an issue creating /u01/app/oracle/logs as requested:
        [Errno 13] Permission denied'
```

**Cause.** The play carried `become: false`, so every task ran as the `ansible`
login user, which owns nothing under `/u01/app/oracle`.

`become: false` was there to stop `ansible.cfg`'s global `become = True` /
`become_user = root` from running the whole role as root — a real concern, since
OPatch and datapatch run as root leave root-owned files scattered through the
Oracle home and inventory. But the correction to "not root" was made without
asking the actual question, which is *which* user this work belongs to. The answer
is `oracle`, and the play now says so: `become: true` with
`become_user: "{{ oracle_user }}"`. Same pattern `dataguard_fsfo` already uses
successfully against this host.

Had the directory task somehow succeeded, the failure would simply have moved
later and got worse — `sqlplus / as sysdba`, `opatch`, `rman` and `emctl` all
require being the software owner, not merely able to execute the binary.

**Two consequential bugs, found by asking what else the change affects rather than
by running it.**

**1. Two tasks needed `become_user: root` stating explicitly.** `opatchauto` and
the `extjob` permission fix both carried a bare `become: true`, which meant root
while the play defaulted to root. With a play-level `become_user: oracle`, a bare
`become: true` now means *become oracle*. `opatchauto` would have failed on
privilege; worse, the `extjob` task also carries `failed_when: false`, so oracle
failing to `chown` a file to root would have been **swallowed silently** — leaving
`extjob` wrong in precisely the way that task exists to prevent, and reporting
success. Both now say `become_user: root`.

**2. `synchronize` had to go, and should never have been there.** The two
cross-cluster copy tasks used `ansible.posix.synchronize`. Two independent
problems:

- **It contradicts an explicit project decision** — one recorded in
  `ssh_equivalence`'s own header, which *this same session wrote*, and in
  `db19c_software_install`'s cross-cluster copy: this project deliberately does not
  depend on ansible.posix, and invokes the real `rsync` binary through
  `command`. The comment was written in one role and violated in its sibling.
- **`synchronize` resolves the remote-side user from the inventory host's
  connection user, not from `become_user`.** Under the new play identity it would
  still have attempted `ansible@oemserver01:` — against a trust that exists for
  `oracle` only. The copy would have failed on authentication, pointing at the
  trust, which had just been proven working. That is an expensive diagnosis.

Both replaced with the explicit form `db19c_software_install` uses and has had
working on these hosts since 2026-08-21, plus a result-reporting `debug` task each
(#80's convention). Deliberately *not* `failed_when: false` the way that role's
version is — it has a controller-routed fallback to fall back to, and this one does
not, so a failed copy must stop the run.

**What this sequence says.** #146 reviewed the code against this register and found
four issues. It did not find these three, because they are not visible in a static
read of the role alone — they only appear once you ask what identity each task runs
under, and compare that against a sibling role's stated conventions. A checklist
catches recurring traps; it does not substitute for reading the neighbouring code
that already solved the same problem. `db19c_software_install` had the answer to
the cross-cluster copy question the entire time.

## 149. `ssh-keyscan -H` made the trust rebuild itself on every run, and `dba_registry_sqlpatch` has no `version` column — both found by the first successful preflight

The first clean preflight run. Two defects it surfaced, plus a design change James
asked for on the back of one of them.

**1. `ORA-00904: "VERSION": invalid identifier`.** The pre-patch baseline's
`dba_registry_sqlpatch` query selected a `version` column. That view has no such
column — it has `ru_version` and `source_version`, and the column that belongs in a
patch summary is `patch_type` (INTERIM vs RU). James supplied the corrected query
directly. Applied to both the pre-patch baseline and the post-patch verification,
which carried the identical block.

Worth noting what this cost: nothing yet, but the post-patch half of the same query
runs *after* the RU is applied, at the point where the run is deciding whether the
dictionary patch registered as SUCCESS. The error would have surfaced mid-window,
with the OMS down, on a query whose whole purpose is to tell you whether it is safe
to bring the OMS back up.

**2. The SSH trust rebuilt itself on every single run.** The known_hosts task
reported `changed` on all six key lines each time, even immediately after a
successful run.

Cause: `ssh-keyscan -H`. The `-H` flag hashes the hostname field with a **random
salt**, so the same host and the same key produce *different text* on every
invocation. `lineinfile` therefore never matched what was already in the file,
appended six more lines, and reported changed — every run, forever, with
`known_hosts` growing without bound.

Dropped `-H`. Unhashed entries are stable text, so `lineinfile` is genuinely
idempotent. Hashing only obscures which hosts a user has connected to, which buys
nothing on a lab whose entire inventory is committed to this repository.

**3. James's design correction, which is the durable part.** Seeing the rebuild, he
asked for the obvious structure the role did not have:

> *"Does it have to do this all the time? Can it check for the SSH first before
> setting up if missing? It is always a 3 step process. 1. Check first if not there
> or not configured 2. then do it and 3. check to make sure that it is done."*

`pair.yml` is now exactly that. Step 1 runs
`ssh -o BatchMode=yes <target> hostname` as the target user. If it returns 0 the
entire setup block is skipped. Step 2 runs only on failure. Step 3 runs the same
command again unconditionally and records the result.

Two details that make it honest rather than decorative:

- **The check is a real connection, not a file inspection.** Whether
  `authorized_keys` contains the right line is a proxy; whether the SSH actually
  opens is the thing itself. `BatchMode=yes` is what makes it a test rather than a
  hang — it refuses to prompt, so an unconfigured trust fails in five seconds
  instead of blocking on input that can never arrive (the #6 hang, in miniature).
- **The stale `.ssh/config` cleanup is deliberately NOT gated on the pre-check.**
  A config containing `UserKnownHostsFile /dev/null` (#63) still *passes* the
  pre-check — `StrictHostKeyChecking no` plus `/dev/null` connects fine, just
  noisily and without persisting anything. So the pre-check cannot detect that
  state, and the cleanup has to run either way.

The role now also prints a one-line summary — how many pairs were already
configured versus built this run — so "did it rebuild everything again?" is
answerable from the output rather than by reading six `changed` lines.

**The general point.** An idempotency bug and a missing guard look like the same
symptom (`changed` on every run) and are not the same defect. `-H` was the bug;
check-first is the design. Fixing only the guard would have hidden the growing
`known_hosts` behind a skip, and fixing only `-H` would have left the role
rebuilding a working trust from scratch every time. Both were real.

**CONFIRMED 2026-08-31 — the rebuild path, tested properly.** James restored
`oemserver01` from a snapshot, wiping its configuration including
`/home/oracle/.ssh/authorized_keys`, specifically to see whether the role would
recover on its own. It did:

```
TASK [ssh_equivalence : CHECK  oracle@oradbserv05 -> oemserver01]
  -> NOT configured, will set up
  rc=255 — Permission denied (publickey,gssapi-keyex,gssapi-with-mic,password)
...
TASK [ssh_equivalence : [oemserver01] Authorise oradbserv05's oracle key]
changed
TASK [ssh_equivalence : VERIFY oracle@oradbserv05 -> oemserver01]
  OK — oemserver01.usat.com [newly configured this run]
  1 pair(s) checked — 0 already configured (setup skipped), 1 built this run.
```

Worth noting how much better that test is than a re-run against an untouched host.
A re-run only ever exercises the skip path; wiping the target is the only way to
exercise the *rebuild* path, which is the one that matters when a node is rebuilt
or recloned. Both halves now need to hold, and only one of them has been proven —
the skip path (pre-check passes, setup skipped, zero changes) is still unverified
and should be confirmed on the next run against the now-configured host.

It also cost a false diagnosis first: the failure was read as a defect —
"the trust did not survive between runs" — because the preceding run had ended
with it working and nothing in the automation explained the regression. The
explanation was outside the automation entirely. **When state changes between runs
and nothing in the code accounts for it, ask what happened to the host before
theorising about the code.**

The pre-check now classifies its own failure (`Permission denied (publickey` →
target's `authorized_keys` and home/.ssh permissions; `Host key verification
failed` → source's `known_hosts`; `Connection refused` → not a trust problem),
which is what made the cause legible here in one line.

## 154. A real `failed_when` on a LOOPED task failed against directories that plainly existed — twice — and this project already had a convention that avoids the question entirely

Staging the OJVM+DBRU combo unzipped correctly, and the verification task then
failed both iterations with the evidence of success in its own output:

```
failed: [oemserver01] (item=.../39618649/39472050) => changed=false
  failed_when_result: true
  stat:
    isdir: true
```

Two attempts, both wrong:

```yaml
failed_when: not (oem_combo_components.stat.isdir | default(false))
# register is not assigned until the whole loop finishes, and then as
# .results — so this resolved false every iteration, and `not false` failed.

failed_when: not (stat.isdir | default(false))
# also failed, with stat.isdir: true visible in the result.
```

The second is the form the documentation implies should work, and it did not.
Rather than attempt a third guess at what is in scope inside a loop-scoped
conditional, the check moved out of the loop.

**The cross-check is the point of this entry.** Asked to review history before
guessing again, a grep for `.results |` found that **this project has had a
settled convention for exactly this since early on, used in at least eight
roles** — `os_prep`, `db19c_software_install`, `asmlib_disks`,
`dataguard_role_services`, `dataguard_net_config`, `dataguard_switchover_test`,
`rolling_postupgrade`, `ssh_equivalence`:

```yaml
- name: <looped check>
  command: ...
  register: chk_thing
  changed_when: false
  failed_when: false          # never a real condition on the looped task
  loop: [...]

- name: <act or fail on the outcome>
  when: chk_thing.results | rejectattr('rc', 'equalto', 0) | list | length > 0
```

`rolling_postupgrade`'s preflight is the closest analogue to what was needed
here, evaluating `(<reg>.results | selectattr(...) | first).stdout` in a `fail`
task *after* the loop. **Nowhere in this codebase is there a meaningful
per-iteration `failed_when` on a looped task referencing module output.** The
construct that failed twice is one this project had already, implicitly, decided
not to use.

It also rhymes with #97, #99 and #130, which all concluded the same thing from a
different direction: do not encode the verdict in a task's own exit condition
where you cannot see what is being tested — register the result and evaluate it
explicitly, in the open, afterwards.

**Fix:** `failed_when` removed from the looped `stat`; a `debug` reports
present/MISSING per directory, and a separate `fail` task evaluates
`oem_combo_components.results | map(attribute='stat.isdir', default=false)`. The
`default=false` matters: for a path that does not exist, `stat` returns
`exists: false` and carries no `isdir` key at all, so the lookup raises rather
than returning false without it.

**Standing rule, now in `docs/ansible-preflight-checklist.md`:** a looped task
gets `failed_when: false`; the verdict goes in the next task, against `.results`.

---

## 155. Grepping datapatch's logs for `ORA-` produced ~300 hits on a completely successful patch — the check was noise, and noise is worse than no check

**Where:** `roles/oem_repo_patch/tasks/main.yml`, the post-datapatch log task;
`monitoring/phase-7a-part3-verification.md` §16 check 4.

**What I wrote:**

```bash
grep -Rn -E "ORA-[0-9]{5}|SP2-[0-9]{4}|Error" ${LOGDIR} || echo "no lines found"
```

It reads like due diligence. On the 2026-09-04 run — a patch that succeeded on
every other measure, `failed=0`, invalid objects 2 → 0 — it emitted roughly
three hundred matching lines, and not one of them indicated a problem.

**Why every hit was noise.** Oracle's own RU scripts are full of `ORA-` text
that has nothing to do with a failure:

- `IGNORABLE ERRORS: ORA-00955` and similar are *declarations at the top of the
  script*, telling the harness which errors to expect and swallow. The string
  `ORA-00955` appearing in a log is the script working as designed.
- `ORA-00955: name is already used by an existing object` is raised and caught
  by design on every `CREATE` for an object that already exists — which, in an
  RU applied to an existing database, is most of them.
- `ORA-` codes appear in comments and in error-handler text that never fired.

**The deeper problem.** A check that fires three hundred false alarms does not
degrade to a useless check — it degrades to a *harmful* one, because the next
person scrolls past the block, and the run where one of those lines is real
looks exactly like this one. Same failure mode as #153, where my apostrophe
check produced 139 false positives and would have been ignored within a day.
The cost of a noisy check is not the noise. It is the real finding you will
miss inside it.

**Fix:** the grep is gone. Datapatch already validates its own logfiles and
prints a verdict per patch:

```
Patch 39472050 apply: SUCCESS
  logfile: .../39472050_apply_OEMCDB_2026Sep04_07_10_39.log (no errors)
```

`(no errors)` is the authoritative signal and it comes from the tool that knows
which errors it declared ignorable. The task now lists the log *locations* only,
with a comment explaining why it deliberately does not grep them — so that
somebody reading it does not helpfully add the grep back.

**Standing rule:** before adding a check, estimate its false-positive rate on a
*known-good* run. If you cannot, run it against one before you ship it. Prefer a
verdict emitted by the tool that did the work over a pattern you invented to
second-guess it.

---

## 156. The fix for #155 reintroduced #153's bug two lines away from the comment explaining it — and `syntax-check.sh` printed `FAIL` and `ok` for the same check

**Where:** `roles/oem_repo_patch/tasks/main.yml`, the "Locate the datapatch apply
logs" task; `syntax-check.sh` checks 2 and 9.

Three separate defects, found in one run. Worth keeping together because they
share a shape: **every one of them is a check or a fix that misreports.**

### 156a. An apostrophe inside a `shell:` block, in the comment explaining #155

The #155 fix replaced a noisy grep with a comment explaining why the grep was
gone. The comment was written *inside* the `shell: |` block and contained:

```
# The authoritative verdict is datapatch's OWN log validation, which it prints
```

`datapatch's`. One apostrophe, odd count, inside a free-form module argument.
Ansible's `split_args` counts quote characters across the whole block, so that
single character unbalances the task and the playbook fails to parse — exactly
#144 and #153, in a comment whose subject was being careful.

**What makes this entry worth writing rather than just fixing:** the rule was
already known, already documented, and already had a check. Knowing a rule does
not apply it. The check did.

**Fix:** the prose moved to a **task-level YAML comment**, above `shell:`, which
is stripped before templating and is therefore safe at any length with any
punctuation. The shell block keeps one plain `echo`. A note in that comment now
tells the next editor why the prose lives where it does.

### 156b. `$?` after a `||` compound is always 0

`syntax-check.sh` check 9 reported the apostrophe correctly, then printed
`ok none found` on the very next line:

```
   FAIL  roles\oem_repo_patch\tasks\main.yml:1935: ...
   checked, 1 issue(s)
   ok    none found
```

The cause:

```bash
python3 - <<'PY' || FAILED=1
...
PY
[ $? -eq 0 ] && ok "none found"       # WRONG
```

`$?` there is not python's exit status. It is the status of the whole
`cmd || assignment` compound, and the assignment always succeeds, so `$?` is
**always 0** and the `ok` always fires. The overall gate still worked — `FAILED`
was set, and the run ended with `FAILURES ABOVE` — but the per-check line said
both things at once.

**Fix:**

```bash
python3 - <<'PY'
...
PY
rc=$?
if [ "$rc" -eq 0 ]; then ok "none found"; else FAILED=1; fi
```

Capture the status on its own line before anything else runs. Same class as
#109: gate on a positive marker rather than on something adjacent to it.

### 156c. A missing dependency reported as six playbook failures

Run from Git Bash / MINGW64 on the Windows side instead of from WSL2,
`syntax-check.sh` produced:

```
   FAIL  site.yml
         syntax-check.sh: line 79: ansible-playbook: command not found
   FAIL  oem-repo-patch.yml
   ... four more identical ...
FAILURES ABOVE — do not run the playbook yet.
```

Six red failures and a red banner, none of which said anything about the
playbooks. The script already handled a missing PyYAML gracefully with a `SKIP`
and an explanation; it did not extend the same courtesy to a missing
`ansible-playbook`.

**Fix:** `command -v ansible-playbook` gates the loop, and its absence prints a
`SKIP` naming the WSL2 path where ansible actually lives.

**The connecting rule, and it is the same one as #155:** a check that reports a
red failure for its own missing dependency, or that reports two verdicts at once,
teaches the reader to stop believing the banner. The cost is not the noise. It is
the real failure that goes unread inside it.
{% endraw %}
