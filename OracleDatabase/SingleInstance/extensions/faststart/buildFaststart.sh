#!/bin/bash
# buildFaststart.sh - create CDB$ROOT+PDB$SEED plus TWO fully pre-converted
# customer-PDB variants (AL32UTF8 and WE8ISO8859P15 - the only two character
# sets actually used), all at build time, and package the result as a
# compressed archive that startFaststart.sh restores directly at container
# start (no dbca -createDatabase, no runtime INTERNAL_CONVERT there at all).
#
# Earlier version deferred both PDB creation AND character-set conversion to
# container start, reusing seedCreatePDB.sh unchanged. Measured (2026-09-20):
# INTERNAL_CONVERT across CDB$ROOT+PDB$SEED's ~1.9GB combined dictionary
# takes ~5:40 min BY ITSELF - it has to scan every character column in the
# whole dictionary (RU BLOB, Java, Spatial - see README's size breakdown),
# even though the actual content is pure ASCII and no byte remapping is
# needed. That swallowed almost all of the time faststart otherwise saves by
# skipping dbca's RMAN restore, defeating the whole point.
#
# Fix: since only two character sets are ever needed in practice, convert
# BOTH once here, at build time (paid once per image build, not once per
# container start), and ship both fully-completed PDBs in the archive.
# startFaststart.sh then just drops the unwanted one and renames the kept
# one to $ORACLE_PDB (ALTER PLUGGABLE DATABASE ... RENAME GLOBAL_NAME) -
# both cheap, metadata-mostly operations, seconds not minutes.
#
# Both variants are derived independently from the SAME US7ASCII
# CDB$ROOT+PDB$SEED, via a filesystem-level snapshot/restore between them -
# not by chaining the two conversions, and not by converting an already-
# cloned PDB. Two things found by testing rule those out:
#   - ALTER DATABASE CHARACTER SET INTERNAL_CONVERT is only supported
#     against CDB$ROOT+PDB$SEED itself (dbca's own sequence for its stock
#     seed); running it against an already-created ordinary PDB fails hard
#     with ORA-12715 (see mikedietrichde.com "Can you select a PDB's
#     character set?" - the only supported way to give a PDB a non-default
#     character set is to clone it from an already-differently-charset
#     PDB$SEED, never to convert it after the fact).
#   - INTERNAL_CONVERT's subset/superset check is about binary byte-
#     encoding compatibility, not abstract character repertoire coverage:
#     WE8ISO8859P15 -> AL32UTF8 fails with ORA-12712 even though Unicode
#     covers every ISO-8859-15 character, because their high bytes aren't
#     encoded the same way.
# See the "1/2." block below for the actual snapshot/convert/unplug/
# restore/convert/plug-in sequence.
set -euo pipefail

: "${ORACLE_HOME:?}" "${ORACLE_BASE:?}" "${SCRIPT_BASE_DIR:?}"

export ORACLE_SID=ORCLCDB
export ORACLE_PDB=ORCLPDB1
export ORACLE_PWD="${ORACLE_PWD:-Welcome1}"
# createDB.sh is called directly here, bypassing runOracle.sh's own
# ORACLE_CHARACTERSET default - see git history for the AL32UTF8-baked-in-at-
# build-time bug this explicit US7ASCII caught and fixed.
export ORACLE_CHARACTERSET=US7ASCII
PDB_ISO=PDBISO
PDB_UTF8=PDBUTF8
ARCHIVE="${ORACLE_BASE}/faststart-oradata.tar.xz"

log() { echo "[$(date -u +%H:%M:%SZ)] faststart-build: $*"; }

# createDB.sh (called directly here, bypassing runOracle.sh) expects
# ALLOCATED_MEMORY to already be exported - runOracle.sh normally computes
# this from cgroups before calling createDB.sh. Same detection, inlined.
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  memory=$(cat /sys/fs/cgroup/memory.max)
else
  memory=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
fi
[[ "${memory}" == "max" || -z "${memory}" ]] && memory=2147483648
export ALLOCATED_MEMORY=$((memory/1024/1024))

log "creating CDB\$ROOT + PDB\$SEED via createDB.sh..."
"${SCRIPT_BASE_DIR}/${CREATE_DB_FILE}" "${ORACLE_SID}" "${ORACLE_PDB}" "${ORACLE_PWD}"
log "created"

sql_show() {
  sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT FAILURE
SET LINESIZE 200 PAGESIZE 100 FEEDBACK OFF
$(cat)
EXIT
SQL
}
sql() {  # run a SQL script from stdin as SYSDBA, fail the build on any error
  sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT FAILURE
SET FEEDBACK ON HEADING OFF PAGESIZE 0 VERIFY OFF
$(cat)
EXIT
SQL
}
log "state after createDB.sh:"
sql_show <<'EOF'
COL name FOR a12
COL open_mode FOR a12
SELECT con_id, name, open_mode FROM v$pdbs;
SELECT value FROM nls_database_parameters WHERE parameter = 'NLS_CHARACTERSET';
EOF

seed_datafile_dir() {
  sqlplus -s / as sysdba <<SQL | tr -d ' \t\r\n'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT MIN(REGEXP_REPLACE(name, '[^/]+\$', '')) FROM v\$datafile WHERE con_id = 2;
EXIT
SQL
}

create_pdb_from_seed() {  # $1 = PDB name
  local name="$1" pdb_dir seed_dir
  seed_dir="$(seed_datafile_dir)"
  pdb_dir="${ORACLE_BASE}/oradata/${ORACLE_SID}/${name}"
  mkdir -p "${pdb_dir}"
  log "creating pluggable database ${name} from PDB\$SEED..."
  sql <<EOF
CREATE PLUGGABLE DATABASE ${name} ADMIN USER PDBADMIN IDENTIFIED BY "${ORACLE_PWD}"
  FILE_NAME_CONVERT = ('${seed_dir}', '${pdb_dir}/');
ALTER PLUGGABLE DATABASE ${name} OPEN;
ALTER PLUGGABLE DATABASE ${name} SAVE STATE;
ALTER SESSION SET CONTAINER = ${name};
CREATE TABLESPACE USERS DATAFILE '${pdb_dir}/users01.dbf' SIZE 5M REUSE AUTOEXTEND ON NEXT 1280K MAXSIZE UNLIMITED;
ALTER DATABASE DEFAULT TABLESPACE USERS;
ALTER SESSION SET CONTAINER = CDB\$ROOT;
GRANT SELECT ON sys.v_\$pdbs TO OPS\$oracle;
ALTER USER OPS\$oracle SET container_data = ALL FOR sys.v_\$pdbs CONTAINER = CURRENT;
EOF
}

convert_root_and_seed() {  # $1 = target charset
  local charset="$1"
  log "converting CDB\$ROOT + PDB\$SEED to ${charset}..."
  # ENABLE RESTRICTED SESSION only blocks NEW connections, it does not drop
  # already-connected ones - INTERNAL_CONVERT itself requires zero other
  # sessions (ORA-12721) and dbca/createDB.sh can leave a lingering
  # JDBC-based session behind for a moment after returning control (caught
  # by testing: this raced and failed on the very first conversion call,
  # right after createDB.sh). Kill everything but our own session first.
  sql <<'EOF0'
ALTER SYSTEM ENABLE RESTRICTED SESSION;
BEGIN
  FOR s IN (SELECT sid, serial# FROM v$session
            WHERE sid <> SYS_CONTEXT('USERENV','SID') AND type != 'BACKGROUND') LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION ''' || s.sid || ',' || s.serial# || ''' IMMEDIATE';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END;
/
EOF0
  converted=""
  for attempt in $(seq 1 10); do
    out=$(sqlplus -s / as sysdba <<EOF
SET FEEDBACK ON
ALTER DATABASE CHARACTER SET INTERNAL_CONVERT ${charset};
EOF
)
    echo "${out}"
    if ! grep -q 'ORA-' <<<"${out}"; then
      converted=1
      break
    fi
    if ! grep -q 'ORA-12721' <<<"${out}"; then
      log "ERROR: INTERNAL_CONVERT failed with an error other than ORA-12721, not retrying - see output above."
      exit 1
    fi
    log "  other sessions still active, killing and retrying (attempt ${attempt})..."
    sqlplus -s / as sysdba <<'EOF1' >/dev/null
BEGIN
  FOR s IN (SELECT sid, serial# FROM v$session
            WHERE sid <> SYS_CONTEXT('USERENV','SID') AND type != 'BACKGROUND') LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION ''' || s.sid || ',' || s.serial# || ''' IMMEDIATE';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END;
/
EOF1
    sleep 3
  done
  [ -n "${converted}" ] || { log "ERROR: INTERNAL_CONVERT still failing with ORA-12721 after 10 attempts."; exit 1; }
  sql <<EOF
ALTER SYSTEM DISABLE RESTRICTED SESSION;
ALTER SESSION SET "_oracle_script" = TRUE;
ALTER PLUGGABLE DATABASE PDB\$SEED CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE PDB\$SEED OPEN RESTRICTED;
ALTER SESSION SET CONTAINER = PDB\$SEED;
ALTER DATABASE CHARACTER SET INTERNAL_CONVERT ${charset};
ALTER SESSION SET CONTAINER = CDB\$ROOT;
ALTER PLUGGABLE DATABASE PDB\$SEED CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE PDB\$SEED OPEN READ ONLY;
EOF
}

# ---------------------------------------------------------------------------
# 1/2. Both variants, derived from the SAME US7ASCII CDB$ROOT+PDB$SEED
#    snapshot - not by chaining conversions (WE8ISO8859P15 -> AL32UTF8 is
#    NOT a valid INTERNAL_CONVERT direction: it fails with ORA-12712,
#    because Oracle's subset/superset check is about binary byte-encoding
#    compatibility, not abstract character repertoire coverage - ISO8859-15's
#    high bytes aren't the same bytes AL32UTF8 would use for those
#    characters, even though Unicode covers them), and not against an
#    already-created ordinary PDB either (ALTER DATABASE CHARACTER SET
#    INTERNAL_CONVERT is only supported against CDB$ROOT+PDB$SEED itself -
#    dbca's own sequence for its stock seed; running it against a plain
#    cloned PDB fails hard with ORA-12715 - see mikedietrichde.com "Can you
#    select a PDB's character set?"). Both found by testing.
#
#    So: snapshot the freshly created US7ASCII CDB$ROOT+PDB$SEED at the
#    filesystem level, convert+clone the ISO variant, UNPLUG it (keeps its
#    datafiles, drops it from the dictionary), restore the US7ASCII
#    snapshot (reverting CDB$ROOT+PDB$SEED only - the unplugged PDBISO's
#    files sit untouched in their own subdirectory), convert+clone the
#    UTF8 variant from that same pristine start, then PLUG PDBISO back in
#    (its datafiles never moved, so NOCOPY - pure dictionary registration).
# ---------------------------------------------------------------------------
US7ASCII_BACKUP=/tmp/cdbroot-seed-us7ascii-backup
PDBISO_MANIFEST=/tmp/pdbiso-manifest.xml

log "snapshotting US7ASCII CDB\$ROOT+PDB\$SEED..."
sqlplus -s / as sysdba <<'EOF'
WHENEVER SQLERROR EXIT FAILURE
SHUTDOWN IMMEDIATE;
EOF
mkdir -p "${US7ASCII_BACKUP}"
cp -a "${ORACLE_BASE}/oradata/${ORACLE_SID}/." "${US7ASCII_BACKUP}/"
sqlplus -s / as sysdba <<'EOF'
WHENEVER SQLERROR EXIT FAILURE
STARTUP;
EOF

convert_root_and_seed WE8ISO8859P15
create_pdb_from_seed "${PDB_ISO}"

log "unplugging ${PDB_ISO} (keeps its datafiles, only drops the dictionary entry)..."
sql <<EOF
ALTER PLUGGABLE DATABASE ${PDB_ISO} CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE ${PDB_ISO} UNPLUG INTO '${PDBISO_MANIFEST}';
EOF

log "restoring US7ASCII CDB\$ROOT+PDB\$SEED snapshot (keeping ${PDB_ISO}'s datafiles)..."
sqlplus -s / as sysdba <<'EOF'
WHENEVER SQLERROR EXIT FAILURE
SHUTDOWN IMMEDIATE;
EOF
find "${ORACLE_BASE}/oradata/${ORACLE_SID}" -mindepth 1 -maxdepth 1 ! -name "${PDB_ISO}" -exec rm -rf {} +
cp -a "${US7ASCII_BACKUP}/." "${ORACLE_BASE}/oradata/${ORACLE_SID}/"
sqlplus -s / as sysdba <<'EOF'
WHENEVER SQLERROR EXIT FAILURE
STARTUP;
EOF

convert_root_and_seed AL32UTF8
create_pdb_from_seed "${PDB_UTF8}"

log "plugging ${PDB_ISO} back in (datafiles never moved, so NOCOPY)..."
# TEMPFILE REUSE: UNPLUG doesn't preserve temp files (they hold no
# persistent data) - PLUG IN always tries to create a fresh one, but
# ${PDB_ISO}'s own old tempfile is still physically sitting at that exact
# path (its subdirectory was deliberately left untouched by the
# snapshot/restore above), so a plain CREATE fails with ORA-27038/ORA-01119
# "file already exists" (caught by testing). REUSE tells Oracle to reuse
# what's already there instead of erroring.
sql <<EOF
CREATE PLUGGABLE DATABASE ${PDB_ISO} USING '${PDBISO_MANIFEST}' NOCOPY TEMPFILE REUSE;
ALTER PLUGGABLE DATABASE ${PDB_ISO} OPEN;
ALTER PLUGGABLE DATABASE ${PDB_ISO} SAVE STATE;
EOF
rm -rf "${US7ASCII_BACKUP}" "${PDBISO_MANIFEST}"

log "state after both variants created:"
sql_show <<'EOF'
COL name FOR a12
COL open_mode FOR a12
SELECT con_id, name, open_mode FROM v$pdbs ORDER BY con_id;
EOF
for pdb in "${PDB_ISO}" "${PDB_UTF8}"; do
  sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
ALTER SESSION SET CONTAINER = ${pdb};
SELECT '${pdb}: ' || value FROM nls_database_parameters WHERE parameter='NLS_CHARACTERSET';
EXIT
EOF
done

# ---------------------------------------------------------------------------
# 3. Shrink the redo logs. dbca's default sizing (3 groups x 200MB here) is
#    generic, not tuned for this image - a faststart container's database
#     is a fixed, one-shot state with low expected write volume, so smaller
#    groups are fine. Redo logs can't be resized in place, only replaced:
#    add new small groups, switch until the old ones are no longer
#    CURRENT/ACTIVE, then drop them.
# ---------------------------------------------------------------------------
log "shrinking redo logs..."
# Capture group# and its file together, in one query, so the two can never
# drift apart (caught by testing: two separate unordered queries for group#
# and member gave no guaranteed index correspondence between the arrays).
# NOTE: strip only spaces/tabs/CR here, NOT newlines (`tr -d '[:space:]'`
# eats newlines too and collapses every row into one bogus concatenated
# element - caught by testing: it turned 3 groups [1,2,3] into a single
# element "123", making NEXT_GROUP=124 and the drop loop target a
# nonexistent group, silently leaving all 3 old 200M logs undropped).
# sql()'s own SET is FEEDBACK ON (wanted for the DDL calls elsewhere in
# this script, to log "Database altered." confirmations) - override it
# back OFF here since this is a plain SELECT into a bash array: a leaked
# "3 rows selected" footer line broke the NEXT_GROUP arithmetic below
# (caught by testing). The `^[0-9]+:` filter is a second, independent
# safety net against any other non-numeric line slipping through.
mapfile -t OLD_LOGS < <(sql <<'EOF' | tr -d ' \t\r' | grep -E '^[0-9]+:'
SET FEEDBACK OFF
SELECT l.group# || ':' || lf.member
FROM v$log l JOIN v$logfile lf ON lf.group# = l.group#
ORDER BY l.group#;
EOF
)
OLD_GROUPS=()
declare -A OLD_GROUP_FILE=()
for entry in "${OLD_LOGS[@]}"; do
  OLD_GROUPS+=("${entry%%:*}")
  OLD_GROUP_FILE["${entry%%:*}"]="${entry#*:}"
done
NEXT_GROUP=$(( $(printf '%s\n' "${OLD_GROUPS[@]}" | sort -n | tail -1) + 1 ))
for i in 1 2 3; do
  sql <<EOF
ALTER DATABASE ADD LOGFILE GROUP $((NEXT_GROUP + i - 1)) ('${ORACLE_BASE}/oradata/${ORACLE_SID}/redo_small_0${i}.log') SIZE 50M;
EOF
done
# Cycle enough times for every old group to become INACTIVE (never CURRENT).
for i in $(seq 1 $(( ${#OLD_GROUPS[@]} + 3 ))); do
  sql <<'EOF'
ALTER SYSTEM SWITCH LOGFILE;
EOF
done
sql <<'EOF'
ALTER SYSTEM CHECKPOINT;
EOF
for g in "${OLD_GROUPS[@]}"; do
  for attempt in $(seq 1 15); do
    # On an idle, freshly created database nothing triggers a log switch on
    # its own - sleeping alone never moves CURRENT off a lingering old
    # group (caught by testing: with exactly #OLD+#NEW switches, CURRENT
    # wraps back onto the very group it started on, leaving it permanently
    # undroppable without this). So actively switch+checkpoint on every
    # failed attempt instead of just waiting.
    if [ "${attempt}" -gt 1 ]; then
      sql <<'EOF2'
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM CHECKPOINT;
EOF2
    fi
    out=$(sqlplus -s / as sysdba <<EOF
SET FEEDBACK ON
ALTER DATABASE DROP LOGFILE GROUP ${g};
EOF
)
    if ! grep -q 'ORA-' <<<"${out}"; then
      # DROP LOGFILE GROUP only forgets the group, it does NOT delete the OS
      # file - remove it now, but ONLY for a group just confirmed dropped
      # (caught by testing: unconditionally deleting every originally-old
      # file regardless of whether its group's drop actually succeeded
      # deleted a file the database still referenced as an active online
      # log, crashing the instance with ORA-00313/ORA-00312 on next OPEN).
      rm -f "${OLD_GROUP_FILE[${g}]}"
      log "  redo group ${g} dropped (attempt ${attempt}), file removed"
      break
    fi
    sleep 2
  done
done
log "redo logs now:"
sql_show <<'EOF'
COL member FOR a60
SELECT l.group#, l.bytes/1048576 mb, lf.member FROM v$log l JOIN v$logfile lf ON lf.group# = l.group# ORDER BY 1;
EOF

# ---------------------------------------------------------------------------
# 4. Move DB config files into oradata/dbconfig/<SID> (same layout runOracle.sh
#    itself uses - see its moveFiles()/symLinkFiles() - so the archive is
#    self-contained: spfile, password file, network config, oratab copy).
# ---------------------------------------------------------------------------
log "consolidating config files into oradata/dbconfig..."
mkdir -p "${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}"
mv "${ORACLE_HOME}/dbs/spfile${ORACLE_SID}.ora"      "${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}/"
mv "${ORACLE_HOME}/dbs/orapw${ORACLE_SID}"           "${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}/"
mv "${ORACLE_HOME}/network/admin/sqlnet.ora"         "${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}/"
mv "${ORACLE_HOME}/network/admin/listener.ora"       "${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}/"
mv "${ORACLE_HOME}/network/admin/tnsnames.ora"       "${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}/"
cp /etc/oratab                                       "${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}/"

# ---------------------------------------------------------------------------
# 5. Shut down cleanly, stop the listener, remove build-time-only leftovers
#    that don't belong in the archive (audit/diag can regenerate; keeping
#    them would just bloat the archive with build-time-specific trace files).
# ---------------------------------------------------------------------------
log "shutting down..."
sqlplus -s / as sysdba <<'EOF'
WHENEVER SQLERROR CONTINUE
SHUTDOWN IMMEDIATE;
EOF
lsnrctl stop >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 6. Compress oradata (everything needed to restore: datafiles under
#    oradata/<SID>/, plus the config files just consolidated into
#    oradata/dbconfig/<SID>/) with xz - LZMA2, already present in the base
#    image, no extra package needed.
# ---------------------------------------------------------------------------
log "compressing oradata..."
tar -C "${ORACLE_BASE}" -cf - oradata | xz -T0 -6 > "${ARCHIVE}"
log "archive size: $(du -h "${ARCHIVE}" | cut -f1)"

# Raw oradata is now redundant - remove it so only the archive ends up in
# this stage's own layer (the final image COPYs just the archive from here).
rm -rf "${ORACLE_BASE}/oradata"
find "${ORACLE_BASE}/diag" -mindepth 1 -delete 2>/dev/null || true
sed -i "/${ORACLE_SID}/d" /etc/oratab 2>/dev/null || true

log "done: ${ARCHIVE}"
