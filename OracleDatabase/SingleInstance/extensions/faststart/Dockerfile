# LICENSE UPL 1.0
#
# Faststart extension (2026-09-20) - see extensions/patching/README.md,
# "Possible future step: a faststart CI variant" for the full design
# discussion and open questions.
#
# Builds a CDB$ROOT+PDB$SEED once (reusing the base image's already-
# regenerated, already-patched seed - no datapatch needed), PLUS both
# character-set variants of the customer PDB (AL32UTF8 and WE8ISO8859P15 -
# see buildFaststart.sh for why runtime INTERNAL_CONVERT was dropped in
# favor of this), compresses the lot, and ships a lean entrypoint that
# decompresses + starts it directly instead of running dbca -createDatabase
# at every container start. ORACLE_PDB stays runtime-configurable;
# ORACLE_CHARACTERSET is runtime-configurable but limited to those two
# values. ORACLE_SID is fixed at build time - see the README's discussion of
# which JDBC connect styles that does and doesn't affect.
#
# HOW TO BUILD
# ------------
#   ./buildExtensions.sh -b oracle/database:19.32.0.0-se2-ext \
#     -t oracle/database:19.32.0.0-se2-faststart -x 'faststart'

ARG BASE_IMAGE=oracle/database:19.32.0.0-se2-ext
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS builder

COPY --chown=oracle:dba buildFaststart.sh "$ORACLE_BASE"/
RUN chmod ug+x "$ORACLE_BASE"/buildFaststart.sh && \
    sync && \
    "$ORACLE_BASE"/buildFaststart.sh && \
    rm -f "$ORACLE_BASE"/buildFaststart.sh

## Final stage: the seed template and creation-only script are no longer
## needed - this image never calls dbca -createDatabase again.
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

# This image never calls dbca -createDatabase or datapatch again, so none
# of the following is needed at runtime: the ~1.1GB regenerated seed
# template (its one and only use already happened, in the builder stage
# above), the base image's createDB.sh, and the ~250MB per-RU sqlpatch zip
# datapatch keeps around for a future re-run against an existing volume
# (this image's database is a fixed, one-shot state, not a persistent
# volume that gets independently re-patched).
#
# IMPORTANT: this only actually shrinks the image when built with
# `--squash-all` (buildExtensions.sh: `-o '--squash-all'`) - `rm` alone in
# this stage only whites out files that physically remain in the inherited
# base image's own (already-published) layers; see README for why.
RUN rm -f "$ORACLE_HOME"/assistants/dbca/templates/General_Purpose_*.dbc \
          "$ORACLE_HOME"/assistants/dbca/templates/General_Purpose_*.ctl \
          "$ORACLE_HOME"/assistants/dbca/templates/General_Purpose_*.dfb* \
          "$ORACLE_HOME"/assistants/dbca/templates/General_Purpose_*.README \
          "$ORACLE_BASE"/scripts/base/createDB.sh && \
    find "$ORACLE_HOME"/sqlpatch -mindepth 3 -maxdepth 3 -iname '*.zip' -delete

COPY --from=builder --chown=oracle:dba /opt/oracle/faststart-oradata.tar.xz "$ORACLE_BASE"/
COPY --chown=oracle:dba startFaststart.sh "$ORACLE_BASE"/scripts/base/
RUN chmod ug+x "$ORACLE_BASE"/scripts/base/startFaststart.sh && sync

HEALTHCHECK --interval=1m --start-period=2m --timeout=30s \
   CMD $ORACLE_BASE/$CHECK_DB_FILE >/dev/null || exit 1

CMD [ "/bin/bash", "-c", "exec $ORACLE_BASE/scripts/base/startFaststart.sh" ]
