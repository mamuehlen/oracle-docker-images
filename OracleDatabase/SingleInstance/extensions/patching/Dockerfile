# LICENSE UPL 1.0
#
# Copyright (c) 1982-2023 Oracle and/or its affiliates. All rights reserved.
#
# ORACLE DOCKERFILES PROJECT
# --------------------------
# This is the Dockerfile for Oracle Database with patching support
#
# REQUIREMETNS FOR THIS IMAGE
# ----------------------------------
#
#
# HOW TO BUILD THIS IMAGE
# -----------------------
#
# Run:
#      $ docker build -t <extended_image_name> . --build-arg BASE_IMAGE=oracle/database:18.3.0-ee
#
# Pull base image
# ---------------
ARG BASE_IMAGE=oracle/database:19.3.0-ee
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} as patching

# Environment variables required for this build (do NOT change)
# -------------------------------------------------------------
ENV HOST_PATCH_DIR="patches" \
    PATCH_DIR=/opt/install/patches \
    PATCH_DB_BINARIES_FILE="patchDBBinaries.sh"

# Copy DB patches
COPY --chown=oracle:dba $HOST_PATCH_DIR $PATCH_DB_BINARIES_FILE $PATCH_DIR/

# Apply DB Patch
RUN chmod ug+x $PATCH_DIR/*.sh && \
    sync && \
    $PATCH_DIR/$PATCH_DB_BINARIES_FILE && \
    rm -rf $PATCH_DIR/* $ORACLE_HOME/.patch_storage $ORACLE_HOME/.opatchauto_storage

# Post-patching slim-down: the base image had to be built with SLIMMING=false
# (patching/opatchauto needs these present), but once patching is done they're
# no longer needed. This removes the same components installDBBinaries.sh would
# have removed under SLIMMING=true (~600MB): APEX, ORDS, UCP, installer zips in
# lib/, OUI inventory backup, network tools help, DBUA, DMU, install/pilot,
# suptools. Done here (in this stage, before the final stage's COPY --from)
# rather than after, so the deleted bytes never end up in a lower layer of the
# final image in the first place - deleting them in a later layer doesn't
# actually shrink the image, it just hides them behind the delete.
RUN rm -rf "$ORACLE_HOME"/apex \
           "$ORACLE_HOME"/ords \
           "$ORACLE_HOME"/sqldeveloper \
           "$ORACLE_HOME"/ucp \
           "$ORACLE_HOME"/lib/*.zip \
           "$ORACLE_HOME"/inventory/backup/* \
           "$ORACLE_HOME"/network/tools/help \
           "$ORACLE_HOME"/assistants/dbua \
           "$ORACLE_HOME"/dmu \
           "$ORACLE_HOME"/install/pilot \
           "$ORACLE_HOME"/suptools


## Seed regeneration stage: rebuild the dbca seed template at the RU level
## just patched into the binaries above, so containers don't spend ~30 min in
## datapatch on every first start. See regenerateSeedTemplate.sh for the full
## rationale, the SE2 licensing note (RMAN BASIC compression) and the
## DBT-10312 consequence handled in createDB.sh. Adds ~45 min to the build.
## REGENERATE_SEED=false turns this into a no-op (stock seed, datapatch at
## first start). Like the slim-down above, all the temporary database's
## files are created *and* deleted inside this stage, so only the template
## itself reaches the final image via COPY --from below.
FROM patching as seedgen
ARG REGENERATE_SEED=true
ENV REGENERATE_SEED_FILE="regenerateSeedTemplate.sh"
COPY --chown=oracle:dba $REGENERATE_SEED_FILE $ORACLE_BASE/
RUN chmod ug+x "$ORACLE_BASE/$REGENERATE_SEED_FILE" && \
    "$ORACLE_BASE/$REGENERATE_SEED_FILE" "$REGENERATE_SEED" && \
    rm -f "$ORACLE_BASE/$REGENERATE_SEED_FILE"


## New stage for minimal layer size
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}-base
ENV DATAPATCH_FILE="runDatapatch.sh" \
    LSPATCHES_FILE="savePatchSummary.sh" \
    SKIP_DATAPATCH=false \
    STARTUP_FILE=startUp.sh \
    SHUT_DB_FILE=shutDown.sh \
    LOCKING_SCRIPT=lock.py \
    SWAP_LOCK_FILE=swapLocks.sh \
    CHECK_DB_LOCK_FILE=checkDBLockStatus.sh

USER oracle
WORKDIR /home/oracle

# Copying patched oracle_base from the seedgen stage (patched, slimmed down,
# and - unless REGENERATE_SEED=false - with the regenerated seed template)
COPY --from=seedgen $ORACLE_BASE $ORACLE_BASE

# Extension setup hooks, run once after database creation by runOracle.sh via
# runUserScripts.sh "$ORACLE_BASE/scripts/extensions/setup" (alphabetical order,
# hence the numeric prefixes). Deliberately NOT /opt/oracle/scripts/setup: that
# is the user hook, and a user volume mounted there would hide our scripts.
#   10_seedCreatePDB.sh       - with the regenerated seed (US7ASCII, see
#                               regenerateSeedTemplate.sh): converts the
#                               character set to $ORACLE_CHARACTERSET (dbca's
#                               own INTERNAL_CONVERT sequence, replayed - dbca
#                               itself only warns DBT-11153 for a CDB clone
#                               template) and creates $ORACLE_PDB from
#                               PDB$SEED (dbca can't, DBT-10312). No-op with
#                               the stock seed.
#   20_se2LicenseSettings.sh  - CONTROL_MANAGEMENT_PACK_ACCESS=NONE, HEAT_MAP=OFF,
#                               SQL Tuning Advisor auto task off (EE-only packs).
#   30_se2CtxsysNocompress.sh - Oracle Text default storage NOCOMPRESS (Advanced
#                               Index Compression isn't licensed in SE2). A .sh,
#                               not .sql: needs ALTER SESSION SET CONTAINER to
#                               $ORACLE_PDB first - a plain "sqlplus / as sysdba"
#                               (all runUserScripts.sh .sql files get exactly
#                               that) always lands in CDB$ROOT, where the
#                               setting is a no-op (found 2026-09-20: this had
#                               silently never applied to the PDB since this
#                               extension's very first commit).
#   savePatchSummary.sh       - upstream: records opatch lspatches for runDatapatch.sh
COPY --chown=oracle:dba seedCreatePDB.sh    $ORACLE_BASE/scripts/extensions/setup/10_seedCreatePDB.sh
COPY --chown=oracle:dba se2LicenseSettings.sh $ORACLE_BASE/scripts/extensions/setup/20_se2LicenseSettings.sh
COPY --chown=oracle:dba --chmod=750 se2_ctxsys_nocompress.sh $ORACLE_BASE/scripts/extensions/setup/30_se2CtxsysNocompress.sh

# Copy script to run datapatch
COPY --chown=oracle:dba $DATAPATCH_FILE $ORACLE_BASE/scripts/extensions/startup/
RUN chmod ug+x "$ORACLE_BASE"/scripts/extensions/startup/*.sh && sync

# Copy script to run lspatches
COPY --chown=oracle:dba $LSPATCHES_FILE $ORACLE_BASE/scripts/extensions/setup/
# hadolint ignore=SC2016
RUN chmod ug+x "$ORACLE_BASE"/scripts/extensions/setup/*.sh && sync && \
    echo 'ORACLE_SID=${ORACLE_SID:-ORCLCDB}; export ORACLE_SID=${ORACLE_SID^^}' > .bashrc

USER root
RUN "$ORACLE_BASE"/oraInventory/orainstRoot.sh && \
    "$ORACLE_HOME"/root.sh

USER oracle

# Using checkDBLockStatus.sh if k8s extension was applied, otherwise, using checkDBStatus.sh
HEALTHCHECK --interval=1m --start-period=20m --timeout=30s \
   CMD if [ -e $ORACLE_BASE/$CHECK_DB_LOCK_FILE ]; then $ORACLE_BASE/$CHECK_DB_LOCK_FILE ; else $ORACLE_BASE/$CHECK_DB_FILE ; fi >/dev/null || exit 1

# Define default command to start Oracle Database. 
CMD [ "/bin/bash", "-c", "exec $ORACLE_BASE/$RUN_FILE" ]
