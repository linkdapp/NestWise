#!/usr/bin/env bash
# Host-side VM tuning + storage provisioning — run on a macOS/Linux VirtualBox host,
# VMs powered OFF, before first boot. Mirrors vm-tuning-vboxmanage.ps1 — see that
# file's comments for the reasoning behind each setting.
#
# Usage:
#   ./vm-tuning-vboxmanage.sh <vm-name> [<vm-name> ...]              # compute+network only
#   ./vm-tuning-vboxmanage.sh --attach-shared-asm-disks vm1 vm2      # + shared ASM storage (real nodes only)
set -euo pipefail

ASM_DISK_DIR="${ASM_DISK_DIR:-$HOME/VirtualBox VMs/SharedDisks}"
ATTACH_ASM=false

if [[ "${1:-}" == "--attach-shared-asm-disks" ]]; then
  ATTACH_ASM=true
  shift
fi

VMS=("$@")

for vm in "${VMS[@]}"; do
  echo "Tuning ${vm} ..."

  VBoxManage modifyvm "$vm" --cpus 4
  VBoxManage modifyvm "$vm" --memory 12288
  VBoxManage modifyvm "$vm" --vram 16

  VBoxManage modifyvm "$vm" --hwvirtex on
  VBoxManage modifyvm "$vm" --nestedpaging on
  VBoxManage modifyvm "$vm" --largepages on
  VBoxManage modifyvm "$vm" --ioapic on
  VBoxManage modifyvm "$vm" --pae on
  VBoxManage modifyvm "$vm" --paravirtprovider kvm

  # NIC1 = NAT (admin/internet, DHCP)
  VBoxManage modifyvm "$vm" --nic1 nat

  # NIC2 = Host-Only Adapter (PUBLIC cluster network, static IP set inside the guest)
  # nictype: virtio-net (paravirtualized), not the Intel PRO/1000 MT Server (82545EM)
  # emulation this used to use — lower overhead, and avoids 82545EM's known
  # interconnect stability issues under VirtualBox. The guest kernel has virtio_net
  # built in already.
  VBoxManage modifyvm "$vm" --nic2 hostonly
  VBoxManage modifyvm "$vm" --hostonlyadapter2 vboxnet0
  VBoxManage modifyvm "$vm" --nictype2 virtio
  VBoxManage modifyvm "$vm" --cableconnected2 on

  # NIC3 = Internal Network "intnet" (PRIVATE interconnect, static IP set inside the
  # guest). CHANGED 2026-08-10 from a custom name "ora_priv" — real incident:
  # oradbserv06's NIC3 internal network NAME ended up as "intnet" (VirtualBox's own
  # default placeholder) while oradbserv05 had the custom "ora_priv" name — exactly
  # how they diverged wasn't conclusively pinned down (clonevm is supposed to carry
  # the source VM's adapter name over), only that they had. VirtualBox doesn't
  # validate that one VM's internal network name matches any other VM's, and a lone
  # VM on a network with zero peers still reports a live link (LOWER_UP) to its own
  # guest OS, so nothing looked wrong from inside either node. Result: `ping`/`ssh`
  # between the two private IPs failed with "Destination Host Unreachable" in both
  # directions (each node could only reach its own IP), which is exactly what hung
  # `grid_infrastructure`'s cluvfy sanity check — see docs/known-risks.md #11 for the
  # full diagnosis. Standardized on "intnet" (the default) for both VMs specifically
  # because it removes the chance of a typo'd custom name diverging between them
  # ever again — every VM this script tunes gets the identical, unambiguous default
  # rather than a hand-typed string.
  VBoxManage modifyvm "$vm" --nic3 intnet
  VBoxManage modifyvm "$vm" --intnet3 "intnet"
  VBoxManage modifyvm "$vm" --nictype3 virtio
  VBoxManage modifyvm "$vm" --cableconnected3 on

  echo "${vm} tuned (compute + network)."

  # Authoritative check, independent of any "is of type bridged" warning VBoxManage may
  # print for --hostonlyadapter2 on some host/version combinations (see
  # docs/network-and-hosts.md) — that warning is a known cosmetic mismatch in
  # VBoxManage's own interface-type check and doesn't override --nic2 hostonly.
  echo "--- Actual NIC config for ${vm} ---"
  VBoxManage showvminfo "$vm" | grep "^NIC"
done

if $ATTACH_ASM; then
  if [[ "${#VMS[@]}" -ne 2 ]]; then
    echo "Shared ASM disks go on exactly the 2 real node VMs, not the template." >&2
    echo "Re-run: $0 --attach-shared-asm-disks oradbserv05 oradbserv06" >&2
    exit 1
  fi

  mkdir -p "$ASM_DISK_DIR"

  # /u01: 75GB dynamic, second (non-shared) disk per node
  for vm in "${VMS[@]}"; do
    u01_disk="$ASM_DISK_DIR/${vm}-u01.vdi"
    VBoxManage createmedium disk --filename "$u01_disk" --size 76800 --format VDI --variant Standard
    VBoxManage storagectl "$vm" --name "SATA Controller" --add sata --controller IntelAhci --portcount 4 || true
    VBoxManage storageattach "$vm" --storagectl "SATA Controller" --port 1 --device 0 --type hdd --medium "$u01_disk"
  done

  # ASMDISK01-06: 50GB each, FIXED, SHAREABLE, attached to BOTH nodes
  VBoxManage storagectl "${VMS[0]}" --name "SAS Controller" --add sas --controller LSILogicSAS || true
  VBoxManage storagectl "${VMS[1]}" --name "SAS Controller" --add sas --controller LSILogicSAS || true

  for i in 1 2 3 4 5 6; do
    label=$(printf "ASMDISK%02d" "$i")
    disk_file="$ASM_DISK_DIR/${label}.vdi"

    if [[ ! -f "$disk_file" ]]; then
      VBoxManage createmedium disk --filename "$disk_file" --size 51200 --format VDI --variant Fixed
      VBoxManage modifymedium disk "$disk_file" --type shareable
    fi

    port=$((i - 1))
    VBoxManage storageattach "${VMS[0]}" --storagectl "SAS Controller" --port "$port" --device 0 --type hdd --medium "$disk_file" --mtype shareable
    VBoxManage storageattach "${VMS[1]}" --storagectl "SAS Controller" --port "$port" --device 0 --type hdd --medium "$disk_file" --mtype shareable

    echo "${label} attached to ${VMS[0]} and ${VMS[1]}."
  done

  cat <<'EOF'

6 shared 50GB ASMDISK0x volumes attached to both nodes.
Inside each guest: confirm device paths with 'lsblk' before running
ansible/roles/asmlib_disks (asmlib_disks in group_vars/all.yml assumes
/dev/sdb.../dev/sdg — update it if lsblk shows something different).
EOF
fi
