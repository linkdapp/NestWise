---
title: "Phase 0/1 — Foundation + 2-Node RAC on Oracle 12.2.0.1"
generated: 2026-08-06
status: "built — RAC cluster up, apexdb (General Purpose, non-CDB) created and validated across both nodes"
---

# Phase 0/1 — Foundation + 2-Node RAC (12.2.0.1)

This folder is the Ansible/scripts layer that builds the first real piece of the Road to
OracleOCM stack: a golden-image-and-clone pair of Oracle Linux 7 nodes
(`oradbserv05`/`oradbserv06`), patched Grid Infrastructure + Database homes installed
silently, ASMLib-backed shared storage, real DNS (BIND) for SCAN, a dedicated chrony
time source, and a **General Purpose, non-CDB** database created across the 2-node RAC
cluster via silent DBCA. Data Guard, GoldenGate, TDE/audit, and the 19c/26ai upgrades
are later phases — this one stops at "RAC cluster up, one non-CDB database running on
it." The full step-by-step SOP (with exact commands and screenshot callouts) lives in
[`../installation/README.md`](../installation/README.md); this file covers the
decisions and file map.

Read **[`docs/known-risks.md`](docs/known-risks.md) first.** The OS choice (OL7) is
right for this phase and Phase 2 (Data Guard, GoldenGate — still 12c/19c-era), but
isn't certified for the later 26ai upgrade — that's a planned, budgeted migration, not
a surprise; see `docs/known-risks.md` #1. New to how this repo's Ansible is actually
organized, or trying to figure out what a failed task really did?
[`docs/ansible-architecture-and-debugging.md`](docs/ansible-architecture-and-debugging.md)
covers both — architecture, and every debugging/logging tool available.

## Decisions locked in this phase

| Decision | Value |
|---|---|
| Hostnames | `oradbserv05.usat.com` (node 1), `oradbserv06.usat.com` (node 2) |
| Cluster shape | 2-node RAC, admin-managed (not policy-managed), cluster name `usatclust1` |
| Build strategy | `oradbserv05` built by hand, verified with Ansible (`verify_baseline`), then cloned via an Ansible-driven `VBoxManage clonevm` to produce `oradbserv06`, personalized over the console, verified again — no separate throwaway template VM. See `docs/golden-image-and-cloning.md` |
| Network | 3 NICs per node: NAT (admin), Host-Only Adapter (public cluster, static IP), Internal Network `intnet` (private interconnect, static IP — the name string must match exactly on both VMs, see `docs/known-risks.md` #11) — see `docs/network-and-hosts.md` |
| Storage | Classic ASMLib v2 — 6× 50GB shared, fixed disks (`ASMDISK01`-`06`), exposed via `/dev/disk/by-label/` (a generic udev mechanism, not ASMLib-specific — see `docs/known-risks.md` #4). `DATA01`: 3 disks, `NORMAL` redundancy. `DATA02`/`RECO01`: 1-2 disks each, `EXTERNAL` |
| OCR / voting / GIMR | OCR multiplexed to `DATA01`+`DATA02` (`ocrconfig -add`); `DATA01` is `NORMAL` redundancy — 3 real voting files across 3 failure groups, a deliberate choice to demonstrate the voting-quorum mechanism (see `docs/known-risks.md` #9); GIMR disabled (lab-scale resource tradeoff) |
| Name resolution | BIND DNS — `oradbserv05` primary NS, `oradbserv06` secondary, real 3-IP round-robin for SCAN (`scan-usatclust1`) |
| Time sync | chrony — `oemserver01` (192.168.56.65) is the local stratum-10 master, both RAC nodes are clients |
| OS | Oracle Linux 7 — right for this phase and Phase 2; not certified for 26ai, so an OS migration is planned before that upgrade phase. See `docs/known-risks.md` #1 |
| Grid Infrastructure | **19c** (19.3 base + RU 19.24), not 12.2.0.1 — a deliberate, independent-version design (GI and DB homes are fully independent, a normal supported Oracle pattern); see `docs/known-risks.md` #2 |
| GI install sequencing | **Two-phase**: Phase A software-only install (`CRS_SWONLY`, patched via `-applyRU`) + root scripts, then Phase B cluster configuration (`CRS_CONFIG` via `config.sh`, not `gridSetup.sh`) + root scripts again — a real two-phase run is what got a live install past `INS-32022`/`INS-32047` cleanly; see `docs/patching-strategy.md` |
| Preinstall | `oracle-database-preinstall-19c` (GI layer, primary — Oracle's post-18c flat naming convention) + `oracle-database-server-12cR2-preinstall` (DB layer, older naming) — both natively available via yum on OL7 |
| Directory layout | OFA: `ORACLE_BASE=/u01/app/oracle`, shared by both `oracle` and `grid`, `ORACLE_HOME=/u01/app/oracle/product/12.2.0/db_1`, `GRID_HOME=/u01/app/grid/19.3.0` (a separate top-level path, not nested under the shared base), staging at `/u01/app/oracle/staging` |
| Patch policy | GI and DB homes are patched **before** any configuration step runs (root scripts / DBCA) — see `docs/patching-strategy.md` |
| Target database | General Purpose template, **non-CDB** (`-createAsContainerDatabase false`), `AL32UTF8`, DB software stays 12.2.0.1 even though GI is 19c |
| Software delivery | 100% silent — no `xhost`/VNC, no interactive OUI or DBCA screens |

## Why non-CDB in a 12.2 build

12.2.0.1 is the last release where a non-CDB target is still fully supported end-to-end —
19c still allows creating one but flags it as deprecated, and it's gone entirely by 23ai/26ai.
Building non-CDB here, then converting to CDB/PDB as part of the Phase 4 (12c→19c)
upgrade with `dbupgrade`/`noncdbtopdb.sql`, is itself a demoable showcase moment that a
straight CDB-from-day-one build would skip. If that's not the intent, flag it — swapping
the DBCA template to `General_Purpose.dbc` with `-createAsContainerDatabase true` is a
one-line change in `ansible/roles/dbca_noncdb/templates/dbca_gp_noncdb.rsp.j2`.

## Directory map

```
phase-01-foundation-2node-rac-12cR2/
├── README.md                          (this file)
├── docs/
│   ├── known-risks.md                 OS certification boundary, build-time gotchas worth knowing up front
│   ├── network-and-hosts.md           hostnames, 3-NIC design, BIND zone, chrony topology, standby cluster addressing
│   ├── golden-image-and-cloning.md    build oradbserv05 by hand, verify, clone via VBoxManage, personalize, verify again
│   ├── ansible-on-windows.md          WSL2 setup for running this repo's playbooks from Windows
│   ├── patching-strategy.md           patch-before-configure workflow, RU numbering caveat
│   └── ansible-architecture-and-debugging.md   what each ansible-playbook command/role
│                                       actually does, plus every tool (Ansible's and this
│                                       repo's own) for seeing what a run actually did
├── ansible/
│   ├── ansible.cfg
│   ├── site.yml                       top-level playbook, runs roles in build order
│   ├── inventory/hosts.ini
│   ├── group_vars/all.yml             shared vars: hostnames, network, OFA paths, ASM disks, versions
│   └── roles/
│       ├── os_prep/                   preinstall RPM, kernel/sysctl, io-scheduler, limits, sudo, OFA dirs
│       ├── verify_baseline/           assertion checks — confirms a node matches what os_prep should have produced
│       ├── dns_bind/                  BIND primary (oradbserv05) + secondary (oradbserv06), SCAN 3-IP zone
│       ├── chrony/                    OEM VM as local time master, RAC nodes as clients
│       ├── asmlib_disks/              ASMLib service config + shared-disk marking/discovery
│       │                              (packages install via os_prep, see docs/known-risks.md #21)
│       ├── ssh_equivalence/           passwordless SSH for grid/oracle across both nodes —
│       │                              required by cluvfy AND gridSetup.sh/runInstaller's
│       │                              own node propagation, see docs/known-risks.md #6
│       ├── patch_before_config/       stages RU, patches GI/DB homes before any config step
│       ├── grid_silent_install/       two-phase GI: stage+install software, then configure the cluster, then DATA02/RECO01 diskgroups (tags: grid_infrastructure / grid_stage / grid_install_software / grid_configure_cluster / grid_storage)
│       ├── db_silent_install/         two-stage DB: stage software, then install (tags: db_software / db_stage / db_install_software)
│       └── dbca_noncdb/               silent DBCA build of the General Purpose non-CDB RAC database
├── response-files/                    standalone copies of the .rsp files (edit-and-run, no Ansible needed)
│   ├── grid_install.rsp
│   ├── db_install.rsp
│   └── dbca_gp_noncdb.rsp
└── scripts/
    ├── vm-tuning-vboxmanage.ps1        host-side (Windows) VM tuning + storage provisioning
    └── vm-tuning-vboxmanage.sh         host-side (macOS/Linux) equivalent
```

`ansible/clone-node.yml` (top-level playbook, not a role) runs against the control node
itself and drives the `VBoxManage clonevm` step — see `docs/golden-image-and-cloning.md`.

## Build order

Full command-by-command version: [`../installation/README.md`](../installation/README.md).
Short version:

1. Install Oracle Linux 7 on `oradbserv05` by hand (real hostname/IPs, `sshd` enabled) —
   no Ansible involved yet.
2. Create the `ansible` managed-node user on `oradbserv05` (passwordless sudo), then
   set up the Ansible control node (WSL2) and confirm connectivity with `ansible ...
   -m raw -a "echo pong"` — plain `-m ping` fails on a fresh OL7 node until `python3`
   is installed (see `docs/known-risks.md` #17); `site.yml`'s bootstrap play handles
   that automatically starting with step 3, so this raw check is only needed before
   any tagged play has run. See `docs/ansible-on-windows.md`. This has to happen
   before step 3; nothing can SSH in as `ansible` before the account exists.
3. Stage `oracleasmlib-2.0.15-1.el7.x86_64.rpm` at `/root/rpms/` on `oradbserv05`
   first (`scp`/manual download from oracle.com/linux/downloads) — `os_prep` installs
   ASMLib packages as part of the golden image now, and `oracleasmlib` isn't reliably
   on OL7's public yum channels (see `docs/known-risks.md` #21). Then run `--tags
   os_prep --limit oradbserv05`, then `--tags verify_baseline --limit oradbserv05` —
   don't proceed until that passes.
4. Power off `oradbserv05`, clone it: `ansible-playbook clone-node.yml -e
   source_vm=oradbserv05 -e target_vm=oradbserv06` (`docs/golden-image-and-cloning.md`).
   The clone carries the `ansible` account over automatically.
5. Personalize `oradbserv06` over the VirtualBox console (hostname/IPs/machine-id/SSH
   host keys — NOT SSH, it's still network-identical to node 1 at this point), then
   power `oradbserv05` back on. Verify: `--tags verify_baseline --limit oradbserv06`.
6. Host side: `scripts/vm-tuning-vboxmanage.ps1 -VMS oradbserv05,oradbserv06 -AttachSharedAsmDisks`
   for the `/u01` disk and the 6 shared ASM disks.
7. `--tags dns_bind`, then `--tags chrony`, then `--tags asmlib_disks` — verify SCAN
   round-robins, chrony syncs, and `oracleasm listdisks` sees all 6 disks before moving on.
8. `--tags ssh_equivalence` — passwordless SSH for `grid`/`oracle` across both nodes.
   Genuinely required before the next step, not optional: the Grid Infrastructure
   `cluvfy` check (and `gridSetup.sh` itself, right after) hangs with zero output,
   indefinitely, without this — see `docs/known-risks.md` #6.
9. Stage GI/DB media + the target RU, then `--tags patch_before_config,grid_infrastructure,db_software`.
10. Run GI root scripts manually in node order (`grid_silent_install`'s task comments
    spell out the exact sequence — Phase A root scripts, then Phase B config.sh, then
    Phase B root scripts), then re-run `--tags grid_infrastructure` after each manual
    step — its idempotency guards (`docs/known-risks.md` #14) skip whatever's already
    done and fall through to the next stage, eventually creating `DATA02`/`RECO01`.
11. `--tags dbca_noncdb` from `oradbserv05` only.
12. Validate: `crsctl stat res -t`, `srvctl status database -d apexdb` (run as `oracle`,
    using db_home's `srvctl` — see `docs/known-risks.md` #44), confirm
    `V$DATABASE.CDB = 'NO'`.

## What's next

Data Guard broker + Fast-Start Failover and GoldenGate Classic land in Phase 2 against a
second RAC cluster (`usatclust2`, nodes `oradbserv07`/`oradbserv08` — addressing already
documented in `docs/network-and-hosts.md`), per
[`../02-roadmap-skeleton.md`](../02-roadmap-skeleton.md). Swingbench load generation and
an AHF compliance baseline (pre-patch and post-patch) belong in this phase too before
calling it "done" for the showcase post — neither is wired up yet in this folder.
