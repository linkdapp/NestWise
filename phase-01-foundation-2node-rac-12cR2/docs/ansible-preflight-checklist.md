---
title: Ansible design checklist — walk this BEFORE handing code over to be run
---

# Ansible design checklist

**Walk this before any new or edited Ansible code is handed over for execution.**
Not after it fails.

`known-risks.md` holds 145 entries, many of them hours of live debugging against a
real lab. Every item below is a trap this project has already hit and paid for.
Re-discovering one is a self-inflicted outage.

The failure mode this document exists to prevent is specific and was diagnosed
in #145: **a trap documented as a comment on the code that avoids it is invisible
to the person writing new code.** Comments reach readers of the cured; a checklist
reaches the author of the next patient. Where a check can be mechanised it lives
in `ansible/syntax-check.sh` instead of here.

Order matters — the structural checks are cheapest and catch the most.

---

## 1. Play structure

| ✔ | Check | Ref |
|---|---|---|
| | `hosts: localhost` play that uses `delegate_to`? **Do NOT add `connection: local`.** It pins every task, including delegated ones, to the control node — while the output still reads `[localhost -> host]`. Symptoms: `sudo: a password is required`, `chmod: invalid mode: 'A+user:oracle:rx:allow'`, generic MODULE FAILURE. | #48, #145 |
| | `hosts: localhost` play with control-node-only tasks? `ansible.cfg` sets `become = True` globally and it applies here too — override `become: false` on those tasks. | #94 |
| | Does the play's `hosts:` group actually contain the hosts the role needs? A play's `hosts:` can be narrowed by `--limit`, never widened. A role that cannot reach its targets is a role that cannot run. | #47 |
| | New tag added? Add it to **both** bootstrap plays' explicit tag lists in `site.yml`, or python3 will not exist on a fresh node when the role runs. Do not use `tags: [always]` on those plays — it fires regardless of `--tags`. | #55 |
| | Role delegates to a fixed node? Use `groups['rac_node1'][0]` / `groups['standby_nodes'][0]` consistently, and make sure the playbook and the role agree. Two spellings that resolve to the same host today are luck, not design. | #61 |
| | **Which OS user does this play run as?** Not "is become on or off" — name the user. Oracle work is `become: true` + `become_user: "{{ oracle_user }}"`. `become: false` means the `ansible` login user, which owns nothing under `/u01`. | #148 |
| | Play sets `become_user`? Then every task needing root must say `become_user: root` **explicitly** — a bare `become: true` inherits the play's user. Especially dangerous on a task that also has `failed_when: false`. | #148 |
| | Copying between hosts? Use `command:` with the real `rsync` binary, not `ansible.posix.synchronize` — this project takes no ansible.posix dependency, and `synchronize` picks the remote user from the connection user, ignoring `become_user`. | #148 |
| | **Read the sibling role that already solved this.** `db19c_software_install` has cross-cluster copy; `dataguard_fsfo` has oemserver01 become; `ssh_equivalence` has SSH trust. A checklist catches recurring traps — it does not replace reading neighbouring code. | #148 |
| | Role must work on **both** clusters? Drive it from `nodes` (redirected per `group_vars/<group>.yml`), never a hardcoded `groups['rac_nodes']` — that is inventory-global and leaks across clusters. | #52, #58, #59, #61 |

## 2. Shell and SQL\*Plus tasks

| ✔ | Check | Ref |
|---|---|---|
| | Using `shell: \|`, never `shell: >`. A folded scalar collapses newlines to spaces and destroys heredoc SQL. | #77 |
| | Jinja block tags (`{% if %}`) indented to match the shell body, never at column 0 — a shallower-indented line ends the YAML block scalar. | #143 |
| | Heredoc terminator at the block's base indent, so it lands at column 0 in the resulting string. | #143 |
| | No backslash before an end-of-line quote (`echo "... \\"`). Ansible's argument splitter treats the quote as escaped and never closes the string. | #144 |
| | No prose apostrophes in comments **inside** a `shell:`/`command:` block. That text is module free-form, not a comment — one unmatched `'` unbalances the whole block. Put explanations in task-level YAML comments, which are stripped before templating. | #153 |
| | `export ORACLE_HOME=...` — bare `ORACLE_HOME=... ORACLE_SID=...` on its own line never reaches `sqlplus`'s environment. | #78 |
| | `command:` does not source a shell environment. Anything needing `ORACLE_HOME` uses `shell:` with explicit `export`. | #83, #84 |
| | **No `sqlplus -s`.** Standing convention: full transcript-style output on every task, and a `debug: var: <reg>.stdout_lines` immediately after. Never silent. | #80 |
| | Want the SQL statements echoed too? `SET ECHO ON` does **not** work on heredoc stdin — it only echoes scripts run with `@`. Write the SQL to a `.sql` file and run `@file`. | #82 |
| | `SET TAB OFF` and `TRIMSPOOL ON` in every SQL\*Plus session — the default pads output with tabs. | — |

## 3. Checking results

| ✔ | Check | Ref |
|---|---|---|
| | Does the output being searched actually reach `stdout`? `rman cmdfile=... log=...` sends everything to the log file, so any `failed_when` on `stdout` is unconditionally true. | #109 |
| | Matching a **positive success marker**, not the absence of an error string. `'RMAN-' in stdout` fails a healthy backup — RMAN emits informational `RMAN-08xxx` constantly. | #109 |
| | Can the search string appear in the **echoed command** as well as the result? `set -x` and `SET ECHO ON` both put the query text in the captured stream. Grepping for `MRP` matched the SQL that mentions MRP. | #121 |
| | Regex accounts for SQL\*Plus formatting — a right-justified `count(*)` broke a `remaining-count` match that assumed left alignment. | #122 |
| | `failed_when: false` on a task whose failure actually matters? That is how a silently-never-created directory got through. | #97 |
| | **Looped task? Do NOT put a real condition in its `failed_when`.** This project's convention, used in 8+ roles: loop → `register` → `failed_when: false` → a **separate following task** evaluates `.results`. Scope inside a loop-scoped conditional is not worth guessing at; after the loop, `.results` is unambiguous. | #97, #99, #130, #154 |
| | Success of a registration step is not the same as the thing working. "Registered with CRS" ≠ "running". | #125, #126 |

## 4. Variables and tags

| ✔ | Check | Ref |
|---|---|---|
| | `set_fact` tasks that later tasks depend on carry `tags: [always]` — otherwise a narrow `--tags` run leaves them undefined and the role dies on a templating error. | #71 |
| | A variable that defaults to a **safe-looking** value when its source task was skipped is a trap. Fail loudly instead. (`oem_repo_is_cdb` defaulting false on a CDB.) | #142 |
| | No `REPLACE_ME` left unguarded — fail fast rather than guessing a patch number, path or password. | #113 |
| | Editing `group_vars/all.yml`? Check the edit did not orphan a list item into the next key's value. YAML will fold it silently. | #79 |
| | Variables match reality, not intent — `RECO` vs the `RECO01` that actually exists. | #43 |
| | `include_tasks` with a `loop:` **always** sets `loop_control: loop_var:`. Include vars are lazy — any loop inside the included file rebinds `item` and silently re-evaluates them against the wrong element. Ansible warns, then proceeds. | #147 |
| | Converting a hardcoded single case into a loop over cases? Review specifically for what the **new loop shadows**. The new failure modes are not in the diff — they are in the interaction with code that was already there. | #147 |

## 5. Idempotency and destructive steps

| ✔ | Check | Ref |
|---|---|---|
| | Expensive or destructive steps guarded with `creates:`, a marker file, or a real state check — never assumed safe to re-run. | #14 |
| | The guard checks something that only the completed step could produce. "Owned by root" did not prove `root.sh` had run; `/etc/oracle/olr.loc` did. | #32, #68 |
| | Check-then-act guards actually work on this environment before relying on them — `asmcmd ls` reported directories missing that demonstrably existed. | #99, #130 |
| | A step that stops a database or a service has a confirm gate or a pause, and cannot be reached by a broad `--tags`. | #129 |
| | Files modified in place (`tnsnames.ora`, `listener.ora`, `authorized_keys`) are appended to or backed up, never wholesale overwritten. | #85, #141 |

## 6. Before handing over

| ✔ | Step |
|---|---|
| | `bash syntax-check.sh` passes — all seven checks. |
| | Every item above consciously considered, not skimmed. |
| | Anything genuinely new and unverified is stated as unverified in the handover, not presented as done. |
| | New trap discovered? Add a `known-risks.md` entry **and**, if it is mechanically detectable, a check in `syntax-check.sh`. A comment alone does not prevent recurrence — that is what #145 proved. |

---

## Known outstanding deviations

Recorded rather than quietly carried, so they are decisions and not oversights.

- **`oem_repo_patch` does not yet meet #82's script-file convention.** `-s` has been
  dropped from all six SQL\*Plus calls, so the banner, `SQL>` prompts and results
  now appear. The statement text still does not, because the SQL is fed via heredoc
  and `SET ECHO ON` has no effect on stdin. Fully meeting the convention means
  writing each block to a `.sql` file and running it with `@`, as
  `dataguard_primary_prep` does. Not done; the tasks that most need it are the
  pre/post baselines, which already `tee` their full output to a file.
