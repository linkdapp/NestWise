# Network design, DNS (BIND), and chrony

Single VirtualBox host, two guest RAC nodes, plus the project's existing OEM VM acting
as the chrony time master. This design was adapted from a previously working BIND +
chrony lab setup rather than written from scratch — the mechanics (zone file shape,
SCAN's 3 `A` records, chrony's local-stratum-10 pattern, the 3-NIC-per-node layout) are
carried over directly from that reference.

## Adapters per node — 3 NICs, not 2

Each RAC node VM has **three** VirtualBox network adapters, each with a distinct role.
Getting this right in VirtualBox's VM settings (or via `vm-tuning-vboxmanage`) before
first boot matters — retrofitting adapter types after OS install means redoing the
`ifcfg`/`nmcli` config too.

| Adapter | Interface (OL7 uses classic `eth`-style naming, not `enp0sN`) | VirtualBox type | Role | Config |
|---|---|---|---|---|
| NIC1 | eth0 | NAT | Admin/internet access only — not part of the Oracle network design | DHCP, connect automatically |
| NIC2 | eth1 | Host-Only Adapter | **Public cluster network** | Static IP (see table below), netmask 255.255.255.0, gateway 192.168.56.1, DNS search domain `usat.com`, connect automatically |
| NIC3 | eth2 | Internal Network (`intnet`) | **Private cluster interconnect** | Static IP (see table below), netmask 255.255.255.0, no gateway, no DNS, connect automatically |

The private interconnect (eth2) is intentionally non-routed — no gateway, both nodes
on the same VirtualBox internal network name, matching Oracle's requirement that the
interconnect not be reachable from outside the cluster.

**The internal network NAME must be the exact same string on both VMs — VirtualBox
does not validate or warn if it isn't.** A lone VM on an internal network with zero
other members still reports a live link (`UP`/`LOWER_UP`, no `NO-CARRIER`) to its own
kernel, even with no peer attached — VirtualBox only actually bridges two adapters
together when their internal network name strings match exactly, so a divergent name
on one VM looks completely normal from inside either guest OS. The symptom, if it ever
happens, is `ping`/`ssh` between the two private IPs failing with "Destination Host
Unreachable" in both directions, and Grid Infrastructure's `cluvfy` sanity check
hanging as a result — see
[`known-risks.md`](known-risks.md) #11. `intnet` (VirtualBox's own default) is what
this project standardizes on for both VMs — not a custom name — specifically to remove
any hand-typed-string divergence risk.

**NIC emulation type: virtio-net, not Intel PRO/1000.** Both the Host-Only (eth1) and
Internal Network (eth2) adapters use VirtualBox's paravirtualized `virtio-net` device
(`--nictype2/3 virtio`), not the Intel PRO/1000 MT Server (`82545EM`) emulation.
`82545EM` has known stability issues under VirtualBox for sustained interconnect-style
traffic; `virtio-net` has lower emulation overhead, and the guest kernel has the
`virtio_net` driver built in, so no extra guest driver install is needed. Confirm after
tuning with `ip a` / `ethtool -i eth1` inside the guest — it should report the
`virtio_net` driver.

**Benign warning to expect:** `VBoxManage modifyvm ... --hostonlyadapter2 "VirtualBox
Host-Only Ethernet Adapter"` sometimes prints `warning: Interface "VirtualBox Host-Only
Ethernet Adapter" is of type bridged` on Windows hosts. This is a known, cosmetic
mismatch in VBoxManage's own interface-type check — it does not override the explicit
`--nic2 hostonly` setting that's actually applied. Verify the real configuration
instead of trusting the warning text: `VBoxManage showvminfo <vm> | findstr NIC` (or
`| grep ^NIC` on macOS/Linux) should show NIC 2 as `Host-only Adapter`. Both tuning
scripts print this automatically after configuring each VM. If it genuinely does come
up bridged, the fix is to recreate the Host-Only network via VirtualBox's Host Network
Manager (or `VBoxManage hostonlynet` on VirtualBox 7.x, which changed how Host-Only
networking is managed) rather than fighting the `--hostonlyadapter2` flag.

## Hostnames and IPs — primary cluster (usatclust1, built by this phase)

| Role | Hostname | IP | Interface |
|---|---|---|---|
| OEM VM (chrony master) | oemserver01 | 192.168.56.65 | existing lab VM, not built by this phase |
| Node 1 public | oradbserv05 | 192.168.56.181 | eth1 |
| Node 1 private | oradbserv05-priv | 192.168.2.181 | eth2 |
| Node 1 VIP | oradbserv05-vip | 192.168.56.191 | (VIP, GI-managed) |
| Node 2 public | oradbserv06 | 192.168.56.182 | eth1 |
| Node 2 private | oradbserv06-priv | 192.168.2.182 | eth2 |
| Node 2 VIP | oradbserv06-vip | 192.168.56.192 | (VIP, GI-managed) |
| SCAN | scan-usatclust1 | 192.168.56.201 / .202 / .203 | 3 `A` records, same name |

`oradbserv05` is the BIND primary and `oradbserv06` the secondary — no separate DNS VM
needed, matching the reference setup. Domain: `usat.com`.

## Standby cluster (usatclust2) — Phase 2 addressing, documented now, not built yet

The Data Guard phase targets a second, independent 2-node RAC cluster (RAC-to-RAC Data
Guard, not RAC-to-single-instance). Addressing is captured here so it isn't lost before
that phase starts — **none of this is provisioned by phase-01's playbooks.**

| Role | Hostname | IP | Interface |
|---|---|---|---|
| Node 1 public | oradbserv07 | 192.168.56.184 | eth1 |
| Node 1 private | oradbserv07-priv | 192.168.2.184 | eth2 |
| Node 1 VIP | oradbserv07-vip | 192.168.56.194 | (VIP, GI-managed) |
| Node 2 public | oradbserv08 | 192.168.56.185 | eth1 |
| Node 2 private | oradbserv08-priv | 192.168.2.185 | eth2 |
| Node 2 VIP | oradbserv08-vip | 192.168.56.195 | (VIP, GI-managed) |
| SCAN | scan-usatclust2 | 192.168.56.211 / .212 / .213 | 3 `A` records, same name |

Same domain (`usat.com`), same BIND primary/secondary pattern once built — likely
extending the existing `oradbserv05` zone rather than standing up a third DNS pair,
though that's a Phase 2 decision, not decided here.

## `/etc/hosts` — bootstrap only, not the real resolution path

A minimal block still gets pushed to both nodes (`ansible/roles/os_prep/templates/hosts.j2`)
so each node can reach the other and reach `oradbserv05` before BIND and `resolv.conf`
are fully live. It's rendered from `group_vars/all.yml`, so it always matches the tables
above — no separate copy to keep in sync.

## BIND zone — SCAN as 3 real `A` records

`ansible/roles/dns_bind` renders `/var/named/usat.com` on `oradbserv05` with every
node/VIP/private name plus SCAN listed **three times** under the same name, one per IP.
This is what gives SCAN its actual round-robin behavior — DNS returns all 3 addresses in
rotation, so a client-side `nslookup scan-usatclust1` (or GI's own SCAN listener
registration) sees genuine load distribution instead of one static hostname. The
complete `named.conf` and zone-file content (both nodes, copy-paste ready) is in
[`../installation/README.md`](../../installation/README.md#appendix-manual-bind-setup-no-ansible)
— this doc covers the *why* behind the design, that appendix has the *exact files*.

A matching reverse zone (`in-addr.arpa`) is rendered alongside it — GI's `cluvfy` checks
reverse lookups too.

**Validate:** `nslookup scan-usatclust1.usat.com` should return all 3 addresses; run it
4-5 times and confirm the order rotates.

## Firewall / SELinux for BIND

`ansible/roles/dns_bind` self-guards its port-53 (tcp+udp) firewalld rule behind a
check for whether firewalld is even active — `os_prep` now disables firewalld entirely
lab-wide (see `docs/known-risks.md` #25), so in practice that rule is a no-op. It also
sets the SELinux file context for `/var/named` via `restorecon`, which is harmless
whether or not SELinux is enforcing. SELinux itself is set fully to `disabled` (not just
`permissive`) in `os_prep` — see `docs/known-risks.md` #26 for why and for the
reboot-to-take-full-effect caveat. If `named` still misbehaves on a node that hasn't
rebooted since `os_prep` ran, check `/var/log/audit/audit.log` for AVC denials before
assuming it's a zone-file problem — SELinux may still be enforcing/permissive until
then.

## Chrony — OEM VM as local time master

Rather than reaching out to public NTP pools (no internet-dependent time sync inside the
lab), the OEM VM (`oemserver01`) runs chrony as a `local stratum 10` source, and both
RAC nodes point at it as their only server. Full manual (non-Ansible) chrony setup steps
are in
[`../installation/README.md`](../../installation/README.md#appendix-manual-chrony-setup-no-ansible).

**Known gotcha, carried over from the reference notes:** chrony can fail to resolve
`oemserver01` at boot if the network isn't fully up yet
(`Could not resolve address of initstepslew server ...`), especially on VirtualBox's
parallelized boot. `ansible/roles/chrony` adds an explicit
`After=network-online.target` + `Wants=network-online.target` systemd drop-in for
`chronyd.service` — verify it actually survives a reboot before trusting it.

## Cluster Verification Utility expectations

`cluvfy stage -pre crsinst` checks name resolution, reverse lookup, and connectivity for
every name above from both nodes. Run it after `dns_bind` and before
`grid_silent_install` — it's the cheapest place to catch a zone-file typo, well before a
failed `root.sh` forces a de-configure/re-configure cycle.
