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
#
# Persistence (2026-09-20): if $ORACLE_BASE/oradata is a mounted volume
# that already has a database in it (checked the same way runOracle.sh
# does, via the CHECKPOINT_FILE_EXTN marker file - not something faststart
# invented), skip decompression AND the variant-selection/rename dance
# below entirely and just start what's already there. Both are not merely
# wasteful to redo, but wrong to redo: after the first start, the kept
# variant PDB has already been renamed to $ORACLE_PDB and the other
# dropped, so PDBISO/PDBUTF8 no longer exist under those names - repeating
# the DROP/RENAME block would fail outright. Without this check, this
# image only ever worked for throwaway "-rm" containers - a persisted
# restart would first silently redo pointless work and then hard-fail.
set -euo pipefail

export ORACLE_SID=${ORACLE_SID:-ORCLCDB}
export ORACLE_SID=${ORACLE_SID^^}
export ORACLE_PDB=${ORACLE_PDB:-ORCLPDB1}
export ORACLE_PDB=${ORACLE_PDB^^}
export ORACLE_CHARACTERSET=${ORACLE_CHARACTERSET:-AL32UTF8}
export ORACLE_CHARACTERSET=${ORACLE_CHARACTERSET^^}

ARCHIVE="${ORACLE_BASE}/faststart-oradata.7z"
CHECKPOINT_FILE="${ORACLE_BASE}/oradata/.${ORACLE_SID}${CHECKPOINT_FILE_EXTN}"
DBCONFIG="${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}"

log() { echo "[$(date -u +%H:%M:%SZ)] faststart: $*"; }

if [ -f "${CHECKPOINT_FILE}" ] && [ -d "${ORACLE_BASE}/oradata/${ORACLE_SID}" ]; then
  log "existing database found under ${ORACLE_BASE}/oradata/${ORACLE_SID} - skipping decompression and variant selection"
else
  # No checkpoint (or a missing oradata/<SID> despite one - a stale/
  # corrupted marker): don't just `7zzs x -y` straight over whatever might
  # already be sitting in oradata/ - `-y` only overwrites files the archive
  # itself contains, silently leaving anything else (partial/incomplete
  # leftovers from a crashed earlier attempt, or unrelated files) behind
  # mixed in with the fresh extraction. runOracle.sh's own "no checkpoint"
  # branch treats an absent checkpoint as license to wipe and recreate
  # unconditionally (`rm -rf "$ORACLE_BASE"/oradata/"$ORACLE_SID"`) rather
  # than overwrite-in-place - matched here for the same reason, covering
  # both directories the archive populates.
  log "no existing database found - clearing ${ORACLE_BASE}/oradata/${ORACLE_SID} and dbconfig before a fresh extraction"
  rm -rf "${ORACLE_BASE}/oradata/${ORACLE_SID}" "${DBCONFIG}" "${CHECKPOINT_FILE}"

  # 7zzs (static, no shared-library deps - see Dockerfile) instead of
  # tar|xz: the archive is a solid 7z archive covering CDB$ROOT+PDB$SEED and
  # both customer-PDB variants together (685M vs. 1.4G for the same content
  # via `tar|xz` - see ../patching/README.md's faststart section,
  # "Compression note"). `-o"${ORACLE_BASE}"` extracts with paths relative
  # to that directory, same as `tar -C "${ORACLE_BASE}" -x` did.
  log "decompressing database..."
  7zzs x "${ARCHIVE}" -o"${ORACLE_BASE}" -y >/dev/null
  log "decompressed"
fi

# Restore symlinks the same way runOracle.sh's symLinkFiles() does - the
# archive carries the config files under oradata/dbconfig/<SID>/ (put there
# by buildFaststart.sh, mirroring moveFiles()). Redone unconditionally even
# on a persisted restart: $ORACLE_HOME itself is never part of the
# persisted volume, only oradata/ is, so a new container always needs these
# recreated, exactly like runOracle.sh's own symLinkFiles() call in its
# "database already exists" branch.
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

if [ -f "${CHECKPOINT_FILE}" ]; then
  log "skipping character-set variant selection (already done on a previous start against this volume)"
else
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

  # createDB.sh's own setupTnsnames() baked a tnsnames.ora PDB entry at
  # BUILD time, under buildFaststart.sh's own hardcoded ORACLE_PDB=ORCLPDB1
  # - not whatever $ORACLE_PDB the kept variant just got renamed to above.
  # That only went unnoticed because ORCLPDB1 is also this script's own
  # runtime default; set ORACLE_PDB to anything else and the alias is
  # simply missing (ORA-12154 for any client connecting via TNS name
  # instead of EZConnect). Rewrite it now that the real name is known -
  # exact same two entries setupTnsnames() itself would produce.
  log "writing tnsnames.ora entry for ${ORACLE_PDB}..."
  cat > "${DBCONFIG}/tnsnames.ora" <<EOF
${ORACLE_SID}=localhost:1521/${ORACLE_SID}
${ORACLE_PDB}=
(DESCRIPTION =
  (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
  (CONNECT_DATA =
    (SERVER = DEDICATED)
    (SERVICE_NAME = ${ORACLE_PDB})
  )
)
EOF

  # Same setup hooks a regular container start's "database just created"
  # branch runs: 20_se2LicenseSettings.sh, 30_se2CtxsysNocompress.sh,
  # savePatchSummary.sh - unmodified, reused as-is, and (like there) only
  # on this first-ever start. savePatchSummary.sh writes the baseline
  # opatch-lspatches record into oradata/dbconfig/<SID>/ that
  # runDatapatch.sh (below, on every start) compares future starts' image
  # against. 10_seedCreatePDB.sh is in the same directory but is a no-op
  # here: by the time it runs, $ORACLE_PDB already exists (just renamed
  # above), so its own "PDB missing -> convert+create" check falls through
  # to its harmless already-done case.
  "${SCRIPT_BASE_DIR}/${USER_SCRIPTS_FILE}" "${ORACLE_BASE}/scripts/extensions/setup"

  # Same custom-provided setup hooks runOracle.sh runs right after its own
  # extensions/setup call, on a freshly created database - this image never
  # ran them at all before (startFaststart.sh only ever knew about its own
  # extensions/ hook directories), so anything mounted into
  # scripts/setup/ (consumer-provided data import, schema setup, ...) was
  # silently skipped. Setup-only, matching runOracle.sh: first start only.
  "${SCRIPT_BASE_DIR}/${USER_SCRIPTS_FILE}" "${ORACLE_BASE}/scripts/setup"

  date -Iseconds > "${CHECKPOINT_FILE}"
  log "checkpoint written - future starts against this volume will skip decompression and variant selection"
fi

# Same intent as runOracle.sh's own "prebuiltdb" password-override path
# (ORACLE_PWD against a database whose password was baked in at build
# time, see buildFaststart.sh) - but NOT via the shared setPassword.sh
# itself. That script re-derives the PDB name from the oradata/<SID>/*/
# directory LISTING, assuming directory name == current PDB name (true for
# the regular image, where dbca creates the PDB already under its final
# name). faststart breaks that assumption on purpose: the directory stays
# named after the build-time variant (PDBISO/PDBUTF8 - see buildFaststart.sh)
# even after RENAME GLOBAL_NAME changes the dictionary's PDB name above, so
# setPassword.sh's own detection picks the stale pre-rename name and fails
# (caught by testing: "ORA-01918: user 'PDBADMIN' does not exist", since
# ALTER SESSION SET CONTAINER=PDBUTF8 switched into the wrong container).
# $ORACLE_PDB is already correct at this point (just renamed, or already
# correct from a prior start) - use it directly instead of re-deriving it.
if [ -n "${ORACLE_PWD:-}" ]; then
  log "applying ORACLE_PWD to SYS/SYSTEM/PDBADMIN..."
  sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER USER SYS IDENTIFIED BY "${ORACLE_PWD}";
ALTER USER SYSTEM IDENTIFIED BY "${ORACLE_PWD}";
ALTER SESSION SET CONTAINER=${ORACLE_PDB};
ALTER USER PDBADMIN IDENTIFIED BY "${ORACLE_PWD}";
EXIT
SQL
fi

# Optional per-container SGA/PGA/processes sizing, same INIT_SGA_SIZE/
# INIT_PGA_SIZE/INIT_PROCESSES env vars createDB.sh honors - but only at
# build time, via dbca's response file (see createDB.sh), which never runs
# per-container here (this image's DB is built once and shipped). Re-
# implemented at every start instead, so a faststart container can still be
# sized without an image rebuild. Only actually touches the spfile (and
# restarts) when a value is given AND differs from what's already set -
# otherwise every single restart would pay for a pointless extra shutdown/
# startup cycle even when nothing changed.
RESIZE_NEEDED=""
if [ -n "${INIT_SGA_SIZE:-}" ] && [ -n "${INIT_PGA_SIZE:-}" ]; then
  CURRENT_SGA_MB=$(sqlplus -s / as sysdba <<'SQL' | tr -d ' \t\r\n'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT ROUND(value/1048576) FROM v$parameter WHERE name = 'sga_target';
SQL
)
  CURRENT_PGA_MB=$(sqlplus -s / as sysdba <<'SQL' | tr -d ' \t\r\n'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT ROUND(value/1048576) FROM v$parameter WHERE name = 'pga_aggregate_target';
SQL
)
  if [ "${CURRENT_SGA_MB}" != "${INIT_SGA_SIZE}" ] || [ "${CURRENT_PGA_MB}" != "${INIT_PGA_SIZE}" ]; then
    log "resizing SGA/PGA: sga_target ${CURRENT_SGA_MB}M -> ${INIT_SGA_SIZE}M, pga_aggregate_target ${CURRENT_PGA_MB}M -> ${INIT_PGA_SIZE}M"
    sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SYSTEM SET sga_target=${INIT_SGA_SIZE}M SCOPE=SPFILE;
ALTER SYSTEM SET pga_aggregate_target=${INIT_PGA_SIZE}M SCOPE=SPFILE;
EXIT
SQL
    RESIZE_NEEDED=1
  fi
fi
if [ -n "${INIT_PROCESSES:-}" ]; then
  CURRENT_PROCESSES=$(sqlplus -s / as sysdba <<'SQL' | tr -d ' \t\r\n'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT value FROM v$parameter WHERE name = 'processes';
SQL
)
  if [ "${CURRENT_PROCESSES}" != "${INIT_PROCESSES}" ]; then
    log "resizing processes: ${CURRENT_PROCESSES} -> ${INIT_PROCESSES}"
    sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SYSTEM SET processes=${INIT_PROCESSES} SCOPE=SPFILE;
EXIT
SQL
    RESIZE_NEEDED=1
  fi
fi
if [ -n "${RESIZE_NEEDED}" ]; then
  log "restarting instance to apply SGA/PGA/processes resize..."
  sqlplus -s / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SHUTDOWN IMMEDIATE;
STARTUP;
SQL
fi

# Same startup hooks a regular container start always runs, including on a
# restart against an existing volume - most importantly
# extensions/patching/runDatapatch.sh (a no-op here if that extension
# wasn't built in, e.g. a 23.26 Gold Image build with patching=false;
# runUserScripts.sh silently skips a missing/empty directory). This is what
# makes "start a newer, differently-patched faststart image against a
# volume created/last patched by an older one" apply datapatch instead of
# silently leaving the dictionary at the old RU: runDatapatch.sh compares
# the current image's `opatch lspatches` against the baseline
# savePatchSummary.sh wrote into the volume above (or, on a later restart,
# whatever runDatapatch.sh itself last wrote there), and runs `datapatch`
# only if they differ. This never needed touching - it only had to
# actually be called, which faststart never did before.
"${SCRIPT_BASE_DIR}/${USER_SCRIPTS_FILE}" "${ORACLE_BASE}/scripts/extensions/startup"

# Same custom-provided startup hooks runOracle.sh always runs after its own
# extensions/startup call, on EVERY start (fresh or restart) - see the
# scripts/setup comment above for why this was missing. Most importantly
# this is where a consumer's own data-import script (mounted into
# scripts/startup/, same convention runOracle.sh itself documents) actually
# gets a chance to run at all.
"${SCRIPT_BASE_DIR}/${USER_SCRIPTS_FILE}" "${ORACLE_BASE}/scripts/startup"

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
