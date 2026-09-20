#!/bin/bash
# SE2 licensing hygiene, run once after database creation via the standard
# user-scripts hook (runOracle.sh -> runUserScripts.sh $ORACLE_BASE/scripts/setup).
#
# A freshly created 19c database defaults to CONTROL_MANAGEMENT_PACK_ACCESS=
# 'DIAGNOSTIC+TUNING', i.e. it happily uses the Diagnostics and Tuning Packs
# (AWR/ADDM/ASH reports, SQL Tuning Advisor auto task, ...). Both packs are
# EE-only options that cannot be licensed for Standard Edition 2 at all, and
# every use is recorded in DBA_FEATURE_USAGE_STATISTICS. Same story for the
# Heat Map (part of the Advanced Compression Option). These settings mirror
# what ZEDAS' Ansible role (roles/oracleserver, "Lizenzrelevantes") sets on
# every customer database.
#
# Applied to CDB$ROOT (inherited by all PDBs) and to $ORACLE_PDB explicitly
# for the container-local auto task; for NON_CDB databases only the first part.
set -e
echo "Applying SE2 licensing settings (management packs off, tuning advisor off, heat map off)"
sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK OFF
ALTER SYSTEM SET control_management_pack_access = 'NONE' SCOPE=BOTH;
ALTER SYSTEM SET heat_map = 'OFF' SCOPE=BOTH;
BEGIN
  DBMS_AUTO_TASK_ADMIN.DISABLE('sql tuning advisor', NULL, NULL);
END;
/
DECLARE
  v_cdb VARCHAR2(3);
  v_open NUMBER;
BEGIN
  SELECT cdb INTO v_cdb FROM v\$database;
  IF v_cdb = 'YES' THEN
    SELECT COUNT(*) INTO v_open FROM v\$pdbs WHERE name = UPPER('${ORACLE_PDB}') AND open_mode = 'READ WRITE';
    IF v_open = 1 THEN
      EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = ${ORACLE_PDB}';
      DBMS_AUTO_TASK_ADMIN.DISABLE('sql tuning advisor', NULL, NULL);
    END IF;
  END IF;
END;
/
SET FEEDBACK ON HEADING ON
COL name FOR a34
COL value FOR a20
SELECT name, value FROM v\$parameter WHERE name IN ('control_management_pack_access','heat_map');
EXIT
SQL
