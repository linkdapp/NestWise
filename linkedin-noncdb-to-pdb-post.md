# LinkedIn: non-CDB to PDB conversion

Companion to `linkedin-noncdb-to-pdb-carousel.html`. Post the carousel as a PDF and
paste the text below as the post body.

Source pages:
[Phase 7d index](monitoring/phase-7d-noncdb-to-pdb.md) ·
[Part 1](monitoring/phase-7d-part1-pre-deployment.md) ·
[Part 2](monitoring/phase-7d-part2-deployment.md) ·
[Part 3](monitoring/phase-7d-part3-post-deployment.md) ·
[Multitenant index](multitenant/README.md)

---

## Feed post

Oracle desupported the non-CDB architecture in Oracle Database 21c. If your database is
still a non-CDB, 19c is the ceiling. No Release Update moves it.

Mine was the Oracle Enterprise Manager repository, sitting at 19.32.0.0.0 on Oracle
Linux. Last week I moved it into a container database. Here is what that actually took.

First correction: there is no in-place conversion. You do not turn a non-CDB into a
CDB. You build a new container and plug the old database into it as a pluggable
database. `oemcdb` did not become a container; its contents became `oempdb` inside one.

The sequence:

1. `DBMS_PDB.DESCRIBE` writes an XML manifest of every datafile
2. `DBMS_PDB.CHECK_PLUG_COMPATIBILITY` reads it against the target container
3. `CREATE PLUGGABLE DATABASE ... USING ... COPY` adopts the files
4. `noncdb_to_pdb.sql` converts the dictionary
5. `OPEN`, then `SAVE STATE`
6. Create a service, because a PDB has no SID
7. Repoint Enterprise Manager at a service name instead

Second correction, and this one is Enterprise Manager specific: `emcli
migrate_noncdb_to_pdb` exists, takes `-migrationMethod=PLUG_AS_PDB`, and cannot be used
here. It drives a job through the OMS against a monitored target. The repository is the
database the OMS runs on, so the OMS stops the moment the source shuts down and the job
has nothing left to run in. The move is done by hand at the SQL level and Enterprise
Manager is told about it afterwards.

What went wrong:

`CHECK_PLUG_COMPATIBILITY` returned YES. Every gate I had checked in advance passed.
Then `noncdb_to_pdb.sql` stopped cold:

ORA-01722: invalid number
User tables dependent on Oracle-Maintained types need to be UPGRADED

Two tables, both SYSMAN Advanced Queuing payload columns: `EM_EVENT_BUS_TABLE` and
`EM_NOTIFY_QTABLE`. An Oracle-maintained type had evolved during some earlier upgrade
and the data was never converted. Nothing had ever reported it. The database ran
normally, `dba_invalid_objects` was clean, `datapatch` and `utlrp` both passed. It took
a conversion that nobody had ever run to surface it.

The fix is one script, `utluptabdata.sql`. Finding it is the work.

The part that changes how you operate afterwards: that check is per container, not per
database. Each PDB has its own dictionary and its own user tables, and there is no
`CDB_` view over `coltype$` to answer it from the root. `catcon.pl` across `CDB$ROOT`,
`PDB$SEED` and both PDBs is the routine form from here on, the same way `datapatch` and
`utlrp` now are.

Full SOP, every command, every error and the screenshots, on my GitHub Pages site. Link
in the comments.

What would you want to see next: the Data Guard rebuild on top of this, or the 19c to
26ai upgrade of the container?

#OracleDatabase #OracleDBA #Multitenant #OracleEnterpriseManager #DatabaseMigration
#Oracle19c #PDB #DBA #OracleACE #DatabaseAdministration

---

## First comment

Post this as the first comment rather than in the body, so the post itself is not
demoted for carrying an external link.

The whole thing is written up as a three-part SOP, including the parts that failed:

Index: https://linkdapp.github.io/NestWise/monitoring/phase-7d-noncdb-to-pdb.html
Part 1, pre-deployment, the eight compatibility gates
Part 2, the window itself, including the ORA-01722 stop and the fix
Part 3, post-deployment, repointing every target that still names the old SID

Also indexed by skill area: https://linkdapp.github.io/NestWise/multitenant/

---

## Notes on this draft

| Choice | Reason |
|---|---|
| Desupport in the first line | It is the only fact in the post that makes a reader check their own estate |
| `ORA-01722` and both table names in full | Searchable. A DBA hitting this error will find the post |
| No claim about window duration | Not recorded, so not stated |
| Link in the first comment | LinkedIn demotes posts carrying an external link in the body |
| Question at the end | Comments are weighted more heavily than reactions in the 2026 ranking |
