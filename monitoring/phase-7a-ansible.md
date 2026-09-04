---
title: Phase 7a — Ansible reference
---

# Phase 7a — Ansible reference

The companion to the Phase 7a runbook, which is split into an index and three
parts:

| | |
|---|---|
| [Index](phase-7a-repository-db-ru32.md) | environment, the result, why the phase comes first, open questions |
| [Part 1 — Before the window](phase-7a-part1-before-the-window.md) | §§1-5: prerequisites, syntax check, preflight, staging, pre-window checks |
| [Part 2 — The patch window](phase-7a-part2-the-patch-window.md) | §§6-12: OPatch, the blackout pause, shutdown, backup, rollback, apply |
| [Part 3 — Datapatch, verification and aftermath](phase-7a-part3-verification.md) | §§13-19: datapatch, `extjob`, restart, verification, rollback, screenshots |

Those are the runbook: what happens to the database, in what order, and why. This
one is the automation behind it — roles, tags, variables, and the design
decisions that are only interesting if you are editing the code.

If you are running the patch, you want the runbook. If you are changing how it
runs, you want this. The blackout, which the automation deliberately does not
create, has its own page:
[Creating a Blackout in Enterprise Manager 13.5](oem-create-blackout.md).

---

## What runs where

| | |
|---|---|
| Playbook | `phase-01-foundation-2node-rac-12cR2/ansible/oem-repo-patch.yml` |
| Role | `ansible/roles/oem_repo_patch` |
| Trust role | `ansible/roles/ssh_equivalence` |
| Variables | `ansible/group_vars/all.yml`, the Phase 7a block |
| Target | `[observer_nodes]` — `oemserver01`, already Ansible-managed by `dataguard_fsfo` |

All commands run from `phase-01-foundation-2node-rac-12cR2/ansible` as the
`ansible` user on the controller.

### A separate playbook, not a play in `site.yml`

Deliberate. `site.yml` builds the RAC and Data Guard estate, and nothing in it
should ever be one broad tag away from stopping the OMS and shutting down the
repository database.

The role also refuses to run at all without `-e oem_patch_confirm=yes`. That gate
is the substitute for the manual pause `patching-strategy.md` uses before
applying a patch — see [Why this one is automated](#why-this-one-is-automated).

---

## Tags

| Tag | Does | Safe to run any time |
|---|---|---|
| `oem_repo_patch_preflight` | SID discovery, home proof, free space, CDB check, baselines | yes, read-only |
| `ssh_trust` | `oracle@oradbserv05` → `oracle@oemserver01` only | yes, idempotent |
| `oem_repo_patch_stage` | trust, then copy and unzip the RU | yes, `creates:`-guarded |
| `oem_repo_patch_opatch` | OPatch update, min-version check, conflict check | yes, read-only after the update |
| `oem_repo_patch_shutdown` | blackout, pause, stop agent/OMS/listener/database | **no** |
| `oem_repo_patch_backup` | RMAN backup, guaranteed restore point | no |
| `oem_repo_patch_apply` | `opatch apply` | no |
| `oem_repo_patch_datapatch` | startup, datapatch, catcon.pl utlrp, extjob | no |
| `oem_repo_patch_verify` | post baselines, comparisons, summary | yes |
| `oem_repo_patch_restart` | listener, OMS, agent, clear blackout | no |

Everything above `oem_repo_patch_shutdown` in that table is worth running days
before the window rather than inside it.

### Why several `set_fact` tasks carry `tags: [always]`

`oem_repo_log`, `oem_run_ts`, `oem_repo_sid`, `oem_repo_is_cdb` and the pre-patch
counters are referenced by tasks much later in the role. Without `always`, running
a single tag such as `--tags oem_repo_patch_apply` leaves them undefined and the
role dies on a templating error instead of doing the work.

---

## The SSH trust

The RU zip lives on `oradbserv05` from the GI build and is multi-GB. The copy is a
direct `rsync` push rather than a round trip through the Ansible controller, which
needs `oracle@oradbserv05` → `oracle@oemserver01` passwordless SSH.

```yaml
- role: ssh_equivalence
  vars:
    ssh_equiv_sources: ["{{ groups['rac_node1'][0] }}"]
    ssh_equiv_targets: ["{{ groups['observer_nodes'][0] }}"]
    ssh_equiv_users: ["{{ oracle_user }}"]
    ssh_equiv_bidirectional: false          # nothing needs the reverse
    ssh_equiv_include_self: false           # a copy, not a cluster mesh
    ssh_equiv_manage_system_config: false   # leave oemserver01's /etc/ssh alone
```

That last flag matters: `oemserver01` sits outside this project's build, and
rewriting a foreign host's system SSH config is more intrusive than a
one-directional file-copy trust warrants. Per-user `known_hosts` is enough.

The play targets `hosts: localhost` — and deliberately **does not** set
`connection: local`. Every task in the role is `delegate_to`-driven, so the play
needs somewhere to run *from*, not a host to run *against*; `oemserver01` cannot
be that host, because the whole point is that the trust does not exist yet.

> **Do not add `connection: local` to this play.** Set explicitly at play level it
> pins every task to a local connection *including delegated ones* — `delegate_to`
> does not override it. Tasks then execute on the WSL2 control node while the
> output still reads `[localhost -> oradbserv05]`, and fail at the connection or
> become layer with `sudo: a password is required`, a generic MODULE FAILURE, or
> `chmod: invalid mode: 'A+user:oracle:rx:allow'` — the last being Ansible trying
> to hand a temp file to an `oracle` user that does not exist on the controller.
>
> This has now bitten this project twice: `known-risks.md` #48 and #145.
> `syntax-check.sh` check 7 warns on it.

### Checking it by hand

The automation is not doing anything clever here, and it should not look like it
is. The whole test is one command, run as the source user on the source host:

```bash
# as oracle on oradbserv05
ssh oracle@oemserver01 hostname
```

If that prints a hostname with no password prompt and no host-key question, the
trust works. Nothing else needs checking. The same one-liner covers the GI mesh —
what James runs to spot-check it:

```bash
# as oracle on oradbserv05
ssh oracle@oradbserv06 date
ssh oracle@oradbserv09 date
```

The role runs exactly that command, twice — once before deciding whether to do
anything, once afterwards to prove it. It adds two flags and nothing else:

| Flag | Why |
|---|---|
| `-o BatchMode=yes` | Refuses to prompt. Without it an unconfigured trust does not fail, it **hangs** — Ansible allocates no PTY, so the password prompt waits forever. That is `known-risks.md` #6, the same silent hang that stalls `cluvfy` and `gridSetup.sh`. |
| `-o ConnectTimeout=5` | Bounds an unreachable host to five seconds rather than the default two-minute TCP wait. |

Interactively neither matters — you see the prompt and press Ctrl-C. In
automation they are the difference between a five-second failure and a run that
never returns.

`hostname` rather than `date` only because it names *which* host answered, which
is worth having when a stale `known_hosts` entry or a wrong alias sends you
somewhere unexpected. `date` verifies just as well.

**So why is the role not three lines?** For this one pair it nearly is — check,
configure if needed, verify. The bulk of the role exists for the Grid
Infrastructure mesh, which needs things a point-to-point trust does not: PEM-format
keys for `gridSetup.sh`'s bundled Java client (#16), the system-wide
`/etc/ssh/ssh_known_hosts`, the `CheckHostIP` carve-out (#64), and every host
trusting every other host including itself. Phase 7a switches almost all of that
off — `ssh_equiv_manage_system_config: false`, `ssh_equiv_include_self: false`,
`ssh_equiv_bidirectional: false` — which is why its run is short.

### Where this role came from

Two roles used to do the same job at different scales. `ssh_equivalence` built the
bidirectional `grid` + `oracle` mesh across a cluster for the Grid Infrastructure
prerequisite; `cross_cluster_ssh_trust` was that same logic hardcoded to one pair,
`oradbserv05 → oradbserv09`, for Phase 6's software copy.

Every hard-won detail had to be remembered twice — PEM-format keys for
`gridSetup.sh`'s bundled Java client (`known-risks.md` #16), no pre-seeded IP
entry (#62), no `UserKnownHostsFile /dev/null` (#63), `CheckHostIP` off (#64) —
and the two had already drifted on how `known_hosts` was written.

`ssh_equivalence` now takes sources, targets, users and a direction:

| Variable | Meaning | Default |
|---|---|---|
| `ssh_equiv_sources` | hosts the connection originates from | every host in `nodes` |
| `ssh_equiv_targets` | hosts it connects to | every host in `nodes` |
| `ssh_equiv_users` | OS users to configure | `grid`, `oracle` |
| `ssh_equiv_bidirectional` | also authorise target → source | `true` |
| `ssh_equiv_include_self` | let a host SSH to its own name (GI needs this) | `true` |
| `ssh_equiv_manage_system_config` | write `/etc/ssh` on the sources | `true` |
| `ssh_equiv_run_once` | do the work once per play, not once per host | `true` |

The defaults reproduce the original mesh exactly, so `site.yml`'s
`ssh_equivalence` and `standby_ssh_equivalence` plays needed no changes.
`cross_cluster_ssh_trust` survives as a deprecation shim forwarding to the new
interface, so `upgrade-19c-rolling.yml` keeps working until its call site is
updated and re-tested.

### `ssh_equiv_run_once` — leave it alone

The consolidation had one non-obvious consequence, caught before it ran
(`known-risks.md` #141). Making every task `delegate_to`-driven is what lets one
role express `oradbserv05 → oemserver01` at all — but it also means the work no
longer depends on which host the play is iterating. A play across `rac_nodes`
would build the entire mesh **twice, concurrently**, with both forks running
`lineinfile` against the same `authorized_keys` on the same target. That is a
read-modify-write race that can silently drop a key, and a missing authorized key
is the failure where `gridSetup.sh` hangs with no output.

`tasks/main.yml` is now a one-task wrapper that includes the real work under
`inventory_hostname == ansible_play_hosts[0]`.

---

## Variables worth knowing about

Full set in `group_vars/all.yml`. These are the ones you might actually change.

| Variable | Default | Effect |
|---|---|---|
| `oem_patch_confirm` | *(unset)* | must be `yes` or the role refuses to run |
| `oem_repo_apply_mechanism` | `opatch` | `opatchauto` is a fallback that should not be needed |
| `oem_repo_conflict_check_fatal` | `true` | fail the run if the conflict check returns non-zero |
| `oem_repo_datapatch_sanity_checks` | `true` | run `datapatch -sanity_checks` before `-verbose` |
| `oem_repo_pause_after_blackout` | `true` | stop and wait for Enter after the blackout starts |
| `oem_repo_take_rman_backup` | `true` | full compressed backup plus archivelog before patching |
| `oem_repo_create_restore_point` | `true` | guaranteed restore point; needs ARCHIVELOG plus an FRA |
| `oem_repo_min_free_gb` | `10` | preflight floor on the mount holding the Oracle home |
| `oem_repo_expected_targets` | `43` | post-patch target count to compare against |

### `oem_repo_apply_mechanism` — why `opatch`

Patch 39472050's own README §3.2 documents plain `opatch apply` for the non-RAC
case. An earlier version of this project's notes said to expect a *"This command
doesn't support System Patch"* refusal and fall back to `opatchauto`, citing the
confirmed 12.2 GI finding.

That finding is real and it is about a different patch. **39467003, the combo, is
the system patch. 39472050, the Database RU component inside it, is not** — and
39472050 is what this home gets, because `oemserver01` has no Grid
Infrastructure, so the combo's ACFS / Tomcat / DBWLM components are out of scope.
The `opatchauto` path stays available because keeping the fallback costs nothing,
but reaching for it would now be a signal that something else is wrong.

Full write-up: `known-risks.md` #142.

### `oem_repo_conflict_check_fatal` — why it defaults true

The conflict check used to end in `|| true`, justified by the assumption above: if
a refusal is expected, swallowing the return code looks reasonable. With that
assumption gone, it was simply a check that could not fail.

Set it false only after reading the report and deciding deliberately that the
conflict is ignorable — the report distinguishes genuine **conflicts** from
**superset** patches, and a superset is fine. Write down why.

---

## Design notes for anyone editing the role

**CDB detection is not decorative.** `SELECT cdb FROM v$database` returns `NO`
today, so the `ALTER PLUGGABLE DATABASE ALL OPEN` branch is dormant. It stays
because Phase 7d converts this database, and on that day a hardcoded non-CDB path
would silently patch only `CDB$ROOT`.

**The Jinja `if`/`endif` in the startup task sits at column 0 on purpose,** with
the SQL inside keeping its indent. Ansible templates with `trim_blocks` on
(`known-risks.md` #70 is the response file that setting mangled), so the newline
after each block tag is eaten and the tag lines vanish cleanly. Indenting them to
match the SQL would leave stray whitespace. Do not tidy it.

**`opatch` and `opatchauto` register to separate variables** (`oem_apply_opatch`,
`oem_apply_opatchauto`). Registering both to one name looks tidier and is a real
bug: the skipped task still registers a result and overwrites the successful one,
so the output task comes back empty.

**Every shell task tees to the run log and uses `set -x`.** A patch you cannot
reconstruct afterwards is a patch you cannot defend in a post-incident review.
Every SQL\*Plus heredoc sets `TAB OFF` and `TRIMSPOOL ON` — SQL\*Plus defaults to
`TAB ON` and pads output with tab characters, which mangles alignment in captured
output.

**Comparisons, not absolutes.** The invalid-object and `dba_registry` checks
compare post against pre. A count that returned to its pre-patch level is clean
whatever that level is; insisting on zero invites someone to "fix" pre-existing
invalid objects mid-window, which is a second change wearing the first one's
clothes.

**A looped task never carries a real `failed_when`.** House convention, used in
at least eight roles here (`os_prep`, `db19c_software_install`, `asmlib_disks`,
`dataguard_role_services`, `dataguard_net_config`, `dataguard_switchover_test`,
`rolling_postupgrade`, `ssh_equivalence`): loop → `register` →
`failed_when: false`, then a **separate following task** evaluates `.results`.
Two attempts at a per-iteration `failed_when` on the combo-component check both
failed against directories that plainly existed (`known-risks.md` #154). Scope
inside a loop-scoped conditional is not worth guessing at; after the loop,
`.results` is unambiguous.

Note `map(attribute='stat.isdir', default=false)` when reading those results —
for a path that does not exist, `stat` returns `exists: false` and carries no
`isdir` key at all, so the lookup raises without the default.

**Idempotency guards must key on the thing they prove.** The combo unzip is gated
on both component directories, not on `creates:` pointing at the parent
`39618649/`. The parent-directory guard skipped the unzip when a single component
had been deleted — which is exactly the state a re-extract test produces — and
then failed verification with no route to recovery. Same class as #32 and #68,
where a guard checked something adjacent to what it was meant to prove. Deleting
a component and re-running is a supported test; the role recovers.

---

## Syntax checking and audit

### Run this before every window

A static read is not a syntax check. From
`phase-01-foundation-2node-rac-12cR2/ansible`:

```bash
bash syntax-check.sh
```

Six checks, exits non-zero if any fails:

| # | Check | Catches |
|---|---|---|
| 1 | `yaml.safe_load` on every `*.yml` | YAML errors in files no playbook reaches |
| 2 | `ansible-playbook --syntax-check` per playbook | Ansible parse errors that are valid YAML |
| 3 | Jinja tags at column 0 | block-scalar termination (#143) |
| 4 | Heredoc opener/terminator balance | an unclosed `<<'SQL'` |
| 5 | Literal tabs | illegal YAML indentation, invisible in most editors |
| 6 | Backslash before end-of-line quote | Ansible's splitter never closing the string (#144) |
| 7 | `connection: local` alongside `delegate_to` | delegated tasks silently running on the control node (#48, #145) |
| 8 | looping `include_tasks` without `loop_var` | inner loops rebinding `item` under lazy include vars (#147) |

**Checks 1 and 2 do not subsume each other**, which is the whole reason both are
here. Each has caught a real failure in this role that the other passed:

| | catches | misses |
|---|---|---|
| 1 — parse every file | malformed YAML anywhere, including files no play reaches | anything valid as YAML but invalid to Ansible |
| 2 — `--syntax-check` | Ansible-specific errors, e.g. `\\"` (#144) | any file no play currently reaches |

Check 3 exists because #143 was a YAML failure that a targeted grep names
precisely, rather than making you read a parser error. Check 6 exists for the same
reason with #144: check 2 catches it, but reports it by dumping a 20-line shell
body and pointing at the task header above the real line.

Invoke it with `bash syntax-check.sh`, not `./syntax-check.sh`. This repository
lives on an NTFS mount under WSL, where the executable bit often does not stick
and CRLF line endings can produce a `bad interpreter` error. Going through `bash`
sidesteps both.

Chain it ahead of anything destructive:

```bash
bash syntax-check.sh && ansible-playbook -i inventory/hosts.ini oem-repo-patch.yml \
  -e oem_patch_confirm=yes --tags oem_repo_patch_preflight
```

A `--check --diff` dry run is also available, though on this role most of the work
is `shell:` tasks, which report little under check mode:

```bash
ansible-playbook -i inventory/hosts.ini oem-repo-patch.yml \
  -e oem_patch_confirm=yes --check --diff
```

`ansible-lint` and `yamllint` are worth adding if installed, but neither replaces
check 1.

> **Why this is a script and not a couple of commands in this document.** It used
> to be two lines in one code block. They were pasted as a single line, and
> `ansible-playbook` read the second command's name as a second playbook argument
> — producing a wall of usage text and no check. A checking tool with a
> copy-paste hazard is not a checking tool.

### The trap this project has now hit

`{%` or `{{` at column 0 inside a `shell: |` block. A YAML block scalar's
indentation is fixed by its first non-empty line, and **any line at a shallower
indent ends the block**. So a Jinja tag written flush-left is not "outside the
SQL" — it is outside the string, and YAML then reads `{` as the start of a flow
mapping:

```
found character that cannot start any token
```

Indent Jinja block tags to match the rest of the shell body. YAML strips the
common indent, so Jinja still sees the tag at the start of its own line, and
`trim_blocks` removes the newline after `%}` so the tag line disappears rather
than leaving a blank.

The same indentation rule governs heredoc terminators, and for the same reason:
`<<'SQL'` requires its terminator at column 0 **of the resulting string**, which
means at the block's base indent in the file. A terminator indented one level
deeper is a heredoc that never closes.

Grep for both after editing any `shell:` block:

```bash
grep -rn '^{%\|^{{' --include='*.yml' .          # must return nothing
grep -rnc "<<-\?'\?[A-Z]\+'\?" --include='*.yml' . # openers, compare to terminators
```

### Audit performed 2026-08-31

Static review of all 40 task files and playbooks under `ansible/`.

| Check | Result |
|---|---|
| Jinja block tags at column 0 | **1 file, 2 lines — fixed** (`oem_repo_patch`, #143) |
| Backslash before end-of-line quote | **1 line — fixed** (`oem_repo_patch`, #144) |
| Heredoc openers vs terminators | 16 vs 16, balanced across 3 files |
| Heredoc terminator indentation | all at block base indent, correct |
| Literal tab characters | none |
| Unquoted `{{ }}` starting a YAML value | none (one match, inside a `>-` scalar, benign) |
| Orphaned task files | **1 — `ssh_equivalence/tasks/per_user.yml`, see below** |
| Partial-tag variable hazards | **1 found and guarded**, see below |

**`per_user.yml` is dead code.** It is the pre-rewrite mesh implementation,
superseded by `pair.yml` + `configure.yml`. Nothing includes it — no file in the
repository contains the string `per_user` except `known-risks.md`. Leaving it
invites someone to edit the wrong file while debugging an SSH problem:

```bash
git rm phase-01-foundation-2node-rac-12cR2/ansible/roles/ssh_equivalence/tasks/per_user.yml
```

Its content is preserved in `pair.yml`, and its history in `known-risks.md`
#61/#62/#63.

**Partial-tag hazard, now guarded.** `oem_repo_is_cdb` derives from a preflight
task, and its `set_fact` resolves to false when that task has not run — so
`--tags oem_repo_patch_datapatch` alone would silently take the non-CDB path on a
CDB, patching only `CDB$ROOT`. The role now fails with an explanation instead of
defaulting to the safe-looking value. Worth checking the other `set_fact` tasks
against the same question when adding tags.

**Not covered by this audit:** runtime behaviour. Everything above is structural.
Whether a task does the right thing, and whether variables resolve to sensible
values on the live hosts, is what steps 1-3 and the preflight tag are for.

`per_user.yml` has since been removed.

### What the 2026-09-04 run actually taught

The role ran clean end to end — `ok=88 changed=19 failed=0` — and the structural
audit above held: nothing it checked for recurred. Everything that went wrong
before that run was runtime behaviour, which is exactly what the last paragraph
above predicted the audit would not catch. Those are #145 through #154.

One defect survived into the successful run without failing it, and it is worth
naming because it is the kind that never fails anything:

**The post-datapatch log grep was pure noise.** `grep -R "ORA-"` across
`$ORACLE_BASE/cfgtoollogs/sqlpatch/` returned roughly three hundred lines on a
patch that succeeded on every other measure — Oracle's RU scripts declare
`IGNORABLE ERRORS: ORA-00955` in plain text and raise-and-swallow `ORA-00955` by
design for every object that already exists. The task was `failed_when: false`
and informational, so it gated nothing; it just buried the useful output. It has
been replaced by datapatch's own per-patch verdict, `... apply: SUCCESS ...
(no errors)`, with a comment in the task explaining why the grep is deliberately
absent. Full write-up: `known-risks.md` #155.

The general rule that came out of it, and out of #153 before it: **estimate a
new check's false-positive rate on a known-good run before shipping it.** A
check that cries wolf is worse than no check, because it teaches the reader to
scroll past the block where the real finding will one day appear.

---

## Why this one is automated

`patching-strategy.md` deliberately stops at a manual pause before applying a
patch, and that was right there: a RAC-registered 12.2 home, two cluster nodes,
and `opatchauto` behaviour not confirmed safe for a non-interactive task.

`oemserver01` is single-instance with no Grid Infrastructure, no second node and
no cluster registration, so the interactive risk that justified the pause is
absent. The safety comes from the confirm gate and the blackout checkpoint
instead.

## What stays manual, and why

- **AHF compliance check, either side** — the value is in diffing two reports and
  reading them, not in a task's `changed_when`
- **Dropping the guaranteed restore point** — only once a human agrees the patch
  is good, and it *must* be dropped, because it holds flashback logs indefinitely
- **RMAN recovery catalog upgrade** — needs credentials that do not belong in this
  repository, and it is not established that a catalog exists at all
- **Re-enabling optimizer-affecting bug fixes** (`DBMS_OPTIM_BUNDLE`) — changing
  plan behaviour as a side effect of a patch run is the opposite of what this
  window is for
- **Rollback** — a decision, not a flag someone passes at 2am

`utlrp` used to be on this list, on the grounds that it was a read-and-judge call.
It is not: with a pre-patch baseline captured, the recompile is deterministic and
the judgement moves to comparing the before and after counts.
