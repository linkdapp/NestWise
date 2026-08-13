# Build oradbserv05 manually, clone it for oradbserv06

`oradbserv05` is built by hand first — no separate throwaway template VM. Once it's
built and verified, it becomes the clone source: `oradbserv06` is a clone of the real
node 1, not of a disposable golden image. This is simpler than a template-plus-two-clones
setup and works just as well here, since node 1 never gets anything cloned-specific
baked into it — it just needs to exist and be correct before node 2 is cloned from it.

Order: **build → verify → clone → personalize → verify again → continue the pipeline.**

## Step 1 — Build oradbserv05 by hand

Install Oracle Linux 7 (minimal) on the `oradbserv05` VM directly — ISO boot, manual
install, no Ansible involved yet. Set its
**final, real identity** during this install, not a placeholder:

- Hostname: `oradbserv05.usat.com`
- 3 NICs per [`network-and-hosts.md`](network-and-hosts.md#adapters-per-node--3-nics-not-2):
  NAT (DHCP), Host-Only Adapter static `192.168.56.181/24` (gateway `192.168.56.1`, DNS
  search `usat.com`), Internal Network `intnet` static `192.168.2.181/24` (no gateway —
  confirm this internal network NAME is the identical string on both VMs, see
  `docs/known-risks.md` #11 for why that matters)
- Enable `sshd`

Once the OS is up and reachable, create the `ansible` managed-node account (passwordless
sudo) that Ansible will connect as — this is a manual, pre-Ansible step by necessity
(Ansible can't SSH in to automate creating its own connection account); exact commands
are in [`../installation/README.md`](../../installation/README.md#5-configure-ansible).

Then perform the equivalent of what `os_prep` would do — either by hand, or just let
Ansible do this part even though the OS install itself was manual:

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags os_prep --limit oradbserv05
```

There's no real purity requirement here — "build manually" is mainly about the OS
install and identity; letting `os_prep` (idempotent) handle the repetitive
package/sysctl/limits/user setup on top of that is fine and less error-prone than
retyping it by hand. What matters is that a **known, verifiable** state exists before
cloning, not which tool produced it.

## Step 2 — Verify oradbserv05 before trusting it as a clone source

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags verify_baseline --limit oradbserv05
```

[`verify_baseline`](../ansible/roles/verify_baseline/tasks/main.yml) asserts the node
actually matches what `os_prep` should have produced — preinstall RPM, users/groups
(including primary group, not just supplementary membership), sudo, OFA directories
(including the dual-owned staging directory and the dedicated `/u01` mount), sysctl
values, resource limits, the I/O scheduler rule, and SELinux mode. It reports every gap
in one pass rather than stopping at the first, and fails the play if anything's
missing — re-run `os_prep` to close gaps automatically, or fix by hand and re-verify.
**Don't clone a node that hasn't passed this check** — any gap gets duplicated into
node 2 otherwise.

ASMLib packages/service are checked too, but only *reported*, not treated as a failure,
at this point — `asmlib_disks` hasn't run yet this early (it's later in `site.yml`,
after both real nodes exist), so it would never actually be installed at either of
verify_baseline's two normal call sites otherwise. Once `asmlib_disks` has run, add
`-e verify_asmlib_disks=true` to hold it to that check too.

## Step 3 — Clone, via Ansible

Power off `oradbserv05` first — `clonevm` needs a clean, non-running source for this
workflow (no `--live`):

```bash
VBoxManage.exe controlvm oradbserv05 acpipowerbutton   # or shut down from inside the guest
```

Then run the clone playbook:

```bash
ansible-playbook clone-node.yml -e source_vm=oradbserv05 -e target_vm=oradbserv06
```

[`clone-node.yml`](../ansible/clone-node.yml) runs against `localhost` (the Ansible
control node itself) and shells out to `VBoxManage.exe clonevm ... --mode all` — a full
clone, not linked, so `oradbserv06` has no ongoing disk dependency on `oradbserv05`. It
checks first that VBoxManage is reachable (WSL2 needs Windows-interop and VirtualBox's
install directory on the Windows `PATH` — `VBoxManage.exe --version` should just work
from a WSL2 shell; if it doesn't, the playbook tells you the equivalent raw PowerShell
command to run instead) and that the source is powered off before proceeding.

## Step 4 — Personalize the clone — console only, not SSH

**`oradbserv06` boots as a byte-for-byte network-identical duplicate of `oradbserv05`:**
same hostname, same static IP on every NIC. If both VMs are powered on at the same time
before this step, they conflict on the shared Host-Only and Internal networks — ARP
fights, silent packet loss, a genuinely confusing thing to debug blind. So:

1. Leave `oradbserv05` powered off for now.
2. Boot `oradbserv06` and log in via the **VirtualBox console** (Show/GUI window or
   `VBoxManage.exe startvm oradbserv06 --type headless` + a serial/console connection —
   not SSH, since its IP isn't unique yet).
3. At the console:
   ```bash
   hostnamectl set-hostname oradbserv06.usat.com

   nmcli con show   # confirm names below match — clone should keep eth1/eth2, but verify, don't assume

   nmcli con mod eth1 ipv4.addresses 192.168.56.182/24 \
     ipv4.gateway 192.168.56.1 ipv4.dns-search usat.com ipv4.method manual
   nmcli con mod eth2 ipv4.addresses 192.168.2.182/24 ipv4.method manual
   nmcli con up eth1
   nmcli con up eth2

   # New machine-id and SSH host keys so oradbserv06 doesn't present oradbserv05's identity
   rm -f /etc/machine-id /var/lib/dbus/machine-id
   systemd-machine-id-setup
   rm -f /etc/ssh/ssh_host_*
   ssh-keygen -A
   systemctl restart sshd
   ```
4. Reboot `oradbserv06`, confirm it comes up on `192.168.56.182`/`192.168.2.182` with
   the new hostname.
5. **Now** power `oradbserv05` back on. Both should coexist without conflict.

**Verify the HOST-SIDE NIC3 internal network name matches, not just the guest-side
config above.** Everything in step 3 is guest-OS-side (`nmcli`, hostname,
machine-id) — none of it touches the VirtualBox adapter's own internal network NAME
attribute. `clonevm` is *supposed* to carry that over from the source VM, but confirm
rather than assume — see
[`known-risks.md`](known-risks.md) #11 for why a divergent name is invisible from
inside either guest (a lone VM on an internal network with zero peers still shows a
live link to its own OS). Confirm from the host before trusting the clone:
```bash
# WSL2/bash:
"/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" showvminfo oradbserv05 --machinereadable | grep -E "nic3|intnet3|cableconnected3"
"/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" showvminfo oradbserv06 --machinereadable | grep -E "nic3|intnet3|cableconnected3"
```
Both should show `nic3="intnet"`, `intnet3="intnet"`, `cableconnected3="on"` — identical
strings, not just "similar." If they diverge, `VBoxManage modifyvm oradbserv06 --intnet3 "intnet"` (VM powered off) fixes it.

(Interface-naming note: this build uses classic `eth0`/`eth1`/`eth2` naming, not the
`enp0sN` predictable-naming scheme — a clone's new MAC address doesn't change that.
Confirm with `ip a` after first boot anyway — cheap to check, expensive to debug if
wrong.)

**Reminder — don't stop here:** both nodes now look "done" from a networking
standpoint (correct hostnames, correct static IPs, SSH reachable), which makes it easy
to assume the addressing work is finished. It isn't — `dns_bind` hasn't run on either
node yet at this point; it's Step 5 below, not part of personalization itself. Without
it, name resolution (including SCAN's 3-IP round-robin) won't work when `cluvfy`/
`gridSetup.sh` needs it later. **Run `dns_bind` against `oradbserv05` (primary) before
`oradbserv06` (secondary)** — the secondary pulls its zone via AXFR from the primary on
first start, so it needs a running, reachable primary to actually get any data;
otherwise it comes up with an empty zone and answers every query with `SERVFAIL` until
it can — even with the primary up, the first transfer isn't always instant, so give it
a few minutes before assuming something's broken. `--tags dns_bind` targets `rac_nodes`
(both), so a single run handles the ordering correctly as long as `oradbserv05` is
powered on and reachable when it starts.

## Step 5 — Verify oradbserv06, then continue the normal pipeline

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags verify_baseline --limit oradbserv06
```

Once both nodes pass verification and can reach each other over SSH, resume the normal
build from `docs/network-and-hosts.md` / [`../installation/README.md`](../../installation/README.md)
— `dns_bind`, `chrony`, `asmlib_disks` (disk marking happens here, after both real nodes
exist and the shared `ASMDISK01`-`06` volumes are attached to both — see
[`known-risks.md`](known-risks.md) #4 for why it can't happen any earlier), then
`patch_before_config`, `grid_infrastructure`, `db_software`, `dbca_noncdb`.

📸 *Showcase note for `installation/`: `VBoxManage.exe list vms` showing both nodes
registered, plus the `verify_baseline` PASS output for both, is good evidence the clone
produced a real, working duplicate — not just an assertion that it did.*
