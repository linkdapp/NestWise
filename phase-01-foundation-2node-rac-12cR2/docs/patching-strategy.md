# Patching strategy: patches before configuration

The requirement driving this phase is that **Grid Infrastructure and Database homes are
patched before any configuration step runs** — before `root.sh`/`rootupgrade.sh`, before
`gridSetup.sh`'s cluster configuration phase, and before DBCA touches the DB home. The
goal is that the first time either home is actually configured, it's already at the
target Release Update, not patched-after-the-fact against a running cluster.

**Note the version split:** GI is **19c** (19.3 base + RU 19.32.0.0.260721) here, not
12.2.0.1 — a deliberate, independent-version design (see `docs/known-risks.md` #2).
Only the Database home is actually 12.2.0.1. The two
patch numbers below (`gi_ru_patch_id`, `db_ru_patch_id`) come from different release
lines accordingly — a 19c GI RU and a 12.2 combo RU, not two 12.2 patches.

**Both are combo/bundle patches, not flat single-purpose zips** — this matters for how
`-applyRU` is invoked, covered in Mechanism 1 below:

- **GI RU — Patch 39467003** (19.32.0.0.260721). Unzips into a `39467003/` folder
  containing five separate component patch numbers as subdirectories — `39472050`
  (Database Release Update; Oracle home only for non-RAC, **both** Oracle home and Grid
  home for RAC, which this project is), `39526364` (OCW, both homes), `39503034` (ACFS,
  Grid home only), `39107855` (Tomcat, Grid home only), `39107825` (DBWLM, Grid home
  only). `-applyRU` takes the top-level `39467003` directory as a single argument and
  auto-discovers/applies all five — see `gi_ru_patch_path` in `group_vars/all.yml`.
- **DB RU — Patch 33559966**, "Combo of OJVM Component Release Update 12.2.0.1.220118 +
  GI (DB) Jan 2022 Release Update 12.2.0.1.220118". Unzips into a `33559966/` folder
  containing **two** components that are handled differently, not interchangeably:
  `33583921` (the actual RU/PSU — `db_ru_patch_path` points here, this is what
  `-applyRU` applies) and `33561275` (OJVM Release Update — **not** part of `-applyRU`,
  but applied at install time via the separate, combinable `-applyOneOffs` flag; see
  Mechanism 1 below and Mechanism 3 for why DBCA's own automatic `datapatch` call
  finishes the job from there, plus one documented caveat worth verifying for).

## Which patch number

**Do not hardcode a specific RU/patch number as permanently current.** The numbers
above (39467003 / 33559966) are what was actually on hand for this build as of
2026-08-08, not a claim that they stay the latest — 12.2.0.1 in particular is long past
Premier Support (see `docs/known-risks.md` #5), so "current" for the DB side means the
latest that was actually available for it, not a moving quarterly target the way the
19c GI RU is. Confirm both are still what you want before a real build:

1. My Oracle Support → **Patches & Updates** → search product `Oracle Grid
   Infrastructure`, release `19.0.0.0.0`, platform `Linux x86-64` for the GI RU; search
   `Oracle Database`, release `12.2.0.1.0`, platform `Linux x86-64` for the DB DBPSU.
2. Cross-check against MOS Note **742060.1** ("Release Schedule of Current Database
   Releases") for whether 12.2.0.1 is still receiving new DBPSUs or is in a
   limited-error-correction/security-only state — this changes whether "latest RU" or
   "latest one-off security patch" is the right target for the DB side. GI's 19c line
   is on its own, separate support/RU schedule.
3. Record the exact patch numbers and My Oracle Support patch IDs in
   `ansible/group_vars/all.yml` (`gi_ru_patch_id`, `db_ru_patch_id`) once known — the
   roles read it from there, nothing here assumes a number.

## Mechanism 1: `-applyRU` during silent install — GI only, NOT the DB layer

`-applyRU <patch_directory>` applies a Release Update as part of the same silent
invocation that lays down the software, before `root.sh` runs — this genuinely works
for the **19c Grid Infrastructure installer**:

```bash
# Grid Infrastructure — software + RU in one pass, before root scripts. Points at the
# TOP-level combo directory (39467003) — gridSetup.sh auto-discovers and applies all
# five component patches inside it (see "Which patch number" above). Confirmed working
# against a real run.
./gridSetup.sh -silent -applyRU /u01/stage/patches/39467003 \
  -responseFile /u01/stage/response-files/grid_install.rsp
```

**It does NOT work for the 12.2.0.1 Database installer — confirmed against a real run,
not a documentation-reading judgment call.** An earlier version of this doc (and of
`db_silent_install`) assumed `-applyRU`/`-applyOneOffs` worked the same way for the DB
layer, based on several DBA writeups describing exactly that flag combination. Those
writeups turned out to all be about 18c+ Database installers, which genuinely do accept
`-applyRU`; 12.2.0.1's installer does not. A real run against this project's actual
media produced this, immediately, before the installer even launched its GUI/wizard
phase:

```
[INS-04003] Invalid argument passed from command line. Specified argument
([-applyRU]) is not a supported argument for this application.
```

The DB layer uses Mechanism 2 below instead — not as a fallback for when Mechanism 1
"isn't viable," the way it's framed for GI, but as the only mechanism that actually
applies to 12.2.0.1's Database installer at all. See docs/known-risks.md #35 for the
full story.

Requirements for `-applyRU` to work cleanly, for GI (the only place it's used now):

- The patch must be **unzipped** (not left as a `.zip`) at the path passed to `-applyRU`.
  Watch the extraction destination for combo patches specifically: Oracle's zips already
  contain a top-level folder matching their own patch number, so unzipping into a
  destination that *also* includes that patch number double-nests it —
  `patch_before_config` extracts into the parent `patches/` directory for exactly this
  reason, not `patches/<patch_id>/`.
- OPatch inside `grid_home` must meet the patch's minimum OPatch version — check the
  patch's README to confirm. `grid_silent_install` updates OPatch automatically from MOS
  patch 6880880 (`gi_opatch_zip` in `group_vars/all.yml`) right after extracting the
  software and before invoking `-applyRU`, since the version bundled with the base
  install media is frequently below what a current RU requires.
- The RU must be compatible with an "apply during install" flow — some one-off/merge
  patches aren't packaged for this and would need Mechanism 2 instead, same as the DB
  layer always does.
- A `cluvfy stage -pre crsinst` sanity pass right after staging the GI software (before
  touching OPatch or `-applyRU`) is cheap insurance — `grid_silent_install` runs one
  automatically now, non-fatally, so its output is there to read before the real
  `-applyRU` step runs.

## Mechanism 2: software-only install, then patch the real home directly with OPatch

**For GI**, this is the fallback when `-applyRU` isn't viable for a given patch (wrong
packaging, OPatch version mismatch, a one-off/merge patch) — not the normal path, since
Mechanism 1 works for GI. **For the DB layer, this is simply how patching happens** —
confirmed the only option 12.2.0.1's installer supports, per Mechanism 1 above.

```bash
# --- GI, Mechanism 2 (fallback only — Mechanism 1 is the normal path) -----------
./gridSetup.sh -silent -responseFile grid_install.rsp
$ORACLE_HOME/OPatch/opatchauto apply /u01/stage/patches/<gi_ru_patch_id>
# ...then root scripts / cluster configuration

# --- DB, Mechanism 2 (the actual, only mechanism for 12.2.0.1) ------------------
# 1. Plain software-only install — no -applyRU, no -applyOneOffs.
/u01/stage/software/database/runInstaller -silent -waitforcompletion \
  -responseFile /u01/stage/response-files/db_install.rsp
# -waitforcompletion is required, not optional — without it runInstaller forks the
# real install into a detached background process and returns almost immediately;
# see docs/known-risks.md #36.

# 2. root.sh — written into the real db_home by a successful install, NOT part of
#    the staged database/ media (confirmed against every transcript checked
#    regardless of extraction-location convention — see docs/known-risks.md #34).
/u01/app/oracle/product/12.2.0/db_1/root.sh   # as root, both nodes

# NOTE: runInstaller's own bundled CVU may hard-fail a mandatory "CRS Integrity"
# check here with PRVF-7595/PRVG-2043 (legacy crs_stat missing from a 19c GRID_HOME)
# even against a genuinely healthy cluster — confirmed a false positive via
# `crsctl check cluster -all`/`crsctl stat res -t`. -ignorePrereq/-ignoreSysPrereqs
# is the only available bypass; see docs/known-risks.md #37.

# 3. Update OPatch in the now-populated db_home, on EVERY node (move the bundled
#    one aside, unzip the newer one from MOS patch 6880880 in its place) — matches
#    the documented approach in every real 12.2.0.1/19c+ transcript checked for this
#    exact step.
mv $ORACLE_HOME/OPatch $ORACLE_HOME/OPatch.bundled
unzip -q -d $ORACLE_HOME /u01/stage/patches/p6880880_122010_Linux-x86-64.zip

# 4. Apply the RU, then the OJVM one-off — via opatchauto, NOT plain `opatch
#    prereq`/`opatch apply` (both patches are System Patches; OPatch itself refuses
#    plain prereq/apply against them with "This command doesn't support System
#    Patch"). opatchauto patches ONE node per invocation — run every step below on
#    EACH node, RU before OJVM. Both steps run from DB_HOME/OPatch: opatchauto must
#    be invoked from the OPatch of the home actually named via -oh (this is a
#    DB-only RU with no GI component, so that's db_home, not grid_home):
export ORACLE_HOME=/u01/app/oracle/product/12.2.0/db_1
export PATH=$PATH:$ORACLE_HOME/OPatch
cd $ORACLE_HOME/OPatch

#    RU — via sudo (opatchauto requires root; run it with sudo directly rather than
#    su - root first):
sudo ./opatchauto apply /u01/stage/patches/33559966/33583921 -oh $ORACLE_HOME

#    OJVM one-off — WITH -nonrolling (OJVM is a documented nonrolling patch type):
sudo ./opatchauto apply /u01/stage/patches/33559966/33561275 -oh $ORACLE_HOME -nonrolling

# 5. Confirm, on both nodes (no manual datapatch needed yet — no database exists
#    until dbca_noncdb runs):
$ORACLE_HOME/OPatch/opatch lsinventory
```

## Mechanism 3: OJVM's SQL-level half — DBCA handles it, with one caveat worth verifying

Patch 33559966's OJVM component (`33561275`) needs two genuinely separate steps to fully
take effect:

1. **Binary/library patch** — handled by a separate `opatchauto apply ... -nonrolling`
   against `db_home` (Mechanism 2, above; NOT plain `opatch apply` — this one-off is a
   System Patch, confirmed by a real run, docs/known-risks.md #38) — and NOT
   `-applyOneOffs` during `runInstaller`, which an earlier version of this doc
   described; that flag doesn't exist for 12.2.0.1's installer any more than
   `-applyRU` does (same #35 finding).
2. **SQL-level dictionary registration** — `datapatch`, which has to run against the
   database open. (Note for this project specifically: `dbca_noncdb` builds a **non-CDB**
   database — `db_is_cdb: false` in `group_vars/all.yml` — so there's no PDB to open;
   `datapatch` just needs the database itself open, which it already is once DBCA
   finishes. An earlier version of this doc referenced "open pluggable database" here,
   left over from thinking in CDB/multitenant terms — doesn't apply to this build.)

The correction from an earlier version of this doc: step 2 does **not** need to be a
separate manual step. **Since Oracle Database 12.2.0.1, DBCA itself runs
`$ORACLE_HOME/OPatch/datapatch -verbose` automatically as the final action of creating a
new database** — confirmed, documented behavior (Oracle's own patch READMEs describe it
under "Loading Modified SQL Files into the Database"; independently confirmed by real
DBCA session output showing the `datapatch` invocation and its "Installation queue"
report). This applies specifically to databases created **through DBCA** — `dbca_noncdb`
here does exactly that — not to databases hand-built with raw `CREATE DATABASE` SQL,
which would still need a manual `datapatch -verbose` afterward. Since `db_silent_install`
already patched `db_home`'s binaries (both `-applyRU` and `-applyOneOffs`) before
`dbca_noncdb` ever runs, DBCA's automatic `datapatch` call at database-creation time is
enough — no separate manual OJVM step is needed after `dbca_noncdb` completes.

**One documented caveat specific to this project's template choice.** DBCA's automatic
`datapatch` call is real, but its *completeness* has a known history of gaps
specifically for **seed-based** DBCA templates — `General_Purpose.dbc`, which is what
`db_template` is set to here (copies a pre-built seed database's datafiles, rather than
running `CREATE DATABASE` from scratch the way DBCA's "Custom Database" option does).
Mike Dietrich (Oracle) documented a real case — the January 2020 RU on 19c — where
databases created from a patched home via a seed-based template (`General_Purpose`/OLTP
or Data Warehousing) came up with ~256 invalid `MDSYS` objects and a broken EM Express,
a problem that did **not** reproduce with "Custom Database" creation. Not necessarily the
same failure signature for patch 33559966 on 12.2.0.1 — cited here as a reason to
**verify, not skip verification** — see the check below.

**Verification, not a re-application** — run this after `dbca_noncdb` completes, instead
of the old manual OJVM step:

```bash
# Confirm datapatch actually registered the OJVM patch:
sqlplus / as sysdba
SQL> select patch_id, patch_type, status, action_time from dba_registry_sqlpatch order by action_time;
SQL> select count(*) from dba_objects where status = 'INVALID';
SQL> exit
```

If `33561275` (or its bundle ID) isn't listed, or the invalid-object count is
unexpectedly high (a handful of transient invalids after any DBCA run is normal —
hundreds, or specifically `MDSYS`-owned ones, is the Mike Dietrich signature above),
remediate rather than assume it self-heals:

```bash
cd $ORACLE_HOME/OPatch
./datapatch -verbose        # idempotent — safe to re-run, only applies what's missing

sqlplus / as sysdba
SQL> @$ORACLE_HOME/rdbms/admin/utlrp.sql
```

Left as a manual, post-`dbca_noncdb` verification step, not an Ansible task in this
repo — same reasoning as elsewhere: worth reading interactively the first time, on a
database that now actually exists, rather than trusting a task's `changed_when` on
something this consequential. `db_ojvm_patch_path` in `group_vars/all.yml` points at
`33559966/33561275` — `db_silent_install`'s manual-pause prompt reads it for the
`opatchauto apply ... -nonrolling` command (docs/known-risks.md #38); nothing needs it
after that.

## AHF baseline around every patch application

Per the project's standing tooling, run an **AHF compliance check** (`ahf runcheck` /
the `orachk` component AHF now includes) immediately before staging the patch and again
immediately after configuration completes. Two compliance reports, before and after, are
the evidence for the showcase post — "the patch applied cleanly" is a much weaker claim
than a diffed compliance report showing it.

## Ansible role mapping

`ansible/roles/patch_before_config/tasks/main.yml` stages both combo zips (reads
`gi_ru_patch_id`/`db_ru_patch_id` from `group_vars/all.yml`, extracts both into the
shared `patches/` staging directory) regardless of which mechanism each layer ends up
using — GI via Mechanism 1, DB via Mechanism 2 (see below), both need the same unzipped
patch directories on disk either way. `ansible/roles/grid_silent_install/tasks/main.yml`
uses Mechanism 1 (`-applyRU`, confirmed working), runs a non-fatal `cluvfy stage
-pre crsinst` sanity check right after staging, before `-applyRU`, and — as of
2026-08-09 — installs GI in two phases (software-only via `-applyRU` against
`grid_install_swonly.rsp`, then cluster configuration via `config.sh` against
`grid_install.rsp`) rather than one single `gridSetup.sh` call.

`ansible/roles/db_silent_install/tasks/main.yml` uses Mechanism 2 — **not by choice, by
necessity**: a real run confirmed `-applyRU`/`-applyOneOffs` aren't supported arguments
for 12.2.0.1's `runInstaller` at all (`[INS-04003]`). The role now runs a plain
software-only install (`runInstaller -silent -responseFile ...`, no patch flags) from
the staged `database/` subfolder the zip's own packaging always produces, runs `root.sh`
from `db_home` itself once install completes (two different locations for two different
reasons — see docs/known-risks.md #31/#33/#34 for the extraction-path history), updates
OPatch in the now-populated `db_home`, then **stops at an unconditional pause with the
exact `opatch prereq`/`opatch apply`/`opatch lsinventory` commands to run by hand**,
rather than automating the actual patch application. That last part is a deliberate
choice, not a gap: plain `opatch apply` against a RAC-registered home has
version-dependent, potentially-interactive behavior around other cluster nodes that
isn't confirmed safe for a non-interactive Ansible `command:` task — see
docs/known-risks.md #35 for exactly what's confirmed vs. not, and why this follows the
same "watch it interactively the first time" philosophy this project already uses for
cluster-forming `root.sh` (docs/known-risks.md #8, #24).

Mechanism 3's SQL-level half (`datapatch`) is **not** a missing automation gap — DBCA
runs it automatically as part of `dbca_noncdb`, per Oracle's own documented 12.2+
behavior. What *is* left as a manual, post-`dbca_noncdb` step is the verification query
(and conditional remediation) covering this project's seed-template caveat — documented
above, not automated, since it's a read-and-judge check rather than a deterministic
task.
