# Running Ansible from Windows

Ansible's control node (the machine you run `ansible-playbook` from) does not support
Windows natively — it needs a POSIX environment. The managed nodes (the RAC VMs) are
Linux and are controlled the same way regardless; this is purely about where you type
`ansible-playbook`. **WSL2 is the standard, Microsoft- and Red&nbsp;Hat-documented way to
run Ansible from a Windows machine.**

## 1. Install WSL2

From an elevated PowerShell prompt:

```powershell
wsl --install -d Ubuntu
```

Reboot if prompted, then finish the Ubuntu first-run setup (username/password inside
the WSL2 environment — unrelated to your Windows login).

## 2. Install Ansible inside WSL2

Modern Ubuntu (23.04+, including the default WSL2 Ubuntu image, which ships Python
3.12) blocks a plain `pip3 install --user ansible` with `error:
externally-managed-environment` — this is PEP 668, not a WSL2-specific problem. Debian/
Ubuntu's system Python refuses `pip install` outside a venv so a stray pip install can't
break apt-managed packages. Don't reach for `--break-system-packages`; use one of the
two options below instead.

**Option A — apt (simplest, recommended for this project):**

```bash
sudo apt update
sudo apt install -y ansible sshpass

# confirm
ansible --version
```

Ubuntu's repo version of Ansible is a version or two behind upstream, which is fine
here — nothing in this repo's playbooks needs a bleeding-edge `ansible-core` feature.

**Option B — pipx (if you specifically want the latest ansible-core):**

```bash
sudo apt update
sudo apt install -y pipx sshpass
pipx ensurepath
source ~/.bashrc     # reload PATH so pipx-installed binaries are found

pipx install --include-deps ansible

# confirm
ansible --version
```

`pipx` gives Ansible its own isolated virtual environment (no system-Python conflict)
while still exposing `ansible`/`ansible-playbook` on your `PATH` — `--include-deps` is
required because the `ansible` package pulls in `ansible-core` (which actually provides
`ansible-playbook`) as a dependency, and pipx doesn't expose dependencies' entry points
by default.

## 3. Reach this repo from WSL2

This repo lives on the Windows filesystem at `D:\github\Oracle-DBA-POC`. WSL2 mounts
Windows drives under `/mnt/`, so it's reachable at:

```bash
cd "/mnt/d/github/Oracle-DBA-POC/phase-01-foundation-2node-rac-12cR2/ansible"
```

Cross-filesystem access (WSL2 reading/writing NTFS via `/mnt/d/...`) works but is
slower than native Linux filesystem access. For a repo this size it doesn't matter; if
`ansible-playbook` ever feels sluggish, `git clone` a working copy into WSL2's native
filesystem (`~/oracle-dba-poc`) instead and treat `D:\github\Oracle-DBA-POC` as the
push/pull remote.

**Known gotcha: `ansible.cfg` gets silently ignored from here.** Running any `ansible`/
`ansible-playbook` command from `/mnt/d/...` prints:
```
[WARNING]: Ansible is being run in a world writable directory ..., ignoring it as an
ansible.cfg source.
```
WSL2's DrvFs mount exposes NTFS directories under `/mnt/` as `777` (world-writable) by
default — there's no real Unix permission bit on the Windows side, so WSL2 has to make
something up, and the default is wide open. Ansible refuses to trust an `ansible.cfg`
sitting in a world-writable directory (someone else with write access could plant a
malicious one), so it silently falls back to defaults — including `remote_user`, which
means commands connect as your WSL2 shell user instead of `ansible`, and fail with
`Permission denied (publickey...)` even though the SSH key setup in Section 4 is correct.

Confirm this is what's happening — from the **Ubuntu/WSL2 shell**, in the `ansible/`
directory:
```bash
ls -ld .
```
shows `drwxrwxrwx`. Three fixes, in order of preference:

- **Fix the WSL2 mount permissions (durable, fixes it everywhere under `/mnt/d`) — the
  recommended fix, confirmed working:**

  1. In the **Ubuntu/WSL2 shell**, write the override:
     ```bash
     sudo bash -c 'cat >> /etc/wsl.conf <<EOF
     [automount]
     options = "metadata,umask=22,fmask=111"
     EOF'
     ```
     Confirm it wrote: `cat /etc/wsl.conf`.
  2. Switch to a **Windows PowerShell** window (a *different* window — this is not a
     WSL2 command) and run:
     ```powershell
     wsl --shutdown
     ```
     This kills the whole WSL2 VM, so your Ubuntu terminal window will print `The
     Windows Subsystem for Linux instance has terminated.` and stop responding —
     **that's expected**, not an error. It just means the shutdown worked.
  3. Reopen **Ubuntu** (Start menu, or type `wsl` in a fresh PowerShell window). The
     new session picks up the `/etc/wsl.conf` change automatically.
  4. Re-check permissions: `ls -ld .` in the `ansible/` directory should now show
     `drwxr-xr-x` instead of `drwxrwxrwx`.
  5. Confirm the actual fix — run the ping **without** `-u ansible`:
     ```bash
     ansible -i inventory/hosts.ini oradbserv05 -m ping
     ```
     Two things confirm success: the `world writable directory` warning is gone, and
     it still returns `"pong"` — meaning `ansible.cfg`'s `remote_user = ansible` loaded
     on its own, with no `-u` flag needed. If the warning is still there, go back to
     step 4 and check `cat /etc/wsl.conf` actually persisted.

- **Point at the config file explicitly, bypassing the cwd safety check** (quicker,
  less durable — only fixes Ansible's config loading, not the underlying permissions):
  ```bash
  export ANSIBLE_CONFIG="/mnt/d/github/Oracle-DBA-POC/phase-01-foundation-2node-rac-12cR2/ansible/ansible.cfg"
  ```
  (add to `~/.bashrc` to make it permanent). Explicitly naming the config file this way
  is exempt from the world-writable-cwd check — only auto-discovery of `./ansible.cfg`
  triggers it.
- **Clone into WSL2's native filesystem** (mentioned above) — ext4 has real permission
  bits, so the check never triggers there at all. The most complete fix if you're
  already considering this for performance.

Until one of these is applied, every command in this SOP either needs `-u ansible`
appended explicitly, or will silently connect as the wrong user:
```bash
ansible -i inventory/hosts.ini oradbserv05 -m ping -u ansible
```

## 4. SSH keys — generate inside WSL2, not Windows

Ansible connects to the RAC nodes over SSH from wherever `ansible-playbook` actually
runs — that's WSL2, so the key pair needs to live there, not in `C:\Users\...\.ssh`.

**Prerequisite on each managed node first:** the `ansible` account (`remote_user` in
`ansible.cfg`) has to exist before `ssh-copy-id` has anywhere to copy a key to, and
Ansible itself can't create it — nothing can SSH in as `ansible` before the account
exists. Run this once on each node, at the console or over SSH as whatever account you
used during the OS install (full context:
[`installation/README.md` Section 5](../../installation/README.md#5-configure-ansible)):

```bash
sudo useradd -m -s /bin/bash ansible
sudo passwd ansible
echo "ansible ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ansible
sudo chmod 0440 /etc/sudoers.d/ansible
```

Then, from WSL2:

```bash
ssh-keygen -t ed25519 -C "ansible-control"
ssh-copy-id ansible@192.168.56.181   # oradbserv05
ssh-copy-id ansible@192.168.56.182   # oradbserv06
```

(If you'd rather connect as a different account, point `remote_user` in `ansible.cfg`
at that account instead — the passwordless-sudo setup above still applies to whichever
account you choose.)

## 5. Networking — WSL2 needs to reach the VirtualBox Host-Only network

WSL2 runs behind its own NAT by default and can't always reach a VirtualBox Host-Only
adapter's subnet (192.168.56.0/24) out of the box. Two ways to fix this, in order of how
much they change your setup:

- **WSL2 mirrored networking mode** (Windows 11 23H2+): add to
  `%UserProfile%\.wslconfig`:
  ```ini
  [wsl2]
  networkingMode=mirrored
  ```
  then `wsl --shutdown` and reopen. WSL2 shares the Windows host's network interfaces
  directly, including the VirtualBox Host-Only adapter — simplest fix if your Windows
  version supports it.
- **Bridge WSL2's virtual switch to the VirtualBox Host-Only network** manually if
  mirrored mode isn't available — more fragile, only reach for this if the above
  doesn't apply to your Windows build.

Verify connectivity before doing anything else:

```bash
ping -c 2 192.168.56.181
ssh ansible@192.168.56.181 "hostname"
```

## 6. `ansible -m ping` fails with "No such file or directory" — OL7 has no `/usr/bin/python3` out of the box

`inventory/hosts.ini` sets `ansible_python_interpreter=/usr/bin/python3` for `rac_nodes`
— correct for where this project ends up, but not what a freshly-installed OL7 node
actually has. Oracle Linux 7's default system Python is 2.7 (`/usr/bin/python`);
`python3` (3.6.8) is available from the `ol7_latest` repo since OL7.7, but it's not
installed by default, so `-m ping` against a brand-new node fails with `/bin/sh:
/usr/bin/python3: No such file or directory` before any real Ansible module ever runs
— this is expected on a node that hasn't been bootstrapped yet, not a broken install.

`site.yml` handles this automatically now — a `tags: [always]` bootstrap play runs
before every other play, uses the `raw` module (which needs no Python on the target at
all, since it's a plain SSH command) to check for `/usr/bin/python3` and `yum install`
it if missing. This means the very first real run against a fresh node should be a
tagged play (even just `--tags os_prep`), not a bare `ansible ... -m ping` — the bare
ad-hoc `ping` module has no bootstrap play to run first, so it hits this error on a
truly fresh node. If you need to confirm connectivity before running anything else, use
`raw` directly instead of `ping`:

```bash
ansible -i inventory/hosts.ini oradbserv05 -m raw -a "echo pong"
```

Or fix it once, by hand, the same way the bootstrap play does:

```bash
ansible -i inventory/hosts.ini oradbserv05 -m raw -a "sudo yum install -y python3" -u ansible
```

See [`known-risks.md`](known-risks.md) #17 for the full reasoning, including why
`/usr/bin/python3` (not `/usr/bin/python`) is still the right long-term interpreter
choice for this project rather than falling back to Python 2.7.

## 7. VBoxManage isn't on PATH by default — needed for clone-node.yml

The VirtualBox installer does not add itself to the Windows `PATH`. This bites two
places in this repo: `scripts/vm-tuning-vboxmanage.ps1` (run from plain PowerShell) and
`ansible/clone-node.yml` (run from WSL2, which needs `VBoxManage.exe` reachable via
Windows-interop). Both now auto-detect it — first on `PATH`, then at the default
install location (`C:\Program Files\Oracle\VirtualBox\VBoxManage.exe`, or
`/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe` from WSL2) — so this usually
resolves itself. If VirtualBox is installed somewhere non-default, override explicitly:

```powershell
# PowerShell script
.\vm-tuning-vboxmanage.ps1 -VMS oradbserv05 -VBoxManagePath "D:\VirtualBox\VBoxManage.exe"
```
```bash
# clone-node.yml, from WSL2
ansible-playbook clone-node.yml -e vboxmanage_bin='"D:\VirtualBox\VBoxManage.exe"'
```

The durable fix, if you'd rather not think about this again, is adding VirtualBox to
the system `PATH` once (elevated PowerShell, then open a new shell):

```powershell
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\Program Files\Oracle\VirtualBox", "Machine")
```

## 8. Run playbooks as normal

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags os_prep
```

Everything else in this repo's docs assumes commands are run from this WSL2 shell.

## Alternative: skip Windows entirely for the control node

If WSL2 networking turns into a fight, a lighter option is running Ansible from
inside one of the lab VMs themselves (e.g. the OEM VM, or a small dedicated
control-node VM) instead of from Windows — SSH into it from Windows/PuTTY and run
`ansible-playbook` there. Loses the convenience of editing files directly in
`D:\github\Oracle-DBA-POC` from Windows tools, but sidesteps WSL2-to-VirtualBox
networking entirely.
