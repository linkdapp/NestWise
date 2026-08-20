#!/bin/bash
#===============================================================================
# cluster_log_monitor.sh
# - Comprehensive Oracle 12cR2 / 19.3 RAC & GI Log & Incident Manager
# - Runs ADRCI purging based on retention configuration (21600 mins / 15 days)
# - Cleans OS trace, cdump, and incident directories older than 2 days (-mtime +2)
# - Rotates alert logs weekly with date timestamps and compresses them
# - Scans for critical error patterns across DB, CRS, ASM, and Listeners
# To Schedule example every 15 minutes
# - */15 * * * * /u01/app/oracle/scripts/cluster_log_monitor.sh >/dev/null 2>&1
#===============================================================================

# ------------------------- Configuration -------------------------
ORACLE_BASE="/u01/app/oracle"
GRID_BASE="/u01/app/oracle"  # Update if your Grid Infrastructure base path differs

HOSTNAME=$(hostname)
LOG_DIR="${ORACLE_BASE}/scripts/logs/monitoring"
ALERT_TMP="${LOG_DIR}/cluster_alert_$$.tmp"
REPORT_FILE="${LOG_DIR}/cluster_monitor_$(date +%Y%m%d_%H%M%S).log"

# Retention configuration (21600 minutes = 15 days)
RETENTION_MIN=21600

# Error pattern engine (Generic setup for current and future tracking)
ERROR_PATTERN="ORA-[0-9]{5}|FATAL|CORRUPTION"

# Mail settings (Uncomment and set recipient when ready)
# MAIL_TO="dba@yourcompany.com"

mkdir -p "$LOG_DIR"
> "$ALERT_TMP"

log() {
    echo "$@" >> "$REPORT_FILE"
}

alert() {
    echo "$@" >> "$ALERT_TMP"
    echo "$@" >> "$REPORT_FILE"
}

log "================================================================================"
log " Oracle RAC & GI Log Monitoring & Purging - $HOSTNAME"
log " Executed: $(date)"
log "================================================================================"
log ""

# -----------------------------------------------------------------
# 1. ADRCI AUTOMATED LOG & INCIDENT PURGING
# -----------------------------------------------------------------
log ">>> 1. Running ADRCI Purge (Retention: $RETENTION_MIN minutes)..."

if command -v adrci &> /dev/null; then
    # Purge Database ADR Homes
    for db_home in $(adrci exec="show homes" | grep -E "rdbms"); do
        adrci exec="set home $db_home; purge -age $RETENTION_MIN;" >> "$REPORT_FILE" 2>&1
    done

    # Purge Grid Infrastructure ADR Homes (CRS, ASM)
    if [ -d "${GRID_BASE}" ]; then
        export ORACLE_BASE="${GRID_BASE}"
        for gi_home in $(adrci exec="show homes" | grep -E "crs|asm"); do
            adrci exec="set home $gi_home; purge -age $RETENTION_MIN;" >> "$REPORT_FILE" 2>&1
        done
        export ORACLE_BASE="/u01/app/oracle" # Reset back to default DB base
    fi
    log "ADRCI purge execution completed."
else
    log "WARNING: adrci command not found in current PATH."
fi
log ""

# -----------------------------------------------------------------
# 2. OS-LEVEL TRACE, CDUMP, AND INCIDENT FILE CLEANUP (-mtime +2)
# -----------------------------------------------------------------
log ">>> 2. Cleaning up OS traces, cdumps, and incidents older than 2 days (-mtime +2)..."

# Database OS cleanups
find ${ORACLE_BASE}/diag/rdbms/*/*/trace/ -type f \( -name "*.trc" -o -name "*.trm" \) -mtime +2 -delete 2>/dev/null
find ${ORACLE_BASE}/diag/rdbms/*/*/cdump/ -type f -mtime +2 -delete 2>/dev/null
find ${ORACLE_BASE}/diag/rdbms/*/*/incident/ -type f -mtime +2 -delete 2>/dev/null

# Grid Infrastructure OS cleanups
if [ -d "${GRID_BASE}" ]; then
    find ${GRID_BASE}/diag/crs/*/*/trace/ -type f \( -name "*.trc" -o -name "*.trm" \) -mtime +2 -delete 2>/dev/null
    find ${GRID_BASE}/diag/asm/*/*/trace/ -type f \( -name "*.trc" -o -name "*.trm" \) -mtime +2 -delete 2>/dev/null
    find ${GRID_BASE}/diag/crs/*/*/incident/ -type f -mtime +2 -delete 2>/dev/null
fi

log "OS-level directory cleanup completed."
log ""

# -----------------------------------------------------------------
# 3. WEEKLY ALERT LOG ROTATION
# -----------------------------------------------------------------
log ">>> 3. Checking Alert Log Rotation (Weekly)..."

rotate_alert_log() {
    local alert_file="$1"
    if [ -f "$alert_file" ]; then
        if [ -n "$(find "$alert_file" -mtime +7 2>/dev/null)" ]; then
            local timestamp=$(date +%Y%m%d_%H%M%S)
            local rotated_name="${alert_file}_${timestamp}.old"
            
            log "Rotating alert log: $alert_file -> $rotated_name"
            mv "$alert_file" "$rotated_name"
            touch "$alert_file"
            gzip "$rotated_name" &
        fi
    fi
}

# Rotate DB Alert Logs
for db_alert in ${ORACLE_BASE}/diag/rdbms/*/*/trace/alert_*.log; do
    rotate_alert_log "$db_alert"
done

# Rotate Grid Infrastructure Alert Logs
for gi_alert in ${ORACLE_BASE}/diag/crs/*/*/trace/alert.log ${GRID_BASE}/diag/crs/*/*/trace/alert.log; do
    [ -f "$gi_alert" ] && rotate_alert_log "$gi_alert"
done

log ""

# -----------------------------------------------------------------
# 4. SCAN ALERT LOGS FOR RECENT ERRORS (15-Minute Window)
# -----------------------------------------------------------------
log ">>> 4. Scanning Component Alert Logs for Errors..."

scan_recent_errors() {
    local log_path="$1"
    local component_name="$2"

    if [ -f "$log_path" ]; then
        RECENT_ERRORS=$(grep -iE "$ERROR_PATTERN" "$log_path" | tail -n 20)
        
        if [ -n "$RECENT_ERRORS" ]; then
            alert "CRITICAL: Errors identified in $component_name ($log_path):"
            alert "$RECENT_ERRORS"
            log ""
        fi
    fi
}

# Scan DB Alert Logs
for db_alert in ${ORACLE_BASE}/diag/rdbms/*/*/trace/alert_*.log; do
    scan_recent_errors "$db_alert" "Database Alert Log"
done

# Scan GI/CRS Alert Logs
for gi_alert in ${ORACLE_BASE}/diag/crs/*/*/trace/alert.log ${GRID_BASE}/diag/crs/*/*/trace/alert.log; do
    scan_recent_errors "$gi_alert" "Grid Infrastructure CRS Log"
done

# Scan Standard & GI Listeners
for lsnr_log in ${ORACLE_BASE}/diag/tnslsnr/*/*/trace/listener.log ${GRID_BASE}/diag/tnslsnr/*/*/trace/*.log; do
    scan_recent_errors "$lsnr_log" "Listener Log"
done

# -----------------------------------------------------------------
# 5. REPORTING & NOTIFICATIONS
# -----------------------------------------------------------------
log "================================================================================"
log " Monitoring cycle completed at $(date)"
log "================================================================================"

if [ -s "$ALERT_TMP" ]; then
    if [ -n "$MAIL_TO" ]; then
        {
            echo "CRITICAL RAC CLUSTER ISSUES DETECTED ON $HOSTNAME"
            echo "================================================================================"
            cat "$ALERT_TMP"
            echo "================================================================================"
            echo "See full report at: $REPORT_FILE"
        } | mailx -s "ALERT: Oracle RAC Cluster Errors on $HOSTNAME" "$MAIL_TO"
    fi
    echo "Alerts detected and logged."
else
    echo "SUCCESS - No critical errors found - $(date)" >> "${LOG_DIR}/cluster_success.log"
fi

rm -f "$ALERT_TMP"
exit 0
