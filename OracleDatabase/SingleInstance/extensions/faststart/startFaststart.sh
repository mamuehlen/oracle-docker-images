#!/bin/bash
# startFaststart.sh - container entrypoint for the faststart image.
#
# Replaces dbca -createDatabase (RMAN restore + "Completing Database
# Creation", ~8-9 min) with: decompress an already-created CDB$ROOT+
# PDB$SEED - which already contains BOTH character-set variants of the
# customer PDB, fully created and converted at build time (see
# buildFaststart.sh) - plain `startup`, then pick the requested variant.
#
# Measured (2026-09-20): deferring character-set conversion to container
# start (as an earlier version of this script did, reusing
# 10_seedCreatePDB.sh's runtime INTERNAL_CONVERT unchanged) cost ~5:40 min
# by itself - INTERNAL_CONVERT has to scan the whole ~1.9GB CDB$ROOT+
# PDB$SEED dictionary, even for pure-ASCII content needing no byte
# remapping. Since only two character sets are ever needed
# (AL32UTF8/WE8ISO8859P15), both are pre-converted once at build time
# instead; here we just DROP the unwanted variant PDB and RENAME the kept
# one to $ORACLE_PDB - both cheap, mostly-metadata operations.
#
# ORACLE_SID is fixed (baked in at build time, see README). ORACLE_PDB
# stays runtime-configurable. ORACLE_CHARACTERSET is runtime-configurable
# but limited to AL32UTF8 (default) or WE8ISO8859P15 - the only two
# variants this image ships; anything else needs the regular (non-
# faststart) image.
set -euo pipefail

export ORACLE_SID=${ORACLE_SID:-ORCLCDB}
export ORACLE_SID=${ORACLE_SID^^}
export ORACLE_PDB=${ORACLE_PDB:-ORCLPDB1}
export ORACLE_PDB=${ORACLE_PDB^^}
export ORACLE_CHARACTERSET=${ORACLE_CHARACTERSET:-AL32UTF8}
export ORACLE_CHARACTERSET=${ORACLE_CHARACTERSET^^}

ARCHIVE="${ORACLE_BASE}/faststart-oradata.tar.xz"

log() { echo "[$(date -u +%H:%M:%SZ)] faststart: $*"; }

# `tar -xJf` shells out to plain `xz -d`, single-threaded regardless of how
# the archive was compressed. The archive was built with `xz -T0` (multiple
# independent blocks), so decoding CAN be parallelized too, and explicitly
# piping through `xz -T0 -dc | tar -x` costs nothing to try - but measured
# (2026-09-20) end-to-end in a real container, it made no measurable
# difference (~54s either way): an isolated host-side benchmark had
# suggested a large win, but that benchmark wrote its output to a tmpfs
# (RAM-backed /tmp), not real disk - not representative of this step's
# actual bottleneck. Left in since it's free and doesn't regress anything,
# but don't expect it to matter; see README's faststart section for the
# still-open question of what the real bottleneck is here.
log "decompressing database..."
xz -T0 -dc "${ARCHIVE}" | tar -C "${ORACLE_BASE}" -x
log "decompressed"

# Restore symlinks the same way runOracle.sh's symLinkFiles() does - the
# archive carries the config files under oradata/dbconfig/<SID>/ (put there
# by buildFaststart.sh, mirroring moveFiles()).
DBCONFIG="${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}"
ln -sf "${DBCONFIG}/spfile${ORACLE_SID}.ora" "${ORACLE_HOME}/dbs/spfile${ORACLE_SID}.ora"
ln -sf "${DBCONFIG}/orapw${ORACLE_SID}"      "${ORACLE_HOME}/dbs/orapw${ORACLE_SID}"
ln -sf "${DBCONFIG}/sqlnet.ora"              "${ORACLE_HOME}/network/admin/sqlnet.ora"
ln -sf "${DBCONFIG}/listener.ora"            "${ORACLE_HOME}/network/admin/listener.ora"
ln -sf "${DBCONFIG}/tnsnames.ora"            "${ORACLE_HOME}/network/admin/tnsnames.ora"
cp "${DBCONFIG}/oratab" /etc/oratab 2>/dev/null || true

# audit_file_dest ({ORACLE_BASE}/admin/{DB_UNIQUE_NAME}/adump per
# dbca.rsp.tmpl) is outside oradata/, so it isn't in the archive - dbca
# creates it once, normally, but this image never runs dbca. Recreate it
# fresh; nothing needs to persist in it across a restart.
mkdir -p "${ORACLE_BASE}/admin/${ORACLE_SID}/adump"

log "starting listener..."
lsnrctl start

log "starting instance..."
sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
STARTUP;
EXIT
SQL
log "instance started"

log "selecting character-set variant (${ORACLE_CHARACTERSET})..."
case "${ORACLE_CHARACTERSET}" in
  AL32UTF8)       KEEP_PDB=PDBUTF8; DROP_PDB=PDBISO ;;
  WE8ISO8859P15)  KEEP_PDB=PDBISO;  DROP_PDB=PDBUTF8 ;;
  *)
    echo "ERROR: this faststart image only supports ORACLE_CHARACTERSET=AL32UTF8 or WE8ISO8859P15 (got ${ORACLE_CHARACTERSET}); use the regular (non-faststart) image for other character sets."
    exit 1
    ;;
esac
# Both variant PDBs auto-open via their build-time SAVE STATE. Drop the
# unwanted one (a real, separately-cloned PDB, not shareable storage - this
# does need its own CLOSE first, DROP can't touch an open PDB) and rename
# the kept one to $ORACLE_PDB - a lightweight, mostly-metadata operation
# (ALTER PLUGGABLE DATABASE ... RENAME GLOBAL_NAME), not a data copy. That
# rename itself requires the PDB to be open in RESTRICTED mode first -
# a plain OPEN isn't enough (caught by testing: fails with ORA-65045
# "pluggable database not in a restricted mode").
sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK ON
ALTER SESSION SET "_oracle_script" = TRUE;
ALTER PLUGGABLE DATABASE ${DROP_PDB} CLOSE IMMEDIATE;
DROP PLUGGABLE DATABASE ${DROP_PDB} INCLUDING DATAFILES;
ALTER PLUGGABLE DATABASE ${KEEP_PDB} CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE ${KEEP_PDB} OPEN RESTRICTED;
ALTER PLUGGABLE DATABASE ${KEEP_PDB} RENAME GLOBAL_NAME TO ${ORACLE_PDB};
ALTER PLUGGABLE DATABASE ${ORACLE_PDB} CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE ${ORACLE_PDB} OPEN;
ALTER PLUGGABLE DATABASE ${ORACLE_PDB} SAVE STATE;
ALTER SYSTEM REGISTER;
EXIT
SQL
log "variant selected: kept ${KEEP_PDB} as ${ORACLE_PDB}, dropped ${DROP_PDB}"

# Same remaining hooks a regular container start runs: 20_se2LicenseSettings.sh,
# 30_se2CtxsysNocompress.sh, savePatchSummary.sh - unmodified, reused as-is.
# 10_seedCreatePDB.sh is in the same directory but is a no-op here: by the
# time it runs, $ORACLE_PDB already exists (just renamed above), so its own
# "PDB missing -> convert+create" check falls through to its harmless
# already-done case.
"${SCRIPT_BASE_DIR}/${USER_SCRIPTS_FILE}" "${ORACLE_BASE}/scripts/extensions/setup"

if "${SCRIPT_BASE_DIR}/${CHECK_DB_FILE}"; then
  echo "#########################"
  echo "DATABASE IS READY TO USE!"
  echo "#########################"
else
  echo "#####################################"
  echo "########### E R R O R ###############"
  echo "DATABASE SETUP WAS NOT SUCCESSFUL!"
  echo "#####################################"
fi

echo "The following output is now a tail of the alert.log:"
tail -f "${ORACLE_BASE}"/diag/rdbms/*/*/trace/alert*.log &
childPID=$!
wait "${childPID}"
