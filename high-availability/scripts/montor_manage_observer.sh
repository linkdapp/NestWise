#!/bin/bash
#===============================================================================
# manage_observer.sh (Wallet-Authenticated with Status Check & Email Alert)
# - Manages the Data Guard Fast-Start Failover (FSFO) Observer
# - Arguments: start | stop | status
# - Automatically alerts via email if the observer goes down during a status check
#===============================================================================

export ORACLE_BASE=/u01/app/oracle
export ORACLE_HOME=$ORACLE_BASE/product/19.3.0/db_1  # Update to match your actual ORACLE_HOME path
export PATH=$ORACLE_HOME/bin:$PATH
export LD_LIBRARY_PATH=$ORACLE_HOME/lib

# ------------------------- Configuration -------------------------
DGMGRL_CONN="/@apexdb_dgmgrl"              # Primary DGMGRL connection via wallet
OBSERVER_CONNECT_ID="apexdb_dgmgrl"         # Connect identifier for background observer
OBSERVER_NAME="oemserver01_observer"
DATA_FILE="/opt/oracle/fsfo/oemserver01_observer.dat"
OBS_LOG_FILE="/opt/oracle/fsfo/oemserver01_observer.log"

# Alert Configuration
MAIL_TO="dba@yourcompany.com"               # Update with your email address
HOSTNAME=$(hostname)

LOG_DIR="/u01/app/oracle/scripts/logs/observer"
ACTION_LOG="${LOG_DIR}/observer_action_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$DATA_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@" | tee -a "$ACTION_LOG"
}

# Check input argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 {start|stop|status}"
    exit 1
fi

ACTION=$(echo "$1" | tr '[:upper:]' '[:lower:]')

# ------------------------- START OBSERVER -------------------------
start_observer() {
    log "=== Starting FSFO Observer ($OBSERVER_NAME) ==="

    RUNNING_PID=$(pgrep -f "dgmgrl.*$OBSERVER_NAME" 2>/dev/null)
    if [ -n "$RUNNING_PID" ]; then
        log "WARNING: Observer process is already running (PID: $RUNNING_PID)."
        exit 0
    fi

    log "Launching DGMGRL observer in background..."
    dgmgrl "$DGMGRL_CONN" <<EOF >> "$OBS_LOG_FILE" 2>&1
START OBSERVER $OBSERVER_NAME IN BACKGROUND FILE IS '$DATA_FILE' LOGFILE IS '$OBS_LOG_FILE' CONNECT IDENTIFIER IS $OBSERVER_CONNECT_ID;
EXIT;
EOF

    log "Waiting 5 seconds for observer initialization..."
    sleep 5

    if pgrep -f "dgmgrl.*$OBSERVER_NAME" > /dev/null; then
        log "SUCCESS: FSFO Observer process started. Querying DGMGRL for registration status..."
        
        dgmgrl "$DGMGRL_CONN" <<EOF | tee -a "$ACTION_LOG"
SHOW OBSERVER;
EXIT;
EOF
    else
        log "CRITICAL: Failed to start observer. Check log file: $OBS_LOG_FILE"
        exit 1
    fi
}

# ------------------------- STOP OBSERVER -------------------------
stop_observer() {
    log "=== Stopping FSFO Observer & Disabling Fast-Start Failover ==="

    log "Step 1: Disabling Fast-Start Failover via DGMGRL..."
    dgmgrl "$DGMGRL_CONN" <<EOF >> "$ACTION_LOG" 2>&1
DISABLE FAST-START FAILOVER;
EXIT;
EOF

    log "Step 2: Stopping the Observer process..."
    dgmgrl "$DGMGRL_CONN" <<EOF >> "$ACTION_LOG" 2>&1
STOP OBSERVER;
EXIT;
EOF

    RUNNING_PID=$(pgrep -f "dgmgrl.*$OBSERVER_NAME" 2>/dev/null)
    if [ -n "$RUNNING_PID" ]; then
        log "Terminating lingering observer process (PID: $RUNNING_PID)..."
        kill -9 "$RUNNING_PID" 2>/dev/null
    fi

    log "SUCCESS: FSFO Observer stopped."
}

# ------------------------- CHECK STATUS & ALERT -------------------
check_status() {
    log "=== Checking FSFO Observer Status ==="
    
    IS_DOWN=0

    # 1. Check OS process level
    RUNNING_PID=$(pgrep -f "dgmgrl.*$OBSERVER_NAME" 2>/dev/null)
    if [ -n "$RUNNING_PID" ]; then
        log "OS Process Check: Observer is RUNNING (PID: $RUNNING_PID)"
    else
        log "OS Process Check: Observer is NOT running."
        IS_DOWN=1
    fi

    # 2. Check DGMGRL Broker Status
    log "DGMGRL Broker Status Check:"
    DGMGRL_OUTPUT=$(dgmgrl "$DGMGRL_CONN" <<EOF 2>&1
SHOW OBSERVER;
EXIT;
EOF
)
    echo "$DGMGRL_OUTPUT" | tee -a "$ACTION_LOG"

    # If DGMGRL output indicates an error or doesn't find the observer
    if echo "$DGMGRL_OUTPUT" | grep -qi "No observer is currently running\|Error"; then
        IS_DOWN=1
    fi

    # Trigger Email Alert if Down
    if [ "$IS_DOWN" -eq 1 ]; then
        log "CRITICAL: FSFO Observer is down or unresponsive!"
        
        if [ -n "$MAIL_TO" ]; then
            {
                echo "CRITICAL ALERT: Data Guard FSFO Observer is DOWN on $HOSTNAME"
                echo "=================================================================="
                echo "Timestamp: $(date)"
                echo "Observer Name: $OBSERVER_NAME"
                echo ""
                echo "Detailed action log / error output:"
                cat "$ACTION_LOG"
            } | mailx -s "CRITICAL: FSFO Observer Down on $HOSTNAME" "$MAIL_TO"
            log "Alert email sent to $MAIL_TO"
        fi
    else
        log "HEALTHY: FSFO Observer is active and registered."
    fi
}

# ------------------------- Execution Router -------------------------
case "$ACTION" in
    start)
        start_observer
        ;;
    stop)
        stop_observer
        ;;
    status)
        check_status
        ;;
    *)
        echo "Invalid argument: $1"
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac

log "Action '$ACTION' completed. Action log saved to: $ACTION_LOG"
exit 0
