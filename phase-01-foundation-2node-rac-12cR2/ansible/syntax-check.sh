#!/usr/bin/env bash
#
# Static checks for every Ansible file in this directory tree.
#
# Run from phase-01-foundation-2node-rac-12cR2/ansible:
#
#     bash syntax-check.sh
#
# Invoke it via `bash` rather than ./syntax-check.sh: this repository lives on an
# NTFS mount under WSL, where the executable bit often does not stick and CRLF
# line endings can produce a "bad interpreter" error. `bash <file>` sidesteps both.
#
# Exits non-zero if anything fails, so it is safe to chain:
#     bash syntax-check.sh && ansible-playbook ... --tags oem_repo_patch_preflight
#
# WHY THIS EXISTS AS A SCRIPT rather than a couple of commands in a README:
# the commands were previously documented as two lines in one code block, got
# pasted as a single line, and ansible-playbook read the second command's name as
# a second playbook argument. A checking tool with a copy-paste hazard is not a
# checking tool. See docs/known-risks.md #143.

set -uo pipefail

FAILED=0
note()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
bad()   { printf '   FAIL  %s\n' "$*"; FAILED=1; }
ok()    { printf '   ok    %s\n' "$*"; }

cd "$(dirname "$0")" || exit 2

# ---------------------------------------------------------------------------
# 1. Parse every YAML file, not just the ones a playbook reaches.
#
# This is the check that matters most, and the one `--syntax-check` cannot do.
# --syntax-check only parses files some play actually includes, so a role task
# file that nothing currently references keeps its YAML error until the day
# something references it.
# ---------------------------------------------------------------------------
note "Parsing every *.yml"

if python3 -c 'import yaml' 2>/dev/null; then
  python3 - <<'PY'
import pathlib, sys, yaml

bad = []
count = 0
for f in sorted(pathlib.Path('.').rglob('*.yml')):
    count += 1
    try:
        yaml.safe_load(f.read_text(encoding='utf-8'))
    except Exception as e:
        first = str(e).splitlines()[0]
        bad.append(f"{f}: {first}")

for b in bad:
    print(f"   FAIL  {b}")
print(f"   parsed {count} file(s), {len(bad)} failed")
sys.exit(1 if bad else 0)
PY
  [ $? -ne 0 ] && FAILED=1
else
  echo "   SKIP  python3 has no yaml module — cannot parse unreferenced files."
  echo "         Ansible itself needs PyYAML, so this usually means ansible is"
  echo "         installed in a venv or via pipx. Activate it and re-run."
fi

# ---------------------------------------------------------------------------
# 2. Ansible's own syntax check, per playbook.
# ---------------------------------------------------------------------------
note "ansible-playbook --syntax-check"

# SKIP, do not FAIL, when ansible is not on PATH at all. Running this script from
# Git Bash / MINGW64 on the Windows side rather than from WSL2 produced six
# identical "ansible-playbook: command not found" FAILs and a red
# "FAILURES ABOVE" banner, none of which said anything about the playbooks. A
# check that reports a red failure for its own missing dependency trains the
# reader to ignore the banner — the same lesson as docs/known-risks.md #155.
# The playbooks live on /mnt/d from WSL2; run this there.
if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "   SKIP  ansible-playbook is not on PATH — cannot syntax-check playbooks."
  echo "         This script is meant to run from WSL2, where ansible is installed"
  echo "         (cd /mnt/d/github/Oracle-DBA-POC/phase-01-foundation-2node-rac-12cR2/ansible)."
  echo "         Every other check below is pure text and runs fine anywhere."
else
  for pb in site.yml oem-repo-patch.yml upgrade-19c-rolling.yml \
            dbms-rolling-execute.yml rolling-postupgrade.yml clone-node.yml; do
    [ -f "$pb" ] || { echo "   skip  $pb (not present)"; continue; }
    if ansible-playbook -i inventory/hosts.ini "$pb" --syntax-check >/dev/null 2>&1; then
      ok "$pb"
    else
      bad "$pb"
      ansible-playbook -i inventory/hosts.ini "$pb" --syntax-check 2>&1 | sed 's/^/         /'
    fi
  done
fi

# ---------------------------------------------------------------------------
# 3. Jinja block tags at column 0 inside a block scalar.
#
# A YAML block scalar's indent is fixed by its first non-empty line, and any
# line at a shallower indent ENDS the block. A `{%` written flush-left is
# therefore outside the string entirely, and YAML reads `{` as a flow mapping:
# "found character that cannot start any token". See docs/known-risks.md #143.
# ---------------------------------------------------------------------------
note "Jinja tags at column 0"

if grep -rn '^{%\|^{{' --include='*.yml' . ; then
  bad "Jinja tag at column 0 — indent it to match the surrounding shell body"
else
  ok "none found"
fi

# ---------------------------------------------------------------------------
# 4. Heredoc openers vs terminators.
#
# Same indentation rule, second application: <<'SQL' needs its terminator at
# column 0 OF THE RESULTING STRING, which means at the block's base indent in the
# file. An imbalance here means a heredoc that never closes.
#
# A count mismatch is a strong signal, not a proof — a terminator indented to the
# wrong depth still counts here. Read any file this flags.
# ---------------------------------------------------------------------------
note "Heredoc balance"

OPEN=$(grep -rEoh "<<-?'?[A-Z]+'?" --include='*.yml' . | wc -l)
CLOSE=$(grep -rEh "^[[:space:]]*(SQL|RMAN|EOF|DGMGRL|PY|EOSQL)[[:space:]]*$" \
        --include='*.yml' . | wc -l)

if [ "$OPEN" -eq "$CLOSE" ]; then
  ok "$OPEN openers, $CLOSE terminators"
else
  bad "$OPEN openers but $CLOSE terminators — a heredoc is unclosed"
fi

# ---------------------------------------------------------------------------
# 5. Literal tabs. Illegal in YAML indentation, and invisible in most editors.
# ---------------------------------------------------------------------------
note "Literal tabs"

if grep -rnP '\t' --include='*.yml' . ; then
  bad "literal tab in a YAML file"
else
  ok "none found"
fi

# ---------------------------------------------------------------------------
# 6. A quote preceded by a backslash at end of line.
#
# Ansible's module-argument splitter treats a quote preceded by `\` as escaped,
# so the quote does not close its string and the whole playbook fails with
# "failed at splitting arguments, either an unbalanced jinja2 block or quotes".
#
# This is valid YAML, so check 1 passes it. It is caught only by check 2, and
# only for playbooks that actually reach the file — which is exactly the gap
# check 1 exists to close, in the other direction. Hence a dedicated grep.
#
# Usually appears as a shell line-continuation inside an echo:
#     echo "some text \\"
# Rewrite to avoid needing the escape rather than trying to escape it correctly.
# See docs/known-risks.md #144.
# ---------------------------------------------------------------------------
note "Backslash before end-of-line quote"

if grep -rn '\\"$\|\\'"'"'$' --include='*.yml' . ; then
  bad "backslash-escaped quote at end of line — Ansible's splitter will not close it"
else
  ok "none found"
fi

# ---------------------------------------------------------------------------
# 7. `connection: local` at play level. WARNING, not a failure.
#
# Set explicitly on a play, it pins EVERY task to a local connection INCLUDING
# delegated ones — delegate_to does not override it. Tasks then run on the WSL2
# control node while the output still reads `[localhost -> somehost]`, failing at
# the connection/become layer with `sudo: a password is required`, ACL chmod
# errors, or a generic MODULE FAILURE.
#
# `hosts: localhost` on its own is enough for a control-node-only play, and leaves
# delegate_to able to resolve each task's real connection from inventory.
#
# Legitimate only when the play genuinely does all its work on the controller and
# delegates nothing — clone-node.yml (VBoxManage) is the one such play here.
#
# Documented at docs/known-risks.md #48 (third update) and #145 — and re-introduced
# once despite that, which is why it is now a check rather than only a comment.
# ---------------------------------------------------------------------------
note "connection: local at play level (warning)"

CONN_LOCAL=$(grep -rln '^\s*connection: local' --include='*.yml' . || true)
if [ -n "$CONN_LOCAL" ]; then
  echo "$CONN_LOCAL" | while read -r f; do
    if grep -q 'delegate_to' "$f"; then
      printf '   WARN  %s — has connection: local AND delegate_to\n' "$f"
      printf '         Delegated tasks will run on the CONTROL NODE. See known-risks.md #48/#145.\n'
    else
      printf '   ok    %s — connection: local, no delegate_to in file\n' "$f"
    fi
  done
else
  ok "none found"
fi

echo "         Note: this check is per-FILE, not per-play. A file with several"
echo "         plays may pair them innocently. Read any WARN before dismissing it."

# ---------------------------------------------------------------------------
# 8. include_tasks with a loop but no loop_var.
#
# An included file whose tasks have loops of their own will REBIND `item` for the
# duration of those tasks. Any var passed to the include as a lazy expression
# referencing `item` (e.g. ssh_pair_source: "{{ item.1.0 }}") is then re-evaluated
# against the INNER element.
#
# That is not a crash — Jinja resolves `<some string>.1.0` to a character and hands
# it back. In ssh_equivalence it produced the hostname "1", which Ansible resolved
# to 0.0.0.1. Ansible warns ("The loop variable 'item' is already in use") and then
# proceeds anyway.
#
# Fix: always set `loop_control: loop_var: <something>` on an include that loops.
# See docs/known-risks.md #147.
# ---------------------------------------------------------------------------
note "Apostrophes inside free-form module block scalars"

# A prose apostrophe inside a `shell: |` block ("the pipeline's output", "tee'd")
# is NOT a comment as far as Ansible is concerned. That block is module free-form
# text, run through split_args, which counts quote characters — one unmatched `'`
# opens a string that never closes and the playbook fails to parse.
#
# SCOPE, and this matters — the first version of this check used indentation as a
# proxy for "inside a block scalar" and produced 139 false positives against zero
# real ones, because:
#   * comments inside a `block:` are also indented 4+ spaces, and are ordinary
#     YAML comments, stripped before templating;
#   * `msg: |` under debug/fail is a MAPPING VALUE, not free-form — never passed
#     through split_args, so apostrophes there are safe.
#
# So this tracks real block-scalar state, and only for the modules whose argument
# really is free-form: shell, command, raw, script. Everything else is left alone.
#
# Balanced pairs (awk '{print $1}') are fine; only an ODD count on a line is a
# problem. Fix by moving prose to a task-level YAML comment, not by escaping.
# See docs/known-risks.md #153.

python3 - <<'PY'
import pathlib, re, sys

FREEFORM = ('shell', 'command', 'raw', 'script')
# e.g. "  shell: |", "    ansible.builtin.shell: >-", "  command: |2"
START = re.compile(r'^(\s*)(?:ansible\.builtin\.)?([\w-]+):\s*[|>][-+]?\d*\s*$')

hits = []
for f in sorted(pathlib.Path('.').rglob('*.yml')):
    in_block = False
    key_indent = 0
    for n, line in enumerate(f.read_text(encoding='utf-8', errors='replace').splitlines(), 1):
        if in_block:
            if not line.strip():
                continue
            indent = len(line) - len(line.expandtabs().lstrip())
            if indent > key_indent:
                if line.lstrip().startswith('#') and line.count("'") % 2:
                    hits.append(f"{f}:{n}: {line.strip()[:88]}")
                continue
            in_block = False           # dedented out of the block; fall through
        m = START.match(line)
        if m and m.group(2) in FREEFORM:
            in_block, key_indent = True, len(m.group(1))

for h in hits:
    print(f"   FAIL  {h}")
    print( "         odd apostrophe count in a free-form block — move prose to a task-level comment")
print(f"   checked, {len(hits)} issue(s)")
sys.exit(1 if hits else 0)
PY
# Capture the heredoc's status BEFORE anything else runs. Writing the opener as
# `python3 - <<'PY' || FAILED=1` and then testing `$?` on this line is wrong: `$?`
# is then the status of the whole `||` compound, which succeeds whenever the
# fallback assignment succeeds — so it is ALWAYS 0, and the check printed
# "ok none found" directly underneath its own FAIL lines. The gate still worked,
# because FAILED was set, but a check that reports both verdicts at once is worse
# than one that reports neither.
rc=$?
if [ "$rc" -eq 0 ]; then ok "none found"; else FAILED=1; fi

note "include_tasks loops without loop_var"

python3 - <<'PY'
import pathlib, re, sys

hits = []
for f in sorted(pathlib.Path('.').rglob('*.yml')):
    lines = f.read_text(encoding='utf-8', errors='replace').splitlines()
    for i, line in enumerate(lines):
        if not re.match(r'\s*(include_tasks|include_role|import_tasks):', line):
            continue
        # Look ahead within this task block for `loop:` and `loop_var:`.
        block, j = [], i + 1
        while j < len(lines):
            nxt = lines[j]
            if re.match(r'\s*-\s', nxt) and nxt.strip() != '-':
                break
            block.append(nxt)
            j += 1
        text = '\n'.join(block)
        loops = re.search(r'^\s*(loop|with_items|with_list):', text, re.M)
        has_var = re.search(r'^\s*loop_var:', text, re.M)
        if loops and not has_var:
            hits.append(f"{f}:{i+1}: {line.strip()}")

for h in hits:
    print(f"   FAIL  {h}")
    print( "         include with a loop and no loop_var — inner loops will rebind `item`")
print(f"   checked, {len(hits)} issue(s)")
sys.exit(1 if hits else 0)
PY
# Capture the heredoc's status BEFORE anything else runs. Writing the opener as
# `python3 - <<'PY' || FAILED=1` and then testing `$?` on this line is wrong: `$?`
# is then the status of the whole `||` compound, which succeeds whenever the
# fallback assignment succeeds — so it is ALWAYS 0, and the check printed
# "ok none found" directly underneath its own FAIL lines. The gate still worked,
# because FAILED was set, but a check that reports both verdicts at once is worse
# than one that reports neither.
rc=$?
if [ "$rc" -eq 0 ]; then ok "none found"; else FAILED=1; fi

# ---------------------------------------------------------------------------

echo
if [ "$FAILED" -eq 0 ]; then
  printf '\033[1mAll checks passed.\033[0m\n'
else
  printf '\033[1mFAILURES ABOVE — do not run the playbook yet.\033[0m\n'
fi
exit "$FAILED"
