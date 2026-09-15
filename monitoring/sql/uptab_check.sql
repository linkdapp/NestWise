-- uptab_check.sql
--
-- Lists tables holding data in columns of evolved Oracle-maintained types that has
-- never been converted. `noncdb_to_pdb.sql` refuses to run while any row is
-- returned, and stops with ORA-01722.
--
-- Read-only. No rows is the expected result.
-- Remediate with @?/rdbms/admin/utluptabdata.sql in the container that returned rows.
--
-- Run as SYS. Safe to run in any container, and under catcon.pl across all of them:
--
--   $ORACLE_HOME/perl/bin/perl $ORACLE_HOME/rdbms/admin/catcon.pl \
--     -u sys -d <dir holding this file> -l <log dir> -b uptab_check uptab_check.sql
--
-- Documented in phase-7d-part1-pre-deployment.md section 1.9 and
-- phase-7d-part2-deployment.md section 6.1.

SET PAGESIZE 200
SET LINESIZE 200
SET FEEDBACK ON
COLUMN owner       FORMAT A30
COLUMN table_name  FORMAT A30
COLUMN column_name FORMAT A30

PROMPT
PROMPT === uptab_check: tables dependent on Oracle-maintained types ===

SELECT SYS_CONTEXT('USERENV', 'CON_NAME') AS container FROM dual;

SELECT u.name AS owner, o.name AS table_name, c.name AS column_name
FROM   sys.obj$ o, sys.col$ c, sys.coltype$ t, sys.user$ u
WHERE  BITAND(t.flags, 256) = 256
AND    o.obj#  = t.obj#
AND    c.obj#  = t.obj#
AND    c.col#  = t.col#
AND    t.intcol# = c.intcol#
AND    o.owner# = u.user#
AND    o.owner# NOT IN
       (SELECT user# FROM sys.user$
        WHERE  type# = 1 AND BITAND(spare1, 256) = 256)
AND    t.obj# IN
       (SELECT DISTINCT d_obj#
        FROM   sys.dependency$
        START WITH p_obj# IN
               (SELECT obj# FROM sys.obj$
                WHERE  type# = 13 AND BITAND(flags, 4194304) = 4194304)
        CONNECT BY PRIOR d_obj# = p_obj#)
ORDER  BY 1, 2, 3;

PROMPT === end uptab_check ===
PROMPT
