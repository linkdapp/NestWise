#!/bin/bash
# =============================================================================
# NestWise — quick RAC session-distribution proof (docs/install.md §9)
# =============================================================================
# Purpose: put enough *sustained, concurrent* Oracle load on the cluster that
# `gv$session` reliably shows NestWise sessions on BOTH RAC instances at the
# same moment. Hand-clicking pages in a browser doesn't work for this: each
# page's DB work finishes in milliseconds, so by the time you switch windows
# and run the query, every session is already gone.
#
# This is deliberately NOT Swingbench. Swingbench answers "how fast is this
# workload" (see swingbench/README-swingbench.md). This answers only "are both
# nodes actually being used" -- a yes/no question that needs concurrency, not
# benchmarking rigor.
#
# Who:   Anyone with sqlplus and the NestWise schema password
# Where: Any host that can reach the RAC SCAN listener (an app server or a DB node)
# What:  ./rac_session_check.sh          # runs 20 sessions for 120s
#        ./rac_session_check.sh 40 300   # 40 sessions for 300s
# =============================================================================

SESSIONS=${1:-20}
DURATION=${2:-120}

# Match how the app itself connects -- SCAN listener, not a single instance.
# A direct //node1:1521/... connect string would defeat the entire purpose of
# this test by pinning every session to one node.
CONNECT_STRING="nestwise/${NESTWISE_PASSWORD}@//scan-usatclust1.usat.com:1521/apexdb_rw"

if [ -z "$NESTWISE_PASSWORD" ]; then
    echo "ERROR: set NESTWISE_PASSWORD first, e.g.:"
    echo "  read -s NESTWISE_PASSWORD && export NESTWISE_PASSWORD"
    echo "(read -s keeps it out of ~/.bash_history)"
    exit 1
fi

echo "Starting $SESSIONS concurrent sessions for ${DURATION}s against the SCAN listener..."
echo "While this runs, in a SEPARATE session run:"
echo
echo "  SELECT inst_id, COUNT(*) FROM gv\$session"
echo "  WHERE username = 'NESTWISE' GROUP BY inst_id ORDER BY inst_id;"
echo

for i in $(seq 1 "$SESSIONS"); do
    (
        END=$((SECONDS + DURATION))
        while [ $SECONDS -lt $END ]; do
            sqlplus -s "$CONNECT_STRING" <<'SQL' > /dev/null 2>&1
-- NestWise's actual hot-path reads, per loadtest/swingbench/workload_notes.md.
-- Plain SQL rather than the SYS_REFCURSOR-returning package functions, for the
-- same reason every APEX region on this project inlines them: a function
-- returning SYS_REFCURSOR can't be driven directly from a SQL statement.
SET FEEDBACK OFF
SELECT COUNT(*) FROM neighborhoods WHERE city = admin_pkg.get_current_city;

SELECT r.name, r.cuisine, r.rating
FROM restaurants r
WHERE r.rating >= 4.0
ORDER BY r.rating DESC
FETCH FIRST 20 ROWS ONLY;

SELECT n.name, COUNT(r.restaurant_id)
FROM neighborhoods n
LEFT JOIN restaurants r ON r.neighborhood_id = n.neighborhood_id
GROUP BY n.name;
EXIT
SQL
            sleep 0.2
        done
    ) &
done

wait
echo "Done. All $SESSIONS sessions have exited."
