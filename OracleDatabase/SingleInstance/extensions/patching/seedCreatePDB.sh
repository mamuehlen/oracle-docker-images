#!/bin/bash
# 10_seedCreatePDB.sh - finish what dbca can't do with the regenerated seed:
# convert the character set and create $ORACLE_PDB.
#
# Runs once after database creation via runOracle.sh -> runUserScripts.sh
# "$ORACLE_BASE/scripts/extensions/setup" (sourced, so ORACLE_SID/ORACLE_PDB/
# ORACLE_PWD/ORACLE_CHARACTERSET/NON_CDB from runOracle.sh are available).
# No-op with the stock seed (REGENERATE_SEED=false): dbca did all of this.
#
# Background (see regenerateSeedTemplate.sh and the README): the regenerated
# seed is a CDB clone template. dbca restores it fine, but
#   - does not convert its character set (only warns DBT-11153) and
#   - refuses to create PDBs from it (DBT-10312).
# Oracle's own seed handles the character set by being US7ASCII and having
# dbca run "ALTER DATABASE CHARACTER SET INTERNAL_CONVERT <cs>" in CDB$ROOT
# and then in PDB$SEED (CLOSE IMMEDIATE / OPEN RESTRICTED / convert / CLOSE /
# OPEN READ ONLY). Our template is built in US7ASCII for exactly that reason,
# and this hook replays dbca's sequence - same statements, same kind of
# database (fresh seed, pure-ASCII dictionary, no user data), same direction
# (US7ASCII is a strict subset of every character set). Then it creates the
# PDB from the converted PDB$SEED, so the whole CDB ends up in
# ORACLE_CHARACTERSET, exactly as with the stock image.

seed_finish_db() {
  local state charset db_cs seed_dir pdb_dir pdb_admin_pwd valid
  if [ "${NON_CDB:-false}" = "true" ] || [ "${CONTAINER_DATABASE:-true}" = "false" ]; then
    return 0
  fi
  state="$(sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT d.cdb || ':' || (SELECT COUNT(*) FROM v\$pdbs p WHERE p.name = UPPER('${ORACLE_PDB}'))
       || ':' || (SELECT value FROM nls_database_parameters WHERE parameter = 'NLS_CHARACTERSET')
  FROM v\$database d;
EXIT
SQL
)"
  state="$(tr -d '[:space:]' <<<"${state}")"
  case "${state}" in
    YES:0:*) db_cs="${state##*:}" ;;   # CDB, PDB missing -> regenerated seed, continue
    *)       return 0 ;;                # non-CDB, or dbca created the PDB (stock seed)
  esac

  charset="${ORACLE_CHARACTERSET:-AL32UTF8}"; charset="${charset^^}"

  # -------- 1. character set: replay dbca's conversion of the US7ASCII seed --------
  if [ "${db_cs}" != "${charset}" ]; then
    valid="$(sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT COUNT(*) FROM v\$nls_valid_values WHERE parameter = 'CHARACTERSET' AND value = '${charset}';
EXIT
SQL
)"
    if [ "$(tr -d '[:space:]' <<<"${valid}")" != "1" ]; then
      echo "ERROR: ORACLE_CHARACTERSET=${charset} is not a valid database character set (see V\$NLS_VALID_VALUES)."
      return 1
    fi
    if [ "${db_cs}" != "US7ASCII" ]; then
      echo "ERROR: database character set is ${db_cs}, expected the seed's US7ASCII - refusing to convert to ${charset}."
      return 1
    fi
    echo "Converting character set US7ASCII -> ${charset} in CDB\$ROOT and PDB\$SEED (dbca's own sequence for its seed database)."
    sqlplus -s / as sysdba <<SQL || return 1
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK ON
ALTER SYSTEM ENABLE RESTRICTED SESSION;
ALTER DATABASE CHARACTER SET INTERNAL_CONVERT ${charset};
ALTER SYSTEM DISABLE RESTRICTED SESSION;
ALTER SESSION SET "_oracle_script" = TRUE;
ALTER PLUGGABLE DATABASE PDB\$SEED CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE PDB\$SEED OPEN RESTRICTED;
ALTER SESSION SET CONTAINER = PDB\$SEED;
ALTER DATABASE CHARACTER SET INTERNAL_CONVERT ${charset};
ALTER SESSION SET CONTAINER = CDB\$ROOT;
ALTER PLUGGABLE DATABASE PDB\$SEED CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE PDB\$SEED OPEN READ ONLY;
SET HEADING ON
SELECT con_id, name, open_mode FROM v\$pdbs;
EXIT
SQL
  fi

  # -------- 2. the PDB dbca couldn't create (DBT-10312) --------
  echo "Creating pluggable database ${ORACLE_PDB} (${charset}) from PDB\$SEED."
  pdb_dir="${ORACLE_BASE}/oradata/${ORACLE_SID}/${ORACLE_PDB}"
  mkdir -p "${pdb_dir}"
  # PDBADMIN: same password as SYS/SYSTEM when ORACLE_PWD is set (as dbca's
  # pdbAdminPassword would be), otherwise random - it isn't meant to be used.
  pdb_admin_pwd="${ORACLE_PWD:-$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-16)_1}"
  seed_dir="$(sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT MIN(REGEXP_REPLACE(name, '[^/]+\$', '')) FROM v\$datafile WHERE con_id = 2;
EXIT
SQL
)"
  seed_dir="$(tr -d '[:space:]' <<<"${seed_dir}")"

  # USERS tablespace + default tablespace, SAVE STATE, OPS$oracle grants:
  # everything dbca/createDB.sh would have done had the PDB existed.
  sqlplus -s / as sysdba <<SQL || return 1
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK ON
CREATE PLUGGABLE DATABASE ${ORACLE_PDB} ADMIN USER PDBADMIN IDENTIFIED BY "${pdb_admin_pwd}"
  FILE_NAME_CONVERT = ('${seed_dir}', '${pdb_dir}/');
ALTER PLUGGABLE DATABASE ${ORACLE_PDB} OPEN;
ALTER PLUGGABLE DATABASE ${ORACLE_PDB} SAVE STATE;
ALTER SESSION SET CONTAINER = ${ORACLE_PDB};
CREATE TABLESPACE USERS DATAFILE '${pdb_dir}/users01.dbf' SIZE 5M REUSE AUTOEXTEND ON NEXT 1280K MAXSIZE UNLIMITED;
ALTER DATABASE DEFAULT TABLESPACE USERS;
ALTER SESSION SET CONTAINER = CDB\$ROOT;
GRANT SELECT ON sys.v_\$pdbs TO OPS\$oracle;
ALTER USER OPS\$oracle SET container_data = ALL FOR sys.v_\$pdbs CONTAINER = CURRENT;
SET HEADING ON
COL name FOR a12
COL open_mode FOR a12
SELECT con_id, name, open_mode FROM v\$pdbs;
SELECT parameter, value FROM nls_database_parameters WHERE parameter IN ('NLS_CHARACTERSET','NLS_NCHAR_CHARACTERSET');
EXIT
SQL
}

# sourced by runUserScripts.sh: return (not exit) so the remaining setup hooks
# still run; the health check (checkDBStatus.sh) then reports the missing PDB.
seed_finish_db || { echo "ERROR: 10_seedCreatePDB.sh failed - see messages above"; return 1; }
