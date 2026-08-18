# High Availability — Part 2: Data Guard Broker, Fast-Start Failover, and Observer

**SOP: Data Guard Standby (`usatclust2`) — 2-Node Physical Standby for `apexdb`, on Oracle Linux 7**

Part 2 of 3 in this Data Guard series. [Part 1](part1-active-data-guard.md) covers the host
build through role-based services — read that first if you're starting fresh; this page
assumes `apexdb_stby` is already a confirmed, working Active Data Guard standby (Part 1,
Sections 1-13). **Part 2 (this page)** covers the Data Guard Broker, a real switchover
test, and Fast-Start Failover with the Observer. [Part 3](part3-post-checks.md) covers
post-standby validation.

Status: 🟩 Confirmed — both sections below ran clean end to end against the live lab.

| # | Section | Status |
|---|---|---|
| 14 | Data Guard Broker configuration | 🟩 Confirmed |
| 15 | Fast-Start Failover and Observer | 🟩 Confirmed |

**Section 14 is confirmed (🟩)** — Data Guard Broker configuration
(`CREATE CONFIGURATION`/`ADD DATABASE`/`ENABLE CONFIGURATION`,
MaxAvailability protection mode, `LogXptMode='SYNC'`) ran clean end to end
against the live lab after three real-run rounds of fixes, and the
standalone `dataguard_switchover_test` role subsequently confirmed a real
`SWITCHOVER TO apexdb_stby` correctly flips both the database roles and
[Part 1](part1-active-data-guard.md) Section 13's `apexdb_rw`/`apexdb_ro` services with no manual `srvctl`
intervention — see
[`known-risks.md`](../phase-01-foundation-2node-rac-12cR2/docs/known-risks.md)
#137 for the full debugging journey (a wrong DGMGRL invocation mechanism, two real
Oracle errors on the standby's broker startup, a dropped 18c-only `VALIDATE` command,
and the switchover test's own confirmed run). **Section 15 is confirmed too (🟩)** —
Fast-Start Failover enabled, Observer running on `oemserver01` under wallet auth,
confirmed against the live lab (three real-run rounds of fixes of its own — see
`known-risks.md` #138).

Before starting here, read
[`known-risks.md`](../phase-01-foundation-2node-rac-12cR2/docs/known-risks.md) — the
same reasoning doc referenced throughout [Part 1](part1-active-data-guard.md).

Screenshots referenced below go in [`screenshots/`](screenshots/) once captured — same
naming convention as `installation/`'s Section 15, numbered to match this page's own
section numbers (14, 15).

---

## Contents

14. [🟩 Confirmed — Data Guard Broker configuration](#14-confirmed--data-guard-broker-configuration)
15. [🟩 Confirmed — Fast-Start Failover and Observer](#15-confirmed--fast-start-failover-and-observer)

Back to **[Part 1 — Setting Up Active Data Guard](part1-active-data-guard.md)**. Continue to
**[Part 3 — Post checks](part3-post-checks.md)**.

---

## 14. 🟩 Confirmed — Data Guard Broker configuration
See `known-risks.md` #137 for the full debugging journey.

**What it does, in order:**

1. Checks and creates the ASM `/DG` subdirectory under both diskgroups on
   BOTH clusters (`+DATA01/apexdb/DG`, `+RECO01/apexdb/DG` on the primary;
   the equivalent pair under `apexdb_stby` on the standby) — closes the gap
   `known-risks.md` #98/#99 left open. ASM has no `mkdir -p`; the parent
   `{{ db_unique_name }}/` directory already existed (DBCA created it), so
   this is one check-then-create step per diskgroup, not a multi-level walk.
   ```
   # -- On the Primary
   $ asmcmd ls -l +DATA01/apexdb/DG
   $ asmcmd ls -l +RECO01/apexdb/DG# -- On the Standby
   $ asmcmd ls -l +DATA01/apexdb_stby/DG
   $ asmcmd ls -l +RECO01/apexdb_stby/DG
   ```
2. Relocates the **primary's** `dg_broker_config_file1/2` onto the new
   `/DG` path via the disable → set → enable dance (`known-risks.md` #81).
   Restarts the **standby's** broker the same way (disable → RE-SET
   `dg_broker_config_file1/2`.
	```
	SQL> alter system set dg_broker_start=true scope=both sid='*';
	```
	📸 *Screenshot: Show_primary_broker_config_file.png
	
3. PAUSE, then clears `log_archive_dest_2` on both databases
   (check-then-clear, idempotent) — Broker manages it from here.
	```
	SQL> alter system set log_archive_dest_2='' scope=both sid='*';
	
	```
   
4. `CREATE CONFIGURATION`, `ADD DATABASE`, and `ENABLE CONFIGURATION` as
   three **independently gated** steps (not one all-or-nothing block —
   `ADD DATABASE` gates on whether the standby specifically is already a
   member, so a partially-built configuration from an earlier failed run
   still gets completed correctly on the next one). Uses the renamed
   `apexdb_DGMGRL`/`apexdb_stby_DGMGRL` TNS aliases (`UR=A`, any-state
   connectivity) as the connect identifiers, not the plain app-facing
   aliases — matters most during an actual switchover/failover. Invoked via
   shell input redirection (`dgmgrl < script`), not a `@script` argument —
   the latter is RMAN/SQL\*Plus convention, not valid DGMGRL syntax (#137).
   
   ```
   DGMGRL> create configuration apexdb_dg as primary database is apexdb connect identifier is apexdb_DGMGRL;
   DGMGRL> add database apexdb_stby as connect identifier is apexdb_stby_DGMGRL maintained as physical;
   DGMGRL> enable configuration;
   ```
   📸 *Screenshot: Show_create_configuration.png.*
   
5. Sets MAA properties: `LogXptMode='SYNC'` on both databases (required for
   MaxAvailability — NOT `'ASYNC'`, `StandbyFileManagement='AUTO'` on the standby,
   `FastStartFailoverTarget` on both.
   ```
   DGMGRL> edit database apexdb  set property logxptmode='sync';
   DGMGRL> edit database apexdb_stby set property logxptmode='sync';
   DGMGRL> edit database apexdb_stby set property standbyfilemanagement='auto';
   DGMGRL> edit configuration set protection mode as maxperformance;   -- or maxavailability if latency allows sync
   DGMGRL> edit database apexdb  set property faststartfailovertarget='apexdb_stby';
   DGMGRL> edit database apexdb_stby set property faststartfailovertarget='apexdb';
   DGMGRL> show configuration verbose;
   ```
6. Sets protection mode to **MaxAvailability** `LogXptMode` Must be `sync`, which is why step 5
   runs first.
   ```
   DGMGRL> edit configuration set protection mode as maxavailability;
   ```
   📸 *Screenshot: Show_current_protection_mode.png.*
   
7. Final health check: `SHOW CONFIGURATION VERBOSE` + `SHOW DATABASE
   VERBOSE` for both databases. (`VALIDATE STATIC CONNECT IDENTIFIER` was
   dropped — real DGMGRL syntax, but introduced in Oracle 18c; this lab's
   DGMGRL is 12.2.0.1.0. `dataguard_net_config`'s existing `tnsping` + real
   `sqlplus` login against the `_DGMGRL` aliases already covers the same
   practical ground on this version.)
   ```
   DGMGRL> show configuration;
   DGMGRL> show database verbose apexdb;
   DGMGRL> show database verbose apexdb_stby;
   ```
   
   📸 *Screenshot: Show_enabled_configuration.png.*
   
8. The switchover test lives in its own standalone role/play.
   
   ```
   $ ansible-playbook -i inventory/hosts.ini site.yml --tags dataguard_switchover_test -e sys_password='<redacted>'
   ```
**What it does, in order:**
	 —
   `roles/dataguard_switchover_test`, `--tags dataguard_switchover_test` —
   not a flag on this role. Direction-agnostic: it queries `SHOW
   CONFIGURATION` first to determine which database is currently primary,
   issues `SWITCHOVER TO <currently-standby>`, then verifies both the real
   `database_role` via SQL and whether Section 13's role-based services
   flipped automatically via `srvctl status service` on both clusters.
   Re-running the same role/tag switches back.
   
   ```
   DGMGRL> switchover to apexdb_stby;
   Switchover succeeded, new primary is "apexdb_stby"
   ```

   ```
   DGMGRL> show configuration;
   DGMGRL> show database verbose apexdb;
   DGMGRL> show database verbose apexdb_stby;
   ```
   
   📸 *Screenshot: Switchover_confirmed_role_flip.png.*

   ```
   # --- New Primary (Old Standby)
   SQL> col host_name for a20
   SELECT d.NAME,
   i.INSTANCE_NAME,
   i.HOST_NAME,
   i.STATUS,
   d.OPEN_MODE,
   d.SWITCHOVER_STATUS,
   i.DATABASE_STATUS
   FROM   gv$instance i
   JOIN   gv$database d ON i.INST_ID = d.INST_ID;
   
   NAME      INSTANCE_NAME    HOST_NAME            STATUS  OPEN_MODE    SWITCHOVER_STATUS    DATABASE_STATUS
   --------- ---------------- -------------------- ------- -----------  -------------------- -----------------
   APEXDB    apexdb2          oradbserv10.usat.com OPEN    READ WRITE   TO STANDBY           ACTIVE
   APEXDB    apexdb1          oradbserv09.usat.com OPEN    READ WRITE   TO STANDBY           ACTIVE
   
   ```
📸 *Screenshot: Show_switchover_output.png

   ``` 
   # --- New Standby (Old Primary)
   SQL> col host_name for a20
   SELECT d.NAME,
   i.INSTANCE_NAME,
   i.HOST_NAME,
   i.STATUS,
   d.OPEN_MODE,
   d.SWITCHOVER_STATUS,
   i.DATABASE_STATUS
   FROM   gv$instance i
   JOIN   gv$database d ON i.INST_ID = d.INST_ID;

   NAME      INSTANCE_NAME    HOST_NAME            STATUS       OPEN_MODE            SWITCHOVER_STATUS    DATABASE_STATUS
   --------- ---------------- -------------------- ------------ -------------------- -------------------- -----------------
   APEXDB    apexdb1          oradbserv05.usat.com OPEN         READ ONLY WITH APPLY NOT ALLOWED          ACTIVE
   APEXDB    apexdb2          oradbserv06.usat.com OPEN         READ ONLY WITH APPLY NOT ALLOWED          ACTIVE
   
   SQL>
   ```


📸 *Screenshot: Show_configuration_pre_switchover.png.*



---

## 15. 🟩 Confirmed — Fast-Start Failover and Observer

```
$ ansible-playbook -i inventory/hosts.ini site.yml --tags dataguard_fsfo -e sys_password='<redacted>' -e dg_observer_wallet_password='<redacted>'
```

**What it does, in order:**

1. Closes a real gap found while scoping this (not guessed — confirmed by reading
   `dataguard_standby_prep`): Flashback Database was enabled on the primary back in
   Phase 1, but never on `apexdb_stby`. Without it on both sides, a failed-over old
   primary can't auto-reinstate as the new standby. Fixed via the Broker-driven
   sequence (`EDIT DATABASE apexdb_stby SET STATE='APPLY-OFF'` → `ALTER DATABASE
   FLASHBACK ON` → `SET STATE='APPLY-ON'`), not a raw open/mount dance.
2. Bootstraps `oemserver01` under Ansible for the first time — new `[observer_nodes]`
   inventory group, the same manual one-time `ansible` OS-user + SSH-key trust dance
   documented in `docs/ansible-on-windows.md` #4, then the same missing-`python3`
   bootstrap play every other node needed the first time (`known-risks.md` #17).

   ```
   # --- On oemserver01 (as oracle)
   sudo useradd -m -s /bin/bash ansible
   sudo passwd ansible
   echo "ansible ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ansible
   sudo chmod 0440 /etc/sudoers.d/ansible
   ```
   
   📸 *Screenshot: creating_observer_directory.png
   ```
   Then from WSL2 (control node — reuses the same ansible-control key you already generated for 
   the other 4 nodes, no need to regenerate):
   
   $ ssh-copy-id ansible@192.168.56.65
   
   Then confirm:
   
   $ ansible -i inventory/hosts.ini oemserver01 -m ping
   ```
3. Idempotent directory checks (`/opt/oracle/fsfo`, `/opt/oracle/wallets`), appends
   (never overwrites — `oemserver01` already had its own `tnsnames.ora`/`sqlnet.ora`
   entries) the `apexdb_DGMGRL`/`apexdb_stby_DGMGRL` TNS aliases and`SQLNET.WALLET_OVERRIDE` config.
   
   ```
   # --- Create directories
   $ sudo mkidr -p /opt/oracle/fsfo
   $ sudo mkdir -p /opt/oracle/wallets
   $ sudo chown -R oracle:oinstall /opt/oracle
   
   # --- Updataes sqlnet.ora file
   
   $ cat >> $TNS_ADMIN/sqlnet.ora <<EOF
   WALLET_LOCATION =
     (SOURCE =
       (METHOD = FILE)
       (METHOD_DATA =
         (DIRECTORY = /opt/oracle/wallet)
       )
     )
   SQLNET.WALLET_OVERRIDE = TRUE
   SSL_CLIENT_AUTHENTICATION = FALSE
   EOF
   ```
4. Creates an Oracle Wallet and credentials for both aliases via `mkstore`, every
   prompt answered over stdin (never a command-line argument), then actually tests
   `/@apexdb_DGMGRL` and `/@apexdb_stby_DGMGRL` connect with no password before
   trusting the wallet for anything else.
   ```
   $ $ORACLE_HOME/mkstore -wrl /opt/oracle/wallets -create
   `# enter a wallet password when prompted`
   
   $ $ORACLE_HOME/mkstore -wrl /opt/oracle/wallets -listCredential
   $ $ORACLE_HOME/mkstore -wrl /opt/oracle/wallets -createCredential apexdb_DGMGRL SYS <SYS_password>
   $ $ORACLE_HOME/mkstore -wrl /opt/oracle/wallets -createCredential apexdb_stby_DGMGRL SYS <SYS_password>
   
   DGMGRL> connect /@apexdb_DGMGRL as sysdba
   Connected to "apexdb"
   Connected as SYSDBA.
   ```
5. Sets `FastStartFailoverThreshold` (30s, Oracle's own default) and
   `ENABLE FAST_START FAILOVER` from the primary:

   📸 *Screenshot: Show_current_FSFO_status.png
   
      ```
   DGMGRL> edit configuration set property FastStartFailoverThreshold=30;
   DGMGRL> enable fast_start failover;
   DGMGRL> show fast_start failover;
   Fast-Start Failover: Enabled in Zero Data Loss Mode
     Threshold:          30 seconds
     Target:             apexdb_stby
   ```
   📸 *Screenshot: Show_FSFO_enabled_status.png.*
   
6. Starts the Observer itself, wallet-authenticated (no embedded password, unlike
   every other one-shot DGMGRL script in this project — this one runs indefinitely
   in the background and has to reconnect on its own):
   ```
   DGMGRL> start observer oemserver01_observer in background file is
     '/opt/oracle/fsfo/oemserver01_observer.dat' logfile is
     '/opt/oracle/fsfo/oemserver01_observer.log' connect identifier is apexdb_DGMGRL;
   Submitted command "START OBSERVER" using connect identifier "apexdb_DGMGRL"
   ```
7. Verifies via `SHOW FAST_START FAILOVER` + `SHOW OBSERVERS` — not just trusting
   that the start command returned successfully (DGMGRL has no `whenever sqlerror`
   equivalent; see `known-risks.md` #138 for the debugging journey behind exactly why
   that distinction mattered here):


   ```
   DGMGRL> show observers;
   Observer "oemserver01_observer"(19.48.0.0.0) - Master
     Host Name:              oemserver01.usat.com
     Last Ping to Primary:   3 seconds ago
     Last Ping to Target:    3 seconds ago
   ``` 
   📸 *Screenshot: show_observer.png
   
      ```
   DGMGRL> show fast_start failover;
   ```

   📸 *Screenshot: show_fast_start_fail_over.png
   
   
**What's left, stated plainly:** the induced-failover test — actually killing the
primary and watching the Observer auto-promote `apexdb_stby` — lives in its own
standalone role (`roles/dataguard_fsfo_test`, `--tags dataguard_fsfo_test`, same
separation-of-concerns reasoning as the switchover test) and hasn't been built or
run yet. Everything confirmed above is FSFO *armed*, not yet exercised against a
real outage. See [Part 3](part3-post-checks.md) for the remaining post-standby
validation work.

---

Back to **[Part 1 — Setting Up Active Data Guard](part1-active-data-guard.md)**. Continue to
**[Part 3 — Post checks](part3-post-checks.md)**.
