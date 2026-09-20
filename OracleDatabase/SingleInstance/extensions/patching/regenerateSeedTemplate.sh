#!/bin/bash
#
# regenerateSeedTemplate.sh - rebuild the dbca seed template at the patched RU level
#
# WHY
# ---
# The 19c installer ships its dbca seed database (Seed_Database.dfb, referenced
# by General_Purpose.dbc) at the *base* release level, 19.3.0. Patching the
# Oracle Home with a Release Update does not touch that seed. So every
# container that creates a new database first restores a 19.3 dictionary and
# then has to run datapatch to bring it up to the RU level of the binaries -
# on the 19.32 RU + Datapump bundle that is ~30 minutes of datapatch on every
# first start (twice: once WITH ERRORS, once SUCCESS - a known and harmless
# ordering effect between the RU and the DPBP, see README).
#
# This script runs once, at image build time, inside the `seedgen` stage of
# the patching Dockerfile. It creates a throw-away CDB from the stock seed,
# lets dbca run datapatch against it (so CDB$ROOT and PDB$SEED are at the RU
# level), shrinks the oversized undo/temp files that datapatch leaves behind,
# and then uses `dbca -createCloneTemplate` to turn that patched CDB into a
# new seed template. The throw-away CDB is deleted again, the stock seed is
# removed, and dbca.rsp.tmpl is pointed at the new template. Containers
# started from the resulting image restore an already-patched dictionary and
# are ready in ~7-8 minutes instead of 30+, with datapatch reporting
# "nothing to apply".
#
# 26ai Gold Images ship their seed at the RU level already, so none of this
# is needed (or used) for the 23.x builds.
#
# LICENSING NOTE (SE2)
# --------------------
# The clone template is written as an RMAN *compressed* backupset. RMAN's
# BASIC compression algorithm is included in every edition, including
# Standard Edition 2. The LOW/MEDIUM/HIGH algorithms require the Advanced
# Compression Option, which is EE-only and cannot be licensed for SE2 at
# all. dbca uses whatever the database's RMAN configuration says, and the
# default is BASIC - but this script sets it explicitly and prints
# `SHOW COMPRESSION ALGORITHM` into the build log so it is verifiable rather
# than assumed.
#
# CONSEQUENCES HANDLED BY THE SETUP HOOK (10_seedCreatePDB.sh)
# --------------------------------------------------------------
# A clone template made from a CDB carries a <PluggableDatabases> section.
# dbca then refuses to create additional PDBs from numberOfPDBs/pdbName
# ("[DBT-10312] Additional PDBs cannot be created when Container database
# template is specified"), and it does not convert the character set of a
# clone template either. This script therefore sets numberOfPDBs=0 in
# dbca.rsp.tmpl and keeps the template in US7ASCII (like Oracle's own seed);
# the extension's setup hook scripts/extensions/setup/10_seedCreatePDB.sh
# then replays dbca's character-set conversion and creates $ORACLE_PDB from
# PDB$SEED at first container start. Upstream createDB.sh stays untouched
# except for tolerating the missing PDB. Since PDB$SEED is already patched,
# all of that takes seconds.
#
# USAGE
# -----
#   regenerateSeedTemplate.sh <true|false>
#
# Runs as the oracle user with ORACLE_HOME/ORACLE_BASE/PATH from the image
# environment. Anything but "true" makes it a no-op, which leaves the image
# exactly as the patching stage produced it (stock 19.3 seed + datapatch at
# first start).
#

set -euo pipefail

if [ "${1:-true}" != "true" ]; then
  echo "REGENERATE_SEED=${1:-} - keeping the stock dbca seed template (datapatch will run at first container start)."
  exit 0
fi

: "${ORACLE_HOME:?}" "${ORACLE_BASE:?}"

# Throw-away database. Its name is irrelevant for the template (db_name is
# blanked in the .dbc and set by dbca at container start). A distinct SID
# makes the cleanup below unambiguous - everything named *SEEDCDB* goes.
export ORACLE_SID=SEEDCDB
# Throw-away password; only has to satisfy dbca's complexity rules. (Not
# `tr </dev/urandom | head -c N`: head closing the pipe gives tr a SIGPIPE,
# which under `set -o pipefail` aborts the whole script with exit 141.)
SEED_PWD="Seed_$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-12)_1"
DATA_DIR="${ORACLE_BASE}/oradata/${ORACLE_SID}"
TEMPLATE_DIR="${ORACLE_HOME}/assistants/dbca/templates"
RSP_TMPL="${ORACLE_BASE}/scripts/base/dbca.rsp.tmpl"
RSP="/tmp/seedgen_dbca.rsp"
LOG_DIR="/tmp/seedgen"
mkdir -p "${LOG_DIR}"

log() { echo "[$(date -u +%H:%M:%SZ)] seedgen: $*"; }

sql() {  # run a SQL script from stdin as SYSDBA, fail the build on any error
  sqlplus -s / as sysdba <<EOF
WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE
SET FEEDBACK OFF HEADING OFF PAGESIZE 0 LINESIZE 200 VERIFY OFF
$(cat)
EXIT
EOF
}

sql_show() {  # like sql(), but with headings/feedback for build-log readability
  sqlplus -s / as sysdba <<EOF
WHENEVER SQLERROR EXIT FAILURE
SET LINESIZE 200 PAGESIZE 100 FEEDBACK OFF
$(cat)
EXIT
EOF
}

# ---------------------------------------------------------------------------
# 0. Derive the template name from the Release Update actually installed
#    (e.g. "Database Release Update : 19.32.0.0.260721" -> General_Purpose_1932),
#    so the template name in the image always matches the patch level and a
#    stale template can't hide behind a fixed name.
# ---------------------------------------------------------------------------
LSPATCHES=$("${ORACLE_HOME}/OPatch/opatch" lspatches)
RU_LINE=$(grep -m1 'Database Release Update' <<<"${LSPATCHES}" || true)
if [ -z "${RU_LINE}" ]; then
  echo "ERROR: no 'Database Release Update' in opatch lspatches - is this really a patched home?" >&2
  exit 1
fi
RU_VERSION=$(sed -E 's/.*Release Update : ([0-9]+\.[0-9]+)\..*/\1/' <<<"${RU_LINE}")   # 19.32
TEMPLATE_NAME="General_Purpose_${RU_VERSION//./}"                                        # General_Purpose_1932
log "installed RU: ${RU_LINE}"
log "new seed template: ${TEMPLATE_NAME}"

if [ -e "${TEMPLATE_DIR}/${TEMPLATE_NAME}.dbc" ]; then
  echo "ERROR: ${TEMPLATE_DIR}/${TEMPLATE_NAME}.dbc already exists - refusing to overwrite." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Minimal listener/sqlnet config - dbca insists on a running listener.
#    Removed again in the cleanup; createDB.sh writes the real ones at runtime.
# ---------------------------------------------------------------------------
mkdir -p "${ORACLE_HOME}/network/admin"
cat > "${ORACLE_HOME}/network/admin/sqlnet.ora" <<EOF
NAMES.DIRECTORY_PATH= (TNSNAMES, EZCONNECT, HOSTNAME)
EOF
cat > "${ORACLE_HOME}/network/admin/listener.ora" <<EOF
LISTENER =
(DESCRIPTION_LIST =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1))
    (ADDRESS = (PROTOCOL = TCP)(HOST = 127.0.0.1)(PORT = 1521))
  )
)
DEDICATED_THROUGH_BROKER_LISTENER=ON
DIAG_ADR_ENABLED = off
EOF
lsnrctl start > "${LOG_DIR}/listener.log" 2>&1
log "listener started"

# ---------------------------------------------------------------------------
# 2. Create the throw-away CDB from the *stock* seed: CDB$ROOT + PDB$SEED,
#    no user PDB (the template must not carry one), no EM Express.
#    Same response file the container uses at runtime (init parameters), but
#    with characterSet=US7ASCII - deliberately. Oracle's own seed is US7ASCII
#    (see the alert log of any dbca run: "Database Characterset is US7ASCII"),
#    and dbca then converts it to the requested character set with
#    "ALTER DATABASE CHARACTER SET INTERNAL_CONVERT <cs>" in CDB$ROOT and
#    PDB$SEED - the legitimate subset->superset direction, because US7ASCII is
#    a strict subset of every character set. dbca does NOT do that for clone
#    templates (it only warns DBT-11153 and keeps the template's charset,
#    tested), so the setup hook 10_seedCreatePDB.sh replays exactly dbca's
#    sequence at first container start. Keeping the template in US7ASCII is
#    what keeps ORACLE_CHARACTERSET freely selectable (ASSET: WE8ISO8859P15,
#    cargo/longhaultraffic: AL32UTF8). Byte-wise the dictionary is pure ASCII,
#    so the template is the same size either way.
# ---------------------------------------------------------------------------
umask 177
cp "${RSP_TMPL}" "${RSP}"
sed -i -e "s|###ORACLE_SID###|${ORACLE_SID}|g" \
       -e "s|###ORACLE_PWD###|${SEED_PWD}|g" \
       -e "s|###ORACLE_CHARACTERSET###|US7ASCII|g" \
       -e "s|^numberOfPDBs=.*|numberOfPDBs=0|" \
       -e "/^pdbName=/d" -e "/^pdbAdminPassword=/d" \
       -e "s|^emConfiguration=.*|emConfiguration=NONE|" \
       -e "/^emExpressPort=/d" \
       "${RSP}"
umask 022
log "effective dbca response (passwords omitted):"
grep -v -e '^#' -e '^$' "${RSP}" | grep -iv 'password' | sed 's/^/    /'

log "creating throw-away CDB ${ORACLE_SID} from the stock seed (this includes the ~30 min datapatch run)..."
if ! dbca -silent -createDatabase -enableArchive false -responseFile "${RSP}" > "${LOG_DIR}/dbca_create.log" 2>&1; then
  echo "ERROR: dbca -createDatabase failed:" >&2
  cat "${LOG_DIR}/dbca_create.log" >&2
  cat "${ORACLE_BASE}/cfgtoollogs/dbca/${ORACLE_SID}/${ORACLE_SID}.log" 2>/dev/null >&2 || true
  exit 1
fi
tail -3 "${LOG_DIR}/dbca_create.log" | sed 's/^/    /'
log "throw-away CDB created"

# ---------------------------------------------------------------------------
# 3. Verify the dictionary really is at the RU level in both containers that
#    end up in the template. Anything short of SUCCESS for every patch in
#    CDB$ROOT and PDB$SEED fails the build - shipping a half-patched seed
#    would be worse than shipping the stock one.
# ---------------------------------------------------------------------------
# NOTE: CDB_REGISTRY_SQLPATCH (like all CDB_* views) does NOT show PDB$SEED,
# so each container is checked from inside via DBA_REGISTRY_SQLPATCH.
# The latest status per patch must be SUCCESS; older WITH ERRORS rows from
# the first datapatch pass are expected and fine. sqlplus pads numbers with
# whitespace/tabs, hence the tr.
for CONTAINER in 'CDB$ROOT' 'PDB$SEED'; do
  log "patch state after datapatch in ${CONTAINER}:"
  sql_show <<EOF
ALTER SESSION SET CONTAINER = ${CONTAINER};
COL status FOR a12
COL description FOR a60 TRUNC
SELECT patch_id, status, TO_CHAR(action_time, 'HH24:MI:SS') applied, description
  FROM dba_registry_sqlpatch ORDER BY action_time;
EOF
  BAD=$(sql <<EOF | tr -d '[:space:]'
ALTER SESSION SET CONTAINER = ${CONTAINER};
SELECT COUNT(*)
  FROM (SELECT patch_id, status,
               ROW_NUMBER() OVER (PARTITION BY patch_id ORDER BY action_time DESC) rn
          FROM dba_registry_sqlpatch)
 WHERE rn = 1 AND status <> 'SUCCESS';
EOF
)
  TOTAL=$(sql <<EOF | tr -d '[:space:]'
ALTER SESSION SET CONTAINER = ${CONTAINER};
SELECT COUNT(DISTINCT patch_id) FROM dba_registry_sqlpatch;
EOF
)
  INVALID=$(sql <<EOF | tr -d '[:space:]'
ALTER SESSION SET CONTAINER = ${CONTAINER};
SELECT COUNT(*) FROM dba_objects WHERE status = 'INVALID';
EOF
)
  log "${CONTAINER}: ${TOTAL} patch(es) registered, ${BAD} not SUCCESS, ${INVALID} invalid object(s)"
  if [ "${BAD}" != "0" ] || [ "${TOTAL}" = "0" ]; then
    echo "ERROR: ${CONTAINER} has ${TOTAL} patches registered and ${BAD} not in SUCCESS state - refusing to build a seed from this." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 3b. Trim what ZEDAS databases never use, mirroring the Ansible role's dbca
#     template (CWMLITE=false) and Oracle's own guidance for SE2:
#     - OLAP (Analytic Workspaces APS + OLAP API XOQ): "OPTION OFF" in SE2
#       anyway and not licensable there, but ~50 MB of dictionary objects
#       that every RU re-patches. Removed with Oracle's own deinstall
#       scripts, one container at a time (running both at once trips
#       ORA-65023 in PDB$SEED - same as gvenzl/oci-oracle-free does it).
#     - optimizer statistics history from the datapatch runs (~25 MB).
#     PDB$SEED has to be opened read/write for this and is put back to
#     read only afterwards.
# ---------------------------------------------------------------------------
log "removing OLAP (APS/XOQ) from CDB\$ROOT and PDB\$SEED..."
sql <<'EOF'
ALTER SESSION SET "_oracle_script" = TRUE;
ALTER PLUGGABLE DATABASE PDB$SEED CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE PDB$SEED OPEN READ WRITE;
EOF
catcon() {  # $1 = container, $2 = script dir, $3 = script, $4 = log prefix
  "${ORACLE_HOME}/perl/bin/perl" "${ORACLE_HOME}/rdbms/admin/catcon.pl" -n 1 -c "$1" \
      -l "${LOG_DIR}" -b "seedgen_$4" -d "$2" "$3" > "${LOG_DIR}/catcon_$4.out" 2>&1 \
    || { echo "ERROR: catcon $3 in $1 failed:" >&2; cat "${LOG_DIR}/catcon_$4.out" >&2; exit 1; }
}
for CONTAINER in 'PDB$SEED' 'CDB$ROOT'; do
  tag=$([ "${CONTAINER}" = 'PDB$SEED' ] && echo seed || echo root)
  catcon "${CONTAINER}" "${ORACLE_HOME}/olap/admin" catnoxoq.sql "xoq_${tag}"
  catcon "${CONTAINER}" "${ORACLE_HOME}/olap/admin" catnoaps.sql "aps_${tag}"
done
log "recompiling..."
catcon 'CDB$ROOT'  "${ORACLE_HOME}/rdbms/admin" utlrp.sql "utlrp_root"
catcon 'PDB$SEED'  "${ORACLE_HOME}/rdbms/admin" utlrp.sql "utlrp_seed"

log "purging optimizer statistics history..."
sql <<'EOF'
BEGIN DBMS_STATS.PURGE_STATS(DBMS_STATS.PURGE_ALL); END;
/
ALTER SESSION SET CONTAINER = PDB$SEED;
BEGIN DBMS_STATS.PURGE_STATS(DBMS_STATS.PURGE_ALL); END;
/
EOF
sql <<'EOF'
ALTER SESSION SET "_oracle_script" = TRUE;
ALTER PLUGGABLE DATABASE PDB$SEED CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE PDB$SEED OPEN READ ONLY;
EOF

for CONTAINER in 'CDB$ROOT' 'PDB$SEED'; do
  OLAP_LEFT=$(sql <<EOF | tr -d '[:space:]'
ALTER SESSION SET CONTAINER = ${CONTAINER};
SELECT COUNT(*) FROM dba_registry WHERE comp_id IN ('APS','XOQ') AND status NOT IN ('REMOVED');
EOF
)
  INVALID=$(sql <<EOF | tr -d '[:space:]'
ALTER SESSION SET CONTAINER = ${CONTAINER};
SELECT COUNT(*) FROM dba_objects WHERE status = 'INVALID';
EOF
)
  log "${CONTAINER} after OLAP removal: APS/XOQ not REMOVED=${OLAP_LEFT}, invalid objects=${INVALID}"
  if [ "${OLAP_LEFT}" != "0" ] || [ "${INVALID}" != "0" ]; then
    echo "ERROR: OLAP removal left ${CONTAINER} in a bad state - refusing to build a seed from this." >&2
    sql_show <<EOF
ALTER SESSION SET CONTAINER = ${CONTAINER};
SELECT comp_id, status FROM dba_registry WHERE comp_id IN ('APS','XOQ');
SELECT owner, object_name, object_type FROM dba_objects WHERE status = 'INVALID' FETCH FIRST 30 ROWS ONLY;
EOF
    exit 1
  fi
done

log "component versions (CDB\$ROOT):"
sql_show <<'EOF'
COL comp_id FOR a10
COL version_full FOR a14
COL status FOR a10
SELECT comp_id, version_full, status FROM dba_registry
 WHERE comp_id IN ('CATALOG','CATPROC','JAVAVM','SDO','XDB','CONTEXT','APS','XOQ') ORDER BY 1;
EOF

# ---------------------------------------------------------------------------
# 4. Shrink what datapatch bloated. Undo grows to >1 GB during datapatch and
#    a datafile can't be shrunk below its high-water mark, so swap the undo
#    tablespace out and back in instead. Everything here ends up in the
#    template, so every MB saved is saved in the image and in every restore.
# ---------------------------------------------------------------------------
log "shrinking undo/temp in CDB\$ROOT..."
drop_undo_when_free() {  # undo segments go offline asynchronously - retry
  local ts=$1 i out
  for i in $(seq 1 60); do
    out=$(sqlplus -s / as sysdba <<EOF
SET FEEDBACK ON
DROP TABLESPACE ${ts} INCLUDING CONTENTS AND DATAFILES;
EXIT
EOF
)
    if ! grep -q 'ORA-' <<<"${out}"; then log "  ${ts} dropped (attempt ${i})"; return 0; fi
    # ORA-30013: undo tablespace currently in use / ORA-01548: active rollback segment
    grep -qE 'ORA-30013|ORA-01548' <<<"${out}" || { echo "${out}" >&2; return 1; }
    sleep 10
  done
  echo "ERROR: timed out waiting to drop ${ts}" >&2; return 1
}
sql <<EOF
ALTER SYSTEM SET undo_retention = 1 SCOPE=MEMORY;
CREATE UNDO TABLESPACE UNDOTBS2 DATAFILE '${DATA_DIR}/undotbs02.dbf' SIZE 25M AUTOEXTEND ON NEXT 5M MAXSIZE UNLIMITED;
ALTER SYSTEM SET undo_tablespace = UNDOTBS2 SCOPE=BOTH;
EOF
drop_undo_when_free UNDOTBS1
sql <<EOF
CREATE UNDO TABLESPACE UNDOTBS1 DATAFILE '${DATA_DIR}/undotbs01.dbf' SIZE 25M AUTOEXTEND ON NEXT 5M MAXSIZE UNLIMITED;
ALTER SYSTEM SET undo_tablespace = UNDOTBS1 SCOPE=BOTH;
EOF
drop_undo_when_free UNDOTBS2
sql <<EOF
ALTER SYSTEM RESET undo_retention SCOPE=MEMORY;
EOF
# TEMP can simply be resized (fails harmlessly if something still holds space)
sqlplus -s / as sysdba <<EOF | grep -E 'ORA-|altered' || true
ALTER DATABASE TEMPFILE '${DATA_DIR}/temp01.dbf' RESIZE 20M;
EXIT
EOF

log "datafile sizes going into the template (MB):"
sql_show <<'EOF'
COL container FOR a10
COL tablespace_name FOR a12
SELECT DECODE(con_id, 1, 'CDB$ROOT', 2, 'PDB$SEED') container, tablespace_name, ROUND(SUM(bytes)/1048576) mb
  FROM cdb_data_files GROUP BY con_id, tablespace_name
UNION ALL
SELECT DECODE(con_id, 1, 'CDB$ROOT', 2, 'PDB$SEED'), tablespace_name || ' (tmp)', ROUND(SUM(bytes)/1048576)
  FROM cdb_temp_files GROUP BY con_id, tablespace_name
ORDER BY 1, 2;
EOF

# ---------------------------------------------------------------------------
# 5. Pin RMAN backup compression to BASIC (the algorithm included in SE2)
#    and print it, then create the clone template.
# ---------------------------------------------------------------------------
log "RMAN compression algorithm (must be BASIC for SE2 licensing):"
RMAN_OUT=$(rman target / <<'EOF'
CONFIGURE COMPRESSION ALGORITHM 'BASIC';
SHOW COMPRESSION ALGORITHM;
EXIT
EOF
)
grep -E 'CONFIGURE COMPRESSION|RMAN-|ORA-' <<<"${RMAN_OUT}" | sed 's/^/    /' || true
# SHOW prints the effective setting as a CONFIGURE statement; anything other
# than BASIC (LOW/MEDIUM/HIGH need the EE-only Advanced Compression Option)
# fails the build.
if ! grep -q "^CONFIGURE COMPRESSION ALGORITHM 'BASIC'" <<<"${RMAN_OUT}"; then
  echo "ERROR: RMAN compression algorithm is not BASIC - refusing to create a template that would need Advanced Compression licensing." >&2
  exit 1
fi

log "creating clone template ${TEMPLATE_NAME} (RMAN compressed backup of CDB\$ROOT + PDB\$SEED)..."
if ! dbca -silent -createCloneTemplate \
      -sourceDB "${ORACLE_SID}" \
      -sysDBAUserName sys -sysDBAPassword "${SEED_PWD}" \
      -templateName "${TEMPLATE_NAME}" \
      -compressBackup true \
      -rmanParallelism 4 \
      -maintainFileLocations false > "${LOG_DIR}/dbca_template.log" 2>&1; then
  echo "ERROR: dbca -createCloneTemplate failed:" >&2
  cat "${LOG_DIR}/dbca_template.log" >&2
  exit 1
fi
tail -2 "${LOG_DIR}/dbca_template.log" | sed 's/^/    /'
log "template files:"
ls -l "${TEMPLATE_DIR}/${TEMPLATE_NAME}".* | awk '{printf "    %8.1f MB  %s\n", $5/1048576, $9}'
du -shc "${TEMPLATE_DIR}/${TEMPLATE_NAME}".* | tail -1 | sed 's/^/    total: /'

# ---------------------------------------------------------------------------
# 6. Throw the temporary CDB away and remove every trace of it, so the only
#    things this stage adds to $ORACLE_BASE are the template files and the
#    two edits below. (The final image stage COPYs $ORACLE_BASE from this
#    stage, so anything left here would be shipped.)
# ---------------------------------------------------------------------------
log "deleting throw-away CDB..."
dbca -silent -deleteDatabase -sourceDB "${ORACLE_SID}" \
     -sysDBAUserName sys -sysDBAPassword "${SEED_PWD}" > "${LOG_DIR}/dbca_delete.log" 2>&1 \
  || { cat "${LOG_DIR}/dbca_delete.log" >&2; exit 1; }
lsnrctl stop > /dev/null 2>&1 || true

rm -rf "${DATA_DIR}" \
       "${ORACLE_BASE}/oradata/dbconfig" \
       "${ORACLE_BASE}/admin" \
       "${ORACLE_BASE}/audit" \
       "${ORACLE_BASE}/diag/rdbms" "${ORACLE_BASE}/diag/tnslsnr" "${ORACLE_BASE}/diag/clients" \
       "${ORACLE_BASE}/cfgtoollogs/dbca" "${ORACLE_BASE}/cfgtoollogs/sqlpatch" \
       "${ORACLE_BASE}/checkpoints"/* \
       "${ORACLE_HOME}/network/admin/listener.ora" "${ORACLE_HOME}/network/admin/sqlnet.ora" "${ORACLE_HOME}/network/admin/tnsnames.ora" \
       "${ORACLE_HOME}/log/diag/rdbms" \
       "${RSP}" "${LOG_DIR}" /tmp/CVU_* /tmp/OraInstall* 2>/dev/null || true
# -iname: the instance writes lowercase seedcdb_ora_*.trc into rdbms/log
find "${ORACLE_HOME}/dbs" "${ORACLE_HOME}/rdbms/log" "${ORACLE_HOME}/rdbms/audit" -iname "*${ORACLE_SID}*" -delete 2>/dev/null || true
# Deliberately kept: $ORACLE_HOME/sqlpatch/<patch>/<uid>/<patch>.zip (~250 MB
# for the RU). datapatch creates it on its first run against any database
# (it stores the patch's SQL files in the dictionary from that zip) - with
# the stock seed every container creates it at first start in its own
# writable layer; here it's created once and shipped in the image instead.
sed -i "/^${ORACLE_SID}:/d" /etc/oratab 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Switch the runtime response file to the new template and drop the stock
#    19.3 seed. numberOfPDBs=0 because dbca can't create PDBs from a CDB
#    clone template (DBT-10312) - createDB.sh creates $ORACLE_PDB from
#    PDB$SEED instead.
# ---------------------------------------------------------------------------
sed -i -e "s|^templateName=.*|templateName=${TEMPLATE_NAME}.dbc|" \
       -e "s|^numberOfPDBs=.*|numberOfPDBs=0|" \
       -e "/^pdbName=/d" -e "/^pdbAdminPassword=/d" \
       "${RSP_TMPL}"
rm -f "${TEMPLATE_DIR}/General_Purpose.dbc" "${TEMPLATE_DIR}/Data_Warehouse.dbc" \
      "${TEMPLATE_DIR}/Seed_Database.dfb" "${TEMPLATE_DIR}/Seed_Database.ctl" \
      "${TEMPLATE_DIR}/pdbseed.dfb" "${TEMPLATE_DIR}/pdbseed.xml"

# dbca compares a <characterSet> declared in the .dbc with the requested one
# and warns DBT-11153 ("may cause data truncation") at every container start.
# The stock General_Purpose.dbc declares none; drop it here too - the hook
# converts from US7ASCII afterwards anyway.
sed -i '/<characterSet>/d' "${TEMPLATE_DIR}/${TEMPLATE_NAME}.dbc"

# Record what was done, next to the template, for anyone inspecting the image.
cat > "${TEMPLATE_DIR}/${TEMPLATE_NAME}.README" <<EOF
${TEMPLATE_NAME}: dbca clone template regenerated at image build time
($(date -u +%Y-%m-%dT%H:%M:%SZ)) from a CDB patched with:
$(sed 's/^/  /' <<<"${LSPATCHES}")
Contains CDB\$ROOT and PDB\$SEED (no user PDB), RMAN BASIC-compressed, character
set US7ASCII like Oracle's own seed - converted to ORACLE_CHARACTERSET at first
container start by scripts/extensions/setup/10_seedCreatePDB.sh (dbca's sequence).
Replaces the stock 19.3.0 Seed_Database.dfb/General_Purpose.dbc, which were
removed from this image. See extensions/patching/README.md in the repo.
EOF

log "done. dbca.rsp.tmpl now uses:"
grep -E '^(templateName|numberOfPDBs)=' "${RSP_TMPL}" | sed 's/^/    /'
log "templates dir:"
ls -l "${TEMPLATE_DIR}" | awk 'NR>1 {printf "    %8.1f MB  %s\n", $5/1048576, $9}'
