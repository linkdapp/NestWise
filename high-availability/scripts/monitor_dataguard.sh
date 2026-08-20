#!/bin/bash
#===============================================================================
# monitor_dataguard.sh
# Advanced Data Guard Monitoring - Primary + Standby Comparison (RAC-Aware & Role-Aware)
# - Dynamically detects if the local node is PRIMARY or PHYSICAL STANDBY
# - Skips standby-specific alerts (like missing MRP) when acting as Primary
#===============================================================================

# ------------------------- Configuration -------------------------
# Standby/Local settings
export ORACLE_SID=apexdb2                     # Change this
export ORACLE_HOME=/u01/app/oracle/product/12.2.0/db_1
export PATH=$ORACLE_HOME/bin:$PATH
export ORACLE_BASE=/u01/app/oracle

# Primary connection (use TNS or Easy Connect)
PRIMARY_CONN="sys/sys@apexdb"   # Change this (or use / as sysdba if local)

# Alert settings
#MAIL_TO="dba@yourcompany.com"   # Change this
HOSTNAME=$(hostname)
LOG_DIR=/u01/app/oracle/scripts/logs/monitoring
REPORT_FILE=${LOG_DIR}/dg_monitor_$(date +%Y%m%d_%H%M%S).log
ALERT_FILE=${LOG_DIR}/dg_ALERT_$$.tmp
LAG_THRESHOLD_MINUTES=5                        # Alert if lag > 5 minutes

mkdir -p $LOG_DIR
> $ALERT_FILE                           # Clear previous alerts

# ------------------------- Helper Functions ----------------------
run_sql_local() {
  sqlplus -s / as sysdba <<EOF
SET ECHO OFF FEEDBACK OFF  TRIMSPOOL ON
SET LINESIZE 160 PAGESIZE 1000
COLUMN inst_id FORMAT 99 HEADING "Inst"
COLUMN HOST_NAME FORMAT A20 HEADING "Hostname"
COLUMN database_role FORMAT A18 HEADING "Database Role"
COLUMN open_mode FORMAT A20 HEADING "Open Mode"
COLUMN protection_mode FORMAT A22 HEADING "Protection Mode"
COLUMN name FORMAT A20 HEADING "DB Name"
COLUMN value FORMAT A20 HEADING "Value"
COLUMN time_computed FORMAT A22 HEADING "Time Computed"
COLUMN process FORMAT A10 HEADING "Process"
COLUMN status FORMAT A18 HEADING "Status"
COLUMN thread# FORMAT 999 HEADING "Thd"
COLUMN sequence# FORMAT 99999999 HEADING "Sequence#"
COLUMN block# FORMAT 99999999 HEADING "Block#"
COLUMN error FORMAT A30 HEADING "Error"
COLUMN severity FORMAT A10 HEADING "Severity"
COLUMN message FORMAT A80 HEADING "Message"
COLUMN group# FORMAT 999 HEADING "Grp"
COLUMN size_mb FORMAT 999,999 HEADING "Size (MB)"
COLUMN item FORMAT A25 HEADING "Item"
COLUMN sofar FORMAT 999,999,999 HEADING "So Far"
COLUMN units FORMAT A20 HEADING "Units"

$1
EXIT;
EOF
}

run_sql_primary() {
  sqlplus -s $PRIMARY_CONN as sysdba <<EOF
SET ECHO OFF FEEDBACK OFF  TRIMSPOOL ON
SET LINESIZE 160 PAGESIZE 1000
COLUMN thread# FORMAT 999 HEADING "Thd"
COLUMN last_seq FORMAT 99999999 HEADING "Last Generated Seq"

$1
EXIT;
EOF
}

log() {
  echo "$@" >> $REPORT_FILE
}

alert() {
  echo "$@" >> $ALERT_FILE
  echo "$@" >> $REPORT_FILE
}

# ------------------------- Start Report --------------------------
log "=============================================================="
log " Data Guard Monitoring Report - $HOSTNAME (RAC & Role Aware)"
log " Generated: $(date)"
log "=============================================================="
log ""

# ------------------------- 1. Database Role & Open Mode -----------
log ">>> 1. Local Database Role & Open Mode (GV$)"
ROLE_OUTPUT=$(run_sql_local "
SELECT 
    i.instance_number, 
    i.instance_name, 
    i.host_name, 
    d.name, 
    d.database_role, 
    d.open_mode, 
    d.log_mode, 
    i.status,
    TO_CHAR(i.startup_time, 'YYYY-MM-DD HH24:MI:SS') AS startup_time
FROM   gv\$instance i
CROSS JOIN v\$database d
ORDER BY i.instance_number;
")
log "$ROLE_OUTPUT"
log ""

# Determine current database role
CURRENT_ROLE=$(echo "$ROLE_OUTPUT" | grep -oE "PRIMARY|PHYSICAL STANDBY" | head -n 1)
log "Detected Local Database Role: ${CURRENT_ROLE:-UNKNOWN}"
log ""

if [ "$CURRENT_ROLE" = "PHYSICAL STANDBY" ]; then

    # =========================================================
    # STANDBY SPECIFIC CHECKS
    # =========================================================

    # 2. Transport & Apply Lag
    log ">>> 2. Transport Lag & Apply Lag (GV$ Dataguard Stats)"
    LAG_OUTPUT=$(run_sql_local "
    SELECT inst_id, name, value, time_computed, datum_time
    FROM   gv\$dataguard_stats
    WHERE  name IN ('transport lag', 'apply lag', 'apply finish time')
    ORDER BY name, inst_id;
    ")
    log "$LAG_OUTPUT"
    log ""

    if echo "$LAG_OUTPUT" | grep -E " [0-9]+ minutes|hours|days" > /dev/null; then
      alert "CRITICAL: Significant Transport/Apply Lag detected!"
      alert "$LAG_OUTPUT"
    fi

    # 3. MRP Status
    log ">>> 3. Managed Recovery Process (MRP) Status across Cluster"
    MRP_OUTPUT=$(run_sql_local "
    SELECT inst_id, process, status, thread#, sequence#, block#
    FROM   gv\$managed_standby
    WHERE  process LIKE 'MRP%' OR process LIKE 'PR%'
    ORDER BY inst_id, process;
    ")
    log "$MRP_OUTPUT"
    log ""

    if ! echo "$MRP_OUTPUT" | grep -qE "MRP|APPLYING_LOG|WAIT_FOR_LOG"; then
      alert "CRITICAL: MRP process is NOT running on ANY node in the Standby RAC cluster!"
    fi

    # 4. Archive Gap
    log ">>> 4. Archive Gap Check (GV$)"
    GAP_OUTPUT=$(run_sql_local "SELECT * FROM gv\$archive_gap;")
    if [ -z "$GAP_OUTPUT" ] || echo "$GAP_OUTPUT" | grep -qi "no rows selected"; then
      log "No archive gaps found - OK"
    else
      log "$GAP_OUTPUT"
      alert "CRITICAL: Archive gap detected on Standby cluster!"
      alert "$GAP_OUTPUT"
    fi
    log ""

    # 5. Sequence Comparison
    log ">>> 5. Primary vs Standby Sequence Comparison"
    PRIMARY_SEQ=$(run_sql_primary "
    SELECT thread#, MAX(sequence#) AS last_seq
    FROM   v\$archived_log
    WHERE  resetlogs_change# = (SELECT resetlogs_change# FROM v\$database)
    GROUP BY thread#
    ORDER BY thread#;
    ")

    STANDBY_SEQ=$(run_sql_local "
    SELECT thread#,
           MAX(sequence#) AS last_received,
           MAX(CASE WHEN applied = 'YES' THEN sequence# END) AS last_applied
    FROM   gv\$archived_log
    WHERE  resetlogs_change# = (SELECT resetlogs_change# FROM v\$database)
    GROUP BY thread#
    ORDER BY thread#;
    ")

    log "--- Primary (Last Generated) ---"
    log "$PRIMARY_SEQ"
    log ""
    log "--- Standby Cluster (Last Received / Applied) ---"
    log "$STANDBY_SEQ"
    log ""

    # 7. Standby Redo Logs
    log ">>> 7. Standby Redo Log Status (GV$)"
    run_sql_local "
    SELECT inst_id, group#, thread#, sequence#, status,
           ROUND(bytes/1024/1024) AS size_mb
    FROM   gv\$standby_log
    ORDER BY inst_id, thread#, group#;
    " >> $REPORT_FILE
    log ""

    # 8. Apply Rate
    log ">>> 8. Apply Rate (GV$)"
    run_sql_local "
    SELECT inst_id, item, sofar, units
    FROM   gv\$recovery_progress
    WHERE  item IN ('Active Apply Rate','Average Apply Rate','Redo Applied');
    " >> $REPORT_FILE
    log ""

elif [ "$CURRENT_ROLE" = "PRIMARY" ]; then

    # =========================================================
    # PRIMARY SPECIFIC HANDLING (Skip Standby/MRP checks)
    # =========================================================
    log ">>> INFO: Local database is currently running as PRIMARY."
    log ">>> Skipping Standby-specific checks (MRP, Apply Lag, Archive Gaps)."
    log ""

else
    alert "CRITICAL: Unable to determine valid Data Guard database role (Role: ${CURRENT_ROLE:-Unknown})."
fi

# ------------------------- 6. Recent Critical Events -------------
log ">>> 6. Recent Critical Data Guard Events (GV$, last 24h)"
EVENTS=$(run_sql_local "
SELECT inst_id, TO_CHAR(timestamp,'YYYY-MM-DD HH24:MI:SS') ts,
       severity, SUBSTR(message,1,100) AS message
FROM   gv\$dataguard_status
WHERE  timestamp > SYSDATE - 1
  AND  severity IN ('Error','Fatal')
ORDER BY timestamp DESC;
")
log "$EVENTS"
log ""

if [ -n "$EVENTS" ] && ! echo "$EVENTS" | grep -qi "no rows selected"; then
  alert "CRITICAL: Error/Fatal events found in Data Guard status!"
  alert "$EVENTS"
fi

# ------------------------- Final Decision: Email only on Critical
log "=============================================================="
log " Monitoring finished at $(date)"
log " Full report saved to: $REPORT_FILE"
log "=============================================================="

if [ -s $ALERT_FILE ]; then
   # Critical issues found → send email
   {
     echo "CRITICAL ISSUES DETECTED on Data Guard environment ($HOSTNAME)"
     echo "=============================================================="
     echo ""
     cat $ALERT_FILE
     echo ""
     echo "=============================================================="
     echo "Full detailed report:"
     echo ""
     cat $REPORT_FILE
   } | mailx -s "CRITICAL: Data Guard Issue on $HOSTNAME - $(date +%Y-%m-%d)" $MAIL_TO

   echo "ALERT EMAIL SENT - Critical issues found."
else
   echo "All checks passed. No email sent (healthy)."
   echo "SUCCESS - No critical issues - $(date)" >> ${LOG_DIR}/dg_success.log
fi

# Cleanup
rm -f $ALERT_FILE
find $LOG_DIR -name "dg_monitor_*.log" -mtime +3 -delete 2>/dev/null

exit 0
