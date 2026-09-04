#!/usr/bin/env bash
#
# One-off: rename the Phase 7a screenshots to this project's naming convention.
#
# The originals came off the terminal as oms_patch_step3a_The_full_run_opatch.png
# and friends. That naming had three problems: it did not match the convention the
# rest of the repository uses (installation/README.md Section 15), TWO files were
# both called step3a, and it left gaps at 3b and 3j that looked like missing
# evidence rather than a numbering accident.
#
# The new names are numbered to match the SECTION numbers in the three Phase 7a
# parts, the same way high-availability/screenshots/16a-* matches Part 3 Section 16.
#
# Run once, from anywhere inside the repository:
#
#   bash monitoring/rename-screenshots.sh
#
# For files git already tracks it uses `git mv`, so history follows. For files git
# has never seen it falls back to plain `mv` — `git mv` refuses to touch an
# untracked path, and on the first run these screenshots are all untracked.
#
# Safe to re-run: files already at their new name are skipped. Delete this script
# once it has run and been committed — it has no ongoing purpose.

set -u

cd "$(git rev-parse --show-toplevel)" || exit 1
DIR=monitoring/screenshots

moved=0
skipped=0

mv_one() {
  local old="$DIR/$1"
  local new="$DIR/$2"

  if [ -f "$new" ]; then
    echo "  already renamed: $2"
    skipped=$((skipped + 1))
    return
  fi
  if [ ! -f "$old" ]; then
    echo "  MISSING SOURCE : $1"
    skipped=$((skipped + 1))
    return
  fi

  # `git mv` only works on paths already in the index. On the first run these
  # files are untracked, so fall back to a plain mv rather than failing.
  if git ls-files --error-unmatch "$old" >/dev/null 2>&1; then
    git mv "$old" "$new"
  else
    mv "$old" "$new"
  fi

  echo "  $1"
  echo "    -> $2"
  moved=$((moved + 1))
}

echo "=== Phase 7a run screenshots -> section-numbered names ==="

# Part 1 — before the window
mv_one oms_patch_step1a_Preflight.png \
       03a-preflight-registry-components.png
mv_one oms_patch_step1b_Preflight.png \
       03b-preflight-summary-19.19.png
mv_one oms_patch_step2_Stage_the_patch.png \
       04-stage-combo-components-present.png

# Part 2 — the patch window
mv_one oms_patch_step3a_The_full_run_opatch.png \
       06-opatch-update-12.2.0.1.52.png
mv_one oms_patch_step3a_The_full_run_pause_ck.png \
       07a-pause-blackout-checkpoint.png
mv_one oms_patch_step3c_The_full_run_blackout.png \
       07b-blackout-verified-expired-false.png
mv_one oms_patch_step3d_The_full_run_shutdown_oms_agent.png \
       08-oms-stopped.png
mv_one oms_patch_step3e_The_full_run_full_rman_backup.png \
       09a-rman-backup-pre-ru32.png
mv_one oms_patch_step3f_The_full_run_restore_point.png \
       09b-restore-point-pre-ru32.png
mv_one oms_patch_step3g_The_full_run_shutdown_db.png \
       10-database-listeners-down-residual-0.png
mv_one oms_patch_step3h_The_full_run__rollback_verify.png \
       11a-rollback-verify-sqlpatch.png
mv_one oms_patch_step3i_The_full_run_post_rollback_con.png \
       11b-post-rollback-conflict-recheck-passed.png
mv_one oms_patch_step3k_The_full_run_post_apply_list.png \
       12-post-apply-lspatches.png

# Part 3 — datapatch, verification, aftermath
mv_one oms_patch_step3l_The_full_run_datapatch_sanity_check.png \
       13a-datapatch-sanity-checks.png
mv_one oms_patch_step3m_The_full_run_recompile_utlrp.png \
       13b-catcon-utlrp-completed.png
mv_one oms_patch_step3o_The_full_run_Show_restart_output.png \
       15-oms-restarted-console-url.png
mv_one oms_patch_step3n_The_full_run_show_patch_verification.png \
       16a-verification-19.32-registry.png
mv_one oms_patch_step3p_The_full_run_REport_Summary.png \
       16b-report-summary-play-recap.png

echo
echo "=== Blackout console walkthrough -> oem-create-blackout.md ==="

mv_one oem_create_blackout1.png blackout-01-enterprise-monitoring-blackouts.png
mv_one oem_create_blackout2.png blackout-02-blackouts-page-create.png
mv_one oem_create_blackout3.png blackout-03-create-dialog-blackout-type.png
mv_one oem_create_blackout4.png blackout-04-name-reason-full-blackout.png
mv_one oem_create_blackout5.png blackout-05-select-targets-hosts.png
mv_one oem_create_blackout6.png blackout-06-targets-added-schedule.png
mv_one oem_create_blackout7.png blackout-07-review-before-submit.png
mv_one oem_create_blackout8.png blackout-08-confirmation-scheduled.png
mv_one oem_create_blackout9.png blackout-09-target-blackout-status.png

echo
echo "renamed: $moved   skipped: $skipped"
echo
echo "Now verify no doc still points at an old name:"
echo "  grep -rn 'oms_patch_step\|oem_create_blackout' --include='*.md' ."
echo "(should return nothing)"
