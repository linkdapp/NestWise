<#
  Host-side VM tuning + storage provisioning — run on the Windows host, VMs powered
  OFF, before first boot. Adjust $VMS names to match what's actually registered in
  VirtualBox (VBoxManage list vms). Values below assume a 32 vCPU / 128GB host per the
  project baseline.

  Run the compute/network section against oradbserv05 BEFORE its OS install. The shared
  ASM disks are attached separately, AFTER oradbserv06 is cloned from oradbserv05 (see
  docs/golden-image-and-cloning.md for why disk marking can't happen any earlier) —
  run the -AttachSharedAsmDisks section once both real nodes exist.

  Run this from ANY directory — it doesn't need to be your current location, relative
  paths in the script itself (like $AsmDiskDir below, if you make it relative) are the
  only thing that would care about cwd. What DOES matter is that VBoxManage.exe is
  findable: the VirtualBox installer does not add itself to the Windows PATH by
  default, so a plain `VBoxManage` call fails with "not recognized as a cmdlet" even
  though VirtualBox itself is installed and working. This script resolves the path
  automatically below — override with -VBoxManagePath if yours lives somewhere
  non-default.
#>

param(
    [Parameter(Mandatory = $true)]
    [string[]] $VMS,                      # e.g. -VMS oradbserv05,oradbserv06 (or a single node name)

    [switch] $AttachSharedAsmDisks,        # only pass this for the two real, already-cloned node VMs

    [string] $VBoxManagePath               # optional override if VBoxManage.exe isn't in the default install location
)

# --- Resolve VBoxManage.exe: PATH first, then the standard install location ---------
$VBoxManage = $null
if ($VBoxManagePath) {
    $VBoxManage = $VBoxManagePath
}
elseif (Get-Command VBoxManage -ErrorAction SilentlyContinue) {
    $VBoxManage = "VBoxManage"
}
else {
    $defaultPath = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
    if (Test-Path $defaultPath) {
        $VBoxManage = $defaultPath
    }
}

if (-not $VBoxManage) {
    Write-Error "VBoxManage.exe not found on PATH or at the default install location. Pass -VBoxManagePath 'C:\path\to\VBoxManage.exe' explicitly."
    exit 1
}

Write-Host "Using VBoxManage: $VBoxManage"

# Adding VirtualBox to your PATH permanently avoids needing -VBoxManagePath every time,
# and is also what clone-node.yml (run from WSL2) needs for `VBoxManage.exe` to resolve
# there too — see docs/ansible-on-windows.md. From an elevated PowerShell prompt:
#   [Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\Program Files\Oracle\VirtualBox", "Machine")
# then open a new shell for it to take effect.

$AsmDiskDir = "G:\virtualbox_vm\ASMDISKS\PrimaryDB"   # adjust to wherever you want the shared .vdi files to live

foreach ($vm in $VMS) {
    Write-Host "Tuning $vm ..."

    # --- CPU / memory -------------------------------------------------------
    & $VBoxManage modifyvm $vm --cpus 3
    & $VBoxManage modifyvm $vm --memory 12288          # 12 GB per node; leaves room for OEM/EBS VMs on the same host
    & $VBoxManage modifyvm $vm --vram 16

    # --- Virtualization acceleration ----------------------------------------
    & $VBoxManage modifyvm $vm --hwvirtex on
    & $VBoxManage modifyvm $vm --nestedpaging on
    & $VBoxManage modifyvm $vm --largepages on          # complements THP-disabled guest kernel setting, not a substitute for it
    & $VBoxManage modifyvm $vm --ioapic on               # required for multi-core guests / SMP
    & $VBoxManage modifyvm $vm --pae on
    & $VBoxManage modifyvm $vm --paravirtprovider kvm    # lower CPU overhead than the default provider

    # --- Network: 3 adapters, see docs/network-and-hosts.md ------------------
    # NIC1 = NAT (admin/internet, DHCP)
    & $VBoxManage modifyvm $vm --nic1 nat

    # NIC2 = Host-Only Adapter (PUBLIC cluster network, static IP set inside the guest)
    # nictype: virtio-net (paravirtualized), not the Intel PRO/1000 MT Server (82545EM)
    # emulation this used to use — virtio-net is lower overhead and doesn't have
    # 82545EM's known interconnect stability issues under VirtualBox. The guest
    # kernel has the virtio_net driver built in, no extra guest driver install needed.
    & $VBoxManage modifyvm $vm --nic2 hostonly
    & $VBoxManage modifyvm $vm --hostonlyadapter2 "VirtualBox Host-Only Ethernet Adapter"
    & $VBoxManage modifyvm $vm --nictype2 virtio
    & $VBoxManage modifyvm $vm --cableconnected2 on

    # NIC3 = Internal Network "intnet" (PRIVATE interconnect, static IP set inside the
    # guest). Uses VirtualBox's default "intnet" name for both VMs deliberately — see
    # the matching comment in vm-tuning-vboxmanage.sh and docs/known-risks.md #11:
    # a mismatched internal network NAME between the two VMs (each VM still shows a
    # live link to its own guest OS even with zero peers on its network, so nothing
    # looks wrong from inside either node) silently breaks the private interconnect
    # entirely and hung cluvfy. Standardized on "intnet" for both VMs so there's no
    # hand-typed custom string left to diverge.
    & $VBoxManage modifyvm $vm --nic3 intnet
    & $VBoxManage modifyvm $vm --intnet3 "intnet"
    & $VBoxManage modifyvm $vm --nictype3 virtio
    & $VBoxManage modifyvm $vm --cableconnected3 on

    Write-Host "$vm tuned (compute + network)."

    # Print back what VirtualBox actually recorded, independent of any warnings above —
    # the "is of type bridged" warning some VBoxManage/Windows combinations print for
    # --hostonlyadapter2 is a known cosmetic mismatch in VBoxManage's own interface-type
    # check (see docs/network-and-hosts.md); it does not override the --nic2 hostonly
    # setting actually applied. This is the authoritative check, not the warning text.
    Write-Host "--- Actual NIC config for $vm (ignore the 'is of type bridged' warning above if these look right) ---"
    # Where-Object instead of Select-String: Select-String's match-highlighting renders
    # as garbled ANSI escape sequences in some PowerShell/terminal combinations. This
    # just filters lines, no highlighting, no garbling.
    & $VBoxManage showvminfo $vm | Where-Object { $_ -match '^NIC' }
}

if ($AttachSharedAsmDisks) {
    if ($VMS.Count -ne 2) {
        Write-Warning "Shared ASM disks are meant to be attached to exactly the 2 real node VMs. Re-run with -VMS oradbserv05,oradbserv06 -AttachSharedAsmDisks."
        exit 1
    }

    New-Item -ItemType Directory -Force -Path $AsmDiskDir | Out-Null

    # --- root disk: 50GB dynamic — created at VM-creation time, not here ------
    # /u01: 75GB dynamic, second (non-shared) disk per node -------------------
    foreach ($vm in $VMS) {
        $u01Disk = Join-Path $AsmDiskDir "$vm-u01.vdi"
        & $VBoxManage createmedium disk --filename "$u01Disk" --size 76800 --format VDI --variant Standard
        & $VBoxManage storagectl $vm --name "SATA Controller" --add sata --controller IntelAhci --portcount 4 2>$null
        & $VBoxManage storageattach $vm --storagectl "SATA Controller" --port 1 --device 0 --type hdd --medium "$u01Disk"
    }

    # --- ASMDISK01-06: 50GB each, FIXED, SHAREABLE, attached to BOTH nodes ----
    & $VBoxManage storagectl $VMS[0] --name "SAS Controller" --add sas --controller LSILogicSAS 2>$null
    & $VBoxManage storagectl $VMS[1] --name "SAS Controller" --add sas --controller LSILogicSAS 2>$null

    for ($i = 1; $i -le 6; $i++) {
        $label = "ASMDISK{0:D2}" -f $i
        $diskFile = Join-Path $AsmDiskDir "$label.vdi"

        if (-not (Test-Path $diskFile)) {
            & $VBoxManage createmedium disk --filename "$diskFile" --size 51200 --format VDI --variant Fixed
            & $VBoxManage modifymedium disk "$diskFile" --type shareable
        }

        & $VBoxManage storageattach $VMS[0] --storagectl "SAS Controller" --port $($i - 1) --device 0 --type hdd --medium "$diskFile" --mtype shareable
        & $VBoxManage storageattach $VMS[1] --storagectl "SAS Controller" --port $($i - 1) --device 0 --type hdd --medium "$diskFile" --mtype shareable

        Write-Host "$label attached to $($VMS[0]) and $($VMS[1])."
    }

    Write-Host ""
    Write-Host "6 shared 50GB ASMDISK0x volumes attached to both nodes."
    Write-Host "Inside each guest: confirm device paths with 'lsblk' before running"
    Write-Host "ansible/roles/asmlib_disks (asmlib_disks in group_vars/all.yml assumes"
    Write-Host "/dev/sdb.../dev/sdg — update it if lsblk shows something different)."
}
