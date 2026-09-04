# Ansible architecture, and how to see what it actually did

This doc has two jobs: explain what's actually happening when you run an
`ansible-playbook` command against this repo (control node, managed nodes, the file
layout, what each role does), and lay out every tool available — Ansible's own, and
this repo's own conventions — for seeing exactly what ran, what changed, and why
something failed, beyond the scrollback in your terminal.

## The model: one control node, several managed nodes

Ansible is agentless — there's no daemon running on `oradbserv05`/`oradbserv06`/
`oemserver01` waiting for instructions. Every `ansible-playbook` invocation:

1. Runs entirely from the **control node** — your WSL2 shell (`docs/ansible-on-windows.md`
   covers why WSL2, not native Windows). This is where `ansible-playbook`, the roles,
   and `group_vars/all.yml` all live.
2. Reads `ansible/inventory/hosts.ini` to figure out which **managed nodes** apply to
   the play, then connects to each over **SSH** as the `ansible` user (`remote_user =
   ansible` in `ansible.cfg`) — the account created in `docs/ansible-on-windows.md`
   step 2, before any playbook can run at all.
3. For tasks needing root (`become: true` — most of them, since Oracle installs touch
   `/u01`, kernel params, systemd units), escalates via `sudo` on the managed node
   (`[privilege_escalation]` in `ansible.cfg`: `become = True`, `become_method = sudo`).
4. Copies the relevant Python module for each task over SSH, executes it on the managed
   node, reads back a JSON result, and reports it to your terminal. For `command`/
   `shell` tasks (which is most of what `grid_silent_install`, `db_silent_install`,
   `dbca_noncdb`, and `patch_before_config` actually do), that module is a thin wrapper
   that just runs the command as-is on the managed node and captures stdout/stderr/rc.

Nothing persists on the control node between runs except what you already have on
disk — the repo itself, and (as of this doc) a run log, covered below.

## Anatomy of a command you'll actually type

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags dns_bind --limit oradbserv05
```

- `ansible-playbook` — the executable; reads `ansible.cfg` from the current directory
  automatically (which is why every command in `installation/README.md` assumes you've
  `cd`'d into `ansible/` first — `ansible.cfg` isn't found otherwise, and defaults like
  `remote_user = ansible` silently fall back to your local username instead).
- `-i inventory/hosts.ini` — technically redundant here, since `ansible.cfg` already
  sets `inventory = inventory/hosts.ini` as the default. Explicit in the docs anyway
  for clarity and so the commands work even if you ever run them with a different
  `ansible.cfg` or from a different directory.
- `site.yml` — the **playbook**: an ordered list of **plays**, each targeting a host
  group and (usually) running exactly one **role**. See the table below.
- `--tags dns_bind` — only run the play(s) tagged `dns_bind`. Without this, `site.yml`
  runs start to finish, every play, in file order — rarely what you want mid-build,
  since GI/DB installs shouldn't blindly re-run every time you fix a DNS record.
- `--limit oradbserv05` — further restricts *which hosts within the targeted play*
  actually run. `--tags` picks the play; `--limit` picks the hosts inside it. This is
  how `patch_before_config --limit oradbserv05` avoids demanding staged patch zips on
  `oradbserv06` too, even though the play's `hosts:` line says `rac_nodes` (both nodes).

## File map and what each piece is responsible for

```
ansible/
├── ansible.cfg              behavior defaults — see below
├── site.yml                 the playbook: ordered plays, one per build phase
├── clone-node.yml           separate playbook — drives VBoxManage clonevm from the
│                             control node itself, not a role, not part of site.yml
├── inventory/hosts.ini      which hosts exist, and which groups they belong to
├── group_vars/all.yml       every variable every role/template reads — single
│                             source of truth (see below)
└── roles/<name>/
    ├── tasks/main.yml        what actually runs, in order
    ├── templates/*.j2        Jinja2 templates — rendered into real files on the
    │                         managed node (response files, config files)
    └── handlers/main.yml     tasks that only run when notified (e.g. "restart named"
                              only fires if the zone file task actually changed something)
```

### `ansible.cfg`

```ini
[defaults]
inventory = inventory/hosts.ini
remote_user = ansible
host_key_checking = False    # skips the interactive "yes/no, trust this host key?"
                              # prompt — deliberate here since these are lab VMs
                              # rebuilt/cloned repeatedly (new host key every clone),
                              # not something you'd want on a real fleet
retry_files_enabled = False  # don't write a .retry file listing failed hosts next
                              # to the playbook on failure — mostly noise for a
                              # 2-node lab, easy to re-run the same command instead
roles_path = roles
stdout_callback = yaml       # formats task output as readable YAML instead of the
                              # dense default JSON-ish format — this is the biggest
                              # lever on how pleasant `ansible-playbook` output is
                              # to actually read
log_path = ../logs/ansible.log   # persistent run log — see "Logging" below
```

### `inventory/hosts.ini`

Defines every host once, then groups them by what needs to happen to them:

- `[rac_nodes]` — `oradbserv05`, `oradbserv06`. Most plays in `site.yml` target this
  group directly.
- `[rac_node1]` — just `oradbserv05`. Used for plays that must run exactly once
  against a single control point (`dbca_noncdb` — DBCA itself talks to the whole
  cluster via the response file's `nodelist`, it doesn't need to be invoked per node).
- `[time_master]` — `oemserver01`, the existing OEM VM, added here **only** as the
  chrony time source for this phase, not otherwise managed by this repo.
- `[chrony_targets:children]` — a **group of groups**: `rac_nodes` + `time_master`
  combined. The `chrony` role runs against this combined group in one play, then
  branches internally on `inventory_hostname == chrony_master_hostname` to decide
  server-vs-client config per host — one role, two behaviors, rather than two roles.
- `[standby_nodes]` — `oradbserv07`/`oradbserv08`, Phase 2's Data Guard target.
  Listed now so the inventory shape is ready later; **not** targeted by anything in
  `site.yml` today — these hosts don't exist yet.

### `group_vars/all.yml`

Every role and template reads from here — hostnames, IPs, OFA paths, ASM disk/diskgroup
layout, patch IDs and filenames, GIDs, passwords (placeholders — see the security note
below). "Single source of truth" isn't just a description, it's load-bearing: e.g.
`grid_home` is referenced by `os_prep` (to create the directory), `grid_install.rsp.j2`
(to render the response file), `verify_baseline` (to check ownership), and
`grid_silent_install` (to know where `gridSetup.sh` lives) — change it once here, not
in four places.

### `site.yml` — the plays, in order

| Play (tag) | Hosts | What it does |
|---|---|---|
| `os_prep` | `rac_nodes` | Preinstall RPM, kernel/sysctl tuning, I/O scheduler, ulimits, sudoers, OS accounts/groups, OFA directory tree, `/u01` partition+mount |
| `verify_baseline` | `rac_nodes` | Read-only assertion checks — confirms a node actually matches what `os_prep` should have produced. Run before cloning, and again on the clone (drift can creep in from the manual personalization step) |
| `dns_bind` | `rac_nodes` | BIND — `oradbserv05` primary/authoritative, `oradbserv06` secondary via AXFR zone transfer, SCAN's 3-IP round-robin |
| `chrony` | `chrony_targets` | `oemserver01` as local time master, both RAC nodes as clients |
| `asmlib_disks` | `rac_nodes` | ASMLib package install + shared-disk marking (`oradbserv05` marks, `oradbserv06` discovers the same disks by header, not by re-marking) |
| `ssh_equivalence` | `rac_nodes` | Passwordless SSH for `grid`/`oracle` across both nodes (self included) — a genuine GI/OUI prerequisite, not just for `cluvfy`; see `docs/known-risks.md` #6 for the hang this fixes. Generalised 2026-08-31 (#141): takes `ssh_equiv_sources`/`ssh_equiv_targets`/`ssh_equiv_users`/`ssh_equiv_bidirectional`, with defaults reproducing the original mesh, so it also covers point-to-point trusts and replaces `cross_cluster_ssh_trust`. Its work runs **once per play**, not once per host — every task is `delegate_to`-driven, so the play's host loop would otherwise duplicate the whole mesh concurrently |
| `patch_before_config` | `rac_nodes` | Confirms GI/DB Release Update zips are staged, unzips them into the shared `patches/` directory — does **not** apply anything itself, just gets patches on disk and ready for the next two roles' `-applyRU` |
| `grid_infrastructure` | `rac_nodes` | Whole GI lifecycle, two-phase (renamed from `grid_install` 2026-08-09 — see `docs/known-risks.md` #20): stage+patch software (`gridSetup.sh -applyRU`, `CRS_SWONLY`), configure the cluster (`config.sh`, `CRS_CONFIG`), then `DATA02`/`RECO01` diskgroup creation via `asmca` + OCR multiplexing. Sub-tags `grid_stage` / `grid_install_software` / `grid_configure_cluster` / `grid_storage` target one stage at a time |
| `db_software` | `rac_nodes` | DB software lifecycle (renamed from `db_install` 2026-08-09): stage software, then install, patched via `-applyRU` + `-applyOneOffs` (RU and OJVM) during the same invocation. Sub-tags `db_stage` / `db_install_software` |
| `dbca_noncdb` | `rac_node1` | Silent DBCA — builds the General Purpose, non-CDB database across both instances; verifies DBCA's own automatic `datapatch` run landed cleanly |

Each row is a separate **play** (not just a tag on one giant play) — that's why running
`site.yml` with no `--tags` re-gathers facts and re-evaluates every play's `hosts:` line
in sequence, rather than behaving like one monolithic script.

## Patterns repeated across every role

Once you recognize these, reading any `tasks/main.yml` in this repo gets much faster:

- **`register` + `debug`, immediately after almost every consequential command.** This
  is the repo's own built-in detailed-logging layer, on top of anything Ansible itself
  provides — `gridsetup_result`, `dbinstall_result`, `dbca_result`, `cluvfy_result`,
  `crs_status`, `sqlpatch_check`, and others are all `register:`'d and then immediately
  shown via a `debug: var: X.stdout_lines` task. That's deliberate: it's the same
  output you'd see running the command by hand, surfaced back into the Ansible run
  rather than left invisible on the remote host.
- **`run_once: true` + `delegate_to: "{% raw %}{{ groups['rac_nodes'][0] }}{% endraw %}"`** on the software
  staging/install tasks in `grid_silent_install`/`db_silent_install`. This matches real
  Oracle behavior, not just a staging choice: OUI copies the home to every node in the
  response file's node list over SSH equivalence as part of one invocation — you don't
  invoke the installer per node. `root.sh`, by contrast, genuinely has to run on both
  nodes, so it's deliberately **not** `run_once`.
- **`stat` + `fail` staging guards.** `patch_before_config`, and the OPatch-update steps
  in `grid_silent_install`/`db_silent_install`, check a file exists and fail with a
  specific, actionable message (exact expected path, why) rather than letting
  `unarchive` fail on a missing source with a generic Ansible error.
- **`creates:` idempotency guards** on `unarchive`/extraction tasks — re-running a tag
  after a partial failure doesn't re-extract 2.5GB zips that already landed correctly.
- **`changed_when`/`failed_when` overrides on `command` tasks.** Unlike most Ansible
  modules, `command`/`shell` have no built-in concept of "changed" — by default *every*
  run reports `changed`, even a `crsctl stat res -t` that changed nothing. Roles here
  override this explicitly (e.g. `changed_when: false` on pure status checks,
  `failed_when: rc not in [0, 6]` on `gridSetup.sh` since exit code 6 means "succeeded,
  root scripts pending," not failure).

## Debugging and logging

### What's already built in, in this repo

The `register`/`debug` pattern above is the first place to look — if a task you care
about failed or you want to double check its output, search that role's
`tasks/main.yml` for the task name from your terminal output, and the very next task is
almost always a `debug` showing exactly what it printed.

### Ansible's own tools

**Verbosity — `-v` through `-vvvv`.** Each `v` adds a layer:
- `-v` — shows the full result dict for each task (not just ok/changed/failed), useful
  for the raw payload of a `debug` task longer than a couple of lines.
- `-vv` — adds task file path and line number, plus more module internals.
- `-vvv` — adds the raw module arguments as sent to the managed node, and SSH
  connection details (the exact `ssh` command Ansible ran) — the level to reach for
  when a task fails and you can't tell if the problem is the command itself or how
  Ansible invoked it.
- `-vvvv` — adds SSH debug output (`ssh -vvv` equivalent) — for connectivity failures
  specifically (auth, host key, network), not module logic.

**`--check` and `--diff` — read the fine print for this repo specifically.** `--check`
(dry run) and `--diff` (show before/after for file changes) work well for
`template`/`copy`/`file`/package-manager tasks. They do **not** meaningfully dry-run
`command`/`shell` tasks — which is most of the impactful work here (`gridSetup.sh`,
`runInstaller`, `dbca`, `opatch`, `asmca`, `cluvfy`). Ansible has no way to safely
simulate what an arbitrary shell command would do, so in `--check` mode these tasks are
skipped by default and reported as `skipped`, not simulated. Practical effect: `--check`
against this repo will accurately preview `os_prep`'s file/package changes, but won't
tell you anything about what `grid_infrastructure` or `dbca_noncdb` would actually do.
**Security note if you do use `--diff`:** several rendered templates
(`grid_install.rsp`, `grid_install_swonly.rsp`, `db_install.rsp`, `dbca_gp_noncdb.rsp`)
contain the SYS/SYSTEM/
SYSASM passwords from `group_vars/all.yml` in plaintext (that's why they're rendered
`mode: "0600"`) — a diff of those files prints the same plaintext to your terminal and,
now, to `logs/ansible.log`. Fine for this lab's placeholder passwords; worth remembering
if you ever point `sys_password`/`system_password` at anything real.

**Preview without executing:**
```bash
ansible-playbook site.yml --tags grid_infrastructure --list-tasks   # every task name that would run
ansible-playbook site.yml --list-tags                                # every tag defined in the playbook
ansible-playbook site.yml --tags grid_infrastructure --list-hosts   # which hosts this tag would touch
ansible-playbook site.yml --syntax-check                             # YAML/structure validity, no connections made
```

Narrower sub-tags work the same way — e.g.
`--tags grid_configure_cluster --list-tasks` shows only Phase B's tasks.

**Step through interactively:**
```bash
ansible-playbook site.yml --tags grid_infrastructure --step         # confirm (y/n/continue) before EACH task
ansible-playbook site.yml --tags grid_infrastructure --start-at-task "Run gridSetup.sh silently (software-only, CRS_SWONLY), patched via -applyRU"
```
`--start-at-task` takes the exact task name string (from `- name:` in the role) — useful
for resuming a long play after fixing something without re-running everything before it.

**Inspect the inventory structure directly** (handy given `hosts.ini`'s overlapping
groups above):
```bash
ansible-inventory -i inventory/hosts.ini --graph
ansible-inventory -i inventory/hosts.ini --list
```

### Logging — persistent, not just terminal scrollback

As of this doc, `ansible.cfg` sets:
```ini
log_path = ../logs/ansible.log
```
Every run from now on appends its full task-by-task output to
`phase-01-foundation-2node-rac-12cR2/logs/ansible.log` — the same content that scrolled
past in your terminal, kept around so you can `grep`/scroll back through a run after the
fact, or compare two runs. Gitignored (repo root `.gitignore`) for the password-in-diff
reason above. Nothing to do differently day to day — it's automatic — but if you want a
clean log for a specific run, `rm ../logs/ansible.log` first (or just `tail -f` it in a
second terminal while a long play runs).

**Optional, not currently installed:** the `ansible.posix.profile_tasks` callback adds
per-task timing to the output — useful for spotting which task in a long install (RU
extraction? `-applyRU` itself? `cluvfy`?) is actually eating the wall-clock time.
Requires `ansible-galaxy collection install ansible.posix` first, then
`callbacks_enabled = ansible.posix.profile_tasks` in `ansible.cfg`'s `[defaults]`. Not
enabled by default here since it's an extra dependency for a lab this size — add it if
a specific play's runtime becomes worth investigating.

**Remote module debugging (rare, but real):** by default Ansible copies its Python
module to a temp directory on the managed node, runs it, and deletes it. Setting
`ANSIBLE_KEEP_REMOTE_FILES=1` (env var on the control node, applies to the next run)
skips the cleanup, leaving the exact module + arguments Ansible sent under
`~ansible/.ansible/tmp/` on the managed node — useful if `-vvv`'s inline module-args
dump still isn't enough to explain a task's behavior.

### Beyond Ansible: Oracle's own logs, on the managed node

Ansible's `debug` tasks only show you what a command printed to **stdout/stderr** —
Oracle's installers write much more detailed logs to disk on the managed node that
Ansible never touches unless a task explicitly goes and fetches them. Worth knowing
these paths directly, especially when a `debug` task's captured stdout ends in a vague
`[FATAL]` or `[WARNING]` with a "see the log" pointer:

- `$ORACLE_BASE/oraInventory/logs/` — OUI/`gridSetup.sh`/`runInstaller` session logs,
  one directory per invocation timestamp (`InstallActions<timestamp>/`).
- `/tmp/InstallActions<timestamp>/installActions<timestamp>.log` and
  `make.log` in the same directory — the actual compile/link output referenced by the
  `-applyOneOffs` OJVM failure mode documented in `patching-strategy.md`.
- `$ORACLE_HOME/cfgtoollogs/dbca/<db_name>/` — DBCA's own detailed log, well beyond
  what `dbca -silent`'s stdout shows.
- `$GRID_BASE/crsdata/<hostname>/crsconfig/` — `gridSetup.sh`'s cluster-configuration-
  phase logs, root script output, and the `rootcrs.sh`/`rootcrs_<host>.log` files —
  the first place to look if `root.sh` on node 2 behaves differently than node 1.
- `$ORACLE_HOME/cfgtoollogs/opatchauto/` and `$ORACLE_HOME/OPatch/opatch<timestamp>.log`
  for `opatch`/`opatchauto`/`datapatch` runs (`datapatch` also logs under
  `$ORACLE_HOME/sqlpatch/`).

None of this is fetched back to the control node automatically today — a possible
future enhancement (not built yet) would be a small set of `fetch:` tasks pulling the
relevant log directory back after each install role, timestamped, for the showcase
posts' "here's the actual evidence" sections — parallel to the AHF compliance
before/after reports already called for in `patching-strategy.md`.
