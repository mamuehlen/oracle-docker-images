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
ARCHIVE="${ORACLE_BASE}/faststart-oradata.7z"

log() { echo "[$(date -u +%H:%M:%SZ)] faststart-build: $*"; }

# createDB.sh (called directly here, bypassing runOracle.sh) expects
# ALLOCATED_MEMORY to already be exported - runOracle.sh normally computes
# this from cgroups before calling createDB.sh. Same detection, inlined.
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  memory=$(cat /sys/fs/cgroup/memory.max)
else
  memory=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
fi
# 2GiB (runOracle.sh's own fallback, matched here for 19c) sizes dbca.rsp's
# sga_target too small for 23ai: caught by testing against a 23.26 Gold
# Image - "ORA-00821: Specified value of sga_target 1536M is too small,
# needs to be at least 2896M" (1536M = 75% of a 2GiB ALLOCATED_MEMORY).
# 4GiB comfortably covers both.
[[ "${memory}" == "max" || -z "${memory}" ]] && memory=4294967296
export ALLOCATED_MEMORY=$((memory/1024/1024))

# We create both customer-PDB variants ourselves later - our own 19.32
# regenerated seed template already has numberOfPDBs=0 (regenerateSeedTemplate.sh
# sets it, since dbca can't create PDBs from a CDB clone template anyway -
# DBT-10312), but a stock, non-regenerated template (e.g. a 23.26 Gold
# Image's own, which this buildFaststart.sh never modified) defaults to
# numberOfPDBs=1 and would have dbca auto-create its own customer PDB
# alongside PDB$SEED - caught by testing: that PDB ends up named after
# $ORACLE_PDB same as ours, and startFaststart.sh's later
# RENAME GLOBAL_NAME TO $ORACLE_PDB then fails with "ORA-65042: name is
# already used by an existing container". Forced to 0 here, unconditionally,
# so this doesn't depend on whichever base image's template happens to
# already have it set right.
sed -i -e 's|^numberOfPDBs=.*|numberOfPDBs=0|' "${SCRIPT_BASE_DIR}/dbca.rsp.tmpl"

# createDB.sh unconditionally passes "-createListener LISTENER:1521" to dbca,
# which makes dbca invoke netca to auto-configure that listener if none by
# that name is already running - netca resolves its own hostname to bind to,
# which works fine in a real container (docker/podman populate /etc/hosts
# with a resolvable entry for the container's own hostname) and in a local
# `podman build` RUN step (same reason), but NOT in a GitHub Actions
# self-hosted runner's BuildKit (`docker buildx`) RUN step: its ephemeral
# build-sandbox hostname has no /etc/hosts entry at all, so netca fails hard
# with "No valid IP Address returned for the host buildkitsandbox" - caught
# by testing (2026-09-20, first real CI run of this extension). dbca skips
# netca entirely if a listener by that name is already running, so start one
# ourselves first with a static, always-resolvable address - the exact fix
# extensions/patching/regenerateSeedTemplate.sh already uses for the same
# underlying "dbca insists on a running listener" problem (there avoided by
# never passing -createListener to its own raw dbca call at all; not an
# option here since createDB.sh's own dbca call is what does that,
# unconditionally, and reimplementing createDB.sh's version/TDE/OMF-aware
# dbca invocation here isn't worth it just to drop one flag).
mkdir -p "${ORACLE_HOME}/network/admin"
cat > "${ORACLE_HOME}/network/admin/listener.ora" <<EOF
LISTENER =
(DESCRIPTION_LIST =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1))
    (ADDRESS = (PROTOCOL = TCP)(HOST = 127.0.0.1)(PORT = 1521))
  )
)
DIAG_ADR_ENABLED = off
EOF
lsnrctl start >/dev/null
log "pre-started a static listener on 127.0.0.1:1521 (works around netca's hostname lookup failing in a BuildKit build sandbox)"

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

db_create_file_dest() {
  sqlplus -s / as sysdba <<SQL | tr -d ' \t\r\n'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT value FROM v\$parameter WHERE name = 'db_create_file_dest';
EXIT
SQL
}

create_pdb_from_seed() {  # $1 = PDB name
  local name="$1" pdb_dir seed_dir omf_dest datafile_clause tablespace_stmt
  seed_dir="$(seed_datafile_dir)"
  pdb_dir="${ORACLE_BASE}/oradata/${ORACLE_SID}/${name}"
  mkdir -p "${pdb_dir}"
  log "creating pluggable database ${name} from PDB\$SEED..."
  # Oracle Managed Files (db_create_file_dest set - the case for a 23.26
  # Gold Image's stock seed, unlike our own regenerated 19.32 one, which
  # doesn't use OMF): PDB$SEED's datafiles are named "o1_mf_*", and
  # FILE_NAME_CONVERT-ing that same OMF-looking name into a new directory
  # fails with ORA-01276 "File has an Oracle Managed Files file name" -
  # caught by testing. OMF wants to generate its own fresh unique names,
  # not reuse the source's verbatim under a new path. Let it, instead of
  # forcing FILE_NAME_CONVERT: omit the clause (OMF places files under
  # db_create_file_dest) and skip the explicit tablespace datafile path
  # too, for the same reason.
  # 5M (which worked fine for 19.32) is below 23ai's minimum tablespace
  # datafile size - caught by testing: "ORA-03214: The specified file
  # size is smaller than the minimum blocks 784" (784 blocks at an 8K
  # block size is ~6.1M). 10M clears both versions' minimums comfortably.
  omf_dest="$(db_create_file_dest)"
  if [ -n "${omf_dest}" ]; then
    datafile_clause=""
    tablespace_stmt="CREATE TABLESPACE USERS DATAFILE SIZE 10M AUTOEXTEND ON NEXT 1280K MAXSIZE UNLIMITED;"
  else
    datafile_clause="FILE_NAME_CONVERT = ('${seed_dir}', '${pdb_dir}/')"
    tablespace_stmt="CREATE TABLESPACE USERS DATAFILE '${pdb_dir}/users01.dbf' SIZE 10M REUSE AUTOEXTEND ON NEXT 1280K MAXSIZE UNLIMITED;"
  fi
  sql <<EOF
CREATE PLUGGABLE DATABASE ${name} ADMIN USER PDBADMIN IDENTIFIED BY "${ORACLE_PWD}"
  ${datafile_clause};
ALTER PLUGGABLE DATABASE ${name} OPEN;
ALTER PLUGGABLE DATABASE ${name} SAVE STATE;
ALTER SESSION SET CONTAINER = ${name};
${tablespace_stmt}
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

# Which top-level subdirectory(ies) of oradata/<SID>/ actually hold
# ${PDB_ISO}'s files - queried from Oracle itself rather than assumed to
# be named after the PDB: with Oracle Managed Files active (a 23.26 Gold
# Image's stock seed, see create_pdb_from_seed above), the OMF-generated
# directory name doesn't necessarily match the PDB name the way our own
# FILE_NAME_CONVERT-based (non-OMF) path always does for 19.32. Whatever
# it's actually called, this is what the restore step below must not
# delete.
mapfile -t PDBISO_KEEP_DIRS < <(sqlplus -s / as sysdba <<EOF | tr -d ' \t\r' | grep -v '^$' | sort -u
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT DISTINCT REGEXP_SUBSTR(name, '^${ORACLE_BASE}/oradata/${ORACLE_SID}/([^/]+)', 1, 1, NULL, 1)
FROM v\$datafile WHERE con_id = (SELECT con_id FROM v\$pdbs WHERE name = '${PDB_ISO}')
UNION
SELECT DISTINCT REGEXP_SUBSTR(name, '^${ORACLE_BASE}/oradata/${ORACLE_SID}/([^/]+)', 1, 1, NULL, 1)
FROM v\$tempfile WHERE con_id = (SELECT con_id FROM v\$pdbs WHERE name = '${PDB_ISO}');
EXIT
EOF
)
log "  ${PDB_ISO}'s files live under: ${PDBISO_KEEP_DIRS[*]:-(none under oradata/${ORACLE_SID} - nothing to preserve there)}"

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
KEEP_ARGS=()
for d in "${PDBISO_KEEP_DIRS[@]}"; do
  KEEP_ARGS+=(! -name "${d}")
done
find "${ORACLE_BASE}/oradata/${ORACLE_SID}" -mindepth 1 -maxdepth 1 "${KEEP_ARGS[@]}" -exec rm -rf {} +
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
#    oradata/dbconfig/<SID>/) with 7zzs in solid mode - measured
#    (2026-09-20) at 685M for this content vs. 1.4G via `tar|xz`: LZMA2 in
#    solid mode finds the heavy redundancy between the two customer-PDB
#    variants (each a clone of the same PDB$SEED) that xz's small default
#    dictionary can't reach across. See ../patching/README.md's faststart
#    section, "Compression note", for the measurement and the two
#    alternatives it ruled out (two separate archives; plain xz).
# ---------------------------------------------------------------------------
log "compressing oradata..."
(cd "${ORACLE_BASE}" && 7zzs a -mx=6 -ms=on -mmt=on "${ARCHIVE}" oradata >/dev/null)
log "archive size: $(du -h "${ARCHIVE}" | cut -f1)"

# Raw oradata is now redundant - remove it so only the archive ends up in
# this stage's own layer (the final image COPYs just the archive from here).
rm -rf "${ORACLE_BASE}/oradata"
find "${ORACLE_BASE}/diag" -mindepth 1 -delete 2>/dev/null || true
sed -i "/${ORACLE_SID}/d" /etc/oratab 2>/dev/null || true

log "done: ${ARCHIVE}"
