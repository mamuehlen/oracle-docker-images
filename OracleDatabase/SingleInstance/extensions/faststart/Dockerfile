# LICENSE UPL 1.0
#
# Faststart extension (2026-09-20) - see extensions/patching/README.md,
# "\"faststart\" CI variant (implemented, ../faststart/)" for the full
# design discussion, measured results, and 19.32/23.26 status.
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
# The lean, pre-patching/pre-seed sibling of BASE_IMAGE - same trick
# extensions/patching/Dockerfile uses for its own final stage
# (`FROM ${BASE_IMAGE}-base`). Needed because `rm` in a stage FROM'd
# directly off BASE_IMAGE only whites out files that physically remain in
# BASE_IMAGE's own already-published layers (confirmed by testing: image
# size didn't shrink at all that way). `COPY --from=<stage>` instead
# copies the *resolved filesystem view* of that stage, not raw layers -
# so starting the final stage from a genuinely lean, separate image and
# copying the already-slimmed builder stage's content onto it actually
# shrinks the result. Confirmed safe to use directly (no re-declared
# ENV vars needed): diffing this image's `docker inspect .Config.Env`
# against BASE_IMAGE's shows exactly 8 patching-specific vars missing
# (CHECK_DB_LOCK_FILE, DATAPATCH_FILE, LOCKING_SCRIPT, LSPATCHES_FILE,
# SHUT_DB_FILE, SKIP_DATAPATCH, STARTUP_FILE, SWAP_LOCK_FILE) - none of
# which any script this image actually runs at build or runtime
# references (`grep`-checked; savePatchSummary.sh, the one hook whose
# name matches LSPATCHES_FILE, sets its own local variable of the same
# name and never reads the environment one).
ARG BASE_IMAGE_LEAN=oracle/database:19.32.0.0-se2-base

# 7zzs: the official 7-Zip project's single-file, fully static Linux
# binary (github.com/ip7z/7zip releases - no shared-library dependencies
# at all, verified with `ldd` and `file`). Used instead of tar|xz for the
# faststart archive: measured (2026-09-20) at 685M solid-compressed for
# CDB$ROOT+PDB$SEED+both customer-PDB variants together, vs. 1.4G for the
# same content via `tar|xz` - LZMA2 in solid mode finds heavy cross-PDB
# redundancy that xz's small default dictionary can't reach. Needed in
# BOTH stages below: the builder stage to CREATE the archive, the final
# stage to EXTRACT it at container start (startFaststart.sh). A distro
# `p7zip` package isn't an option (not in Oracle Linux's default repos,
# would need EPEL), and the dynamically-linked p7zip from a non-Oracle-
# Linux host fails here with a glibc/libstdc++ ABI mismatch
# (`CXXABI_1.3.15' not found`) - 7zzs's static linking is exactly why
# gvenzl/oci-oracle-free uses the same binary for the same purpose.
FROM oraclelinux:9 AS sevenzip
ARG SEVENZIP_VERSION=26.03
ARG SEVENZIP_SHA256=dc99eff5008f1ab79bd7084c68513701547a808a89502bf4133683535ab3c695
RUN set -eux; \
    dnf install -y xz; \
    mkdir -p /tmp/7z && cd /tmp/7z; \
    curl -fsSL -O "https://github.com/ip7z/7zip/releases/download/${SEVENZIP_VERSION}/7z$(echo "${SEVENZIP_VERSION}" | tr -d .)-linux-x64.tar.xz"; \
    echo "${SEVENZIP_SHA256}  7z$(echo "${SEVENZIP_VERSION}" | tr -d .)-linux-x64.tar.xz" | sha256sum -c -; \
    tar xf 7z*.tar.xz 7zzs License.txt; \
    chmod 755 7zzs

# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS builder

COPY --from=sevenzip /tmp/7z/7zzs /usr/bin/7zzs
COPY --chown=oracle:dba buildFaststart.sh "$ORACLE_BASE"/
RUN chmod ug+x "$ORACLE_BASE"/buildFaststart.sh && \
    sync && \
    "$ORACLE_BASE"/buildFaststart.sh && \
    rm -f "$ORACLE_BASE"/buildFaststart.sh

# This image never calls dbca -createDatabase again (its build-time use in
# buildFaststart.sh is the only one), so none of the following is needed at
# runtime: every dbca seed/clone template (NOT just the ones matching our
# own 19.32 regenerated-template naming, "General_Purpose_<RU>.*": a stock
# (non-regenerated, e.g. a 23.26 Gold Image) seed is named
# "General_Purpose.dbc"/"Seed_Database.ctl/.dfb*" instead, so this removes
# the templates directory's contents wholesale rather than name-matching -
# 1.1GB for our regenerated 19.32 template, 417MB for a stock 23.26 Gold
# Image one, checked 2026-09-20), and the base image's createDB.sh.
#
# rollback_files/ (686MB across the 3 RU/bug directories present for
# 19.32, 669MB of it from the main RU alone) is removed too, but for a
# narrower reason than "never runs datapatch again" - since 2026-09-20
# startFaststart.sh DOES run datapatch, forward, when a newer image starts
# against a volume last touched by an older one (see
# ../patching/README.md's "Persistence and datapatch" section). Forward
# `datapatch` only ever reads `<bug>_apply.sql` (kept); `rollback_files/`
# backs a specific, deliberate `datapatch -rollback <bug>` instead, which
# this image just doesn't support - a real but narrow trade-off, not the
# "datapatch never runs at all" case this comment used to claim. Any per-RU
# sqlpatch zip is removed for the same "not needed for forward apply"
# reason (there wasn't actually one present for 19.32 - the
# `-iname '*.zip' -delete` below was always a no-op there, checked
# 2026-09-20 - kept for whichever version does ship one).
#
# Removed HERE, inside the builder stage itself, not in the final stage -
# see BASE_IMAGE_LEAN's comment above for why that distinction is exactly
# what makes this actually shrink the final image instead of just whiting
# the files out.
RUN find "$ORACLE_HOME"/assistants/dbca/templates -mindepth 1 -delete && \
    rm -f "$ORACLE_BASE"/scripts/base/createDB.sh && \
    find "$ORACLE_HOME"/sqlpatch -mindepth 3 -maxdepth 3 -iname '*.zip' -delete && \
    find "$ORACLE_HOME"/sqlpatch -type d -name rollback_files -exec rm -rf {} +

## Final stage: starts from the lean, pre-patching sibling (see
## BASE_IMAGE_LEAN above) and copies the builder stage's already-slimmed
## $ORACLE_BASE onto it in one fresh layer - this is what actually
## shrinks the image, not the `rm` above by itself.
# hadolint ignore=DL3006
FROM ${BASE_IMAGE_LEAN}

# BASE_IMAGE_LEAN has no USER set (defaults to root, WORKDIR /) - BASE_IMAGE
# (-ext) sets these explicitly, so this stage needs to as well (confirmed
# by testing: `docker inspect .Config.User` is empty on the lean image,
# "oracle" on -ext).
USER oracle
WORKDIR /home/oracle

COPY --from=sevenzip /tmp/7z/7zzs /usr/bin/7zzs
COPY --from=sevenzip /tmp/7z/License.txt /usr/share/licenses/7zip/License.txt
COPY --from=builder "$ORACLE_BASE" "$ORACLE_BASE"
COPY --chown=oracle:dba startFaststart.sh "$ORACLE_BASE"/scripts/base/
RUN chmod ug+x "$ORACLE_BASE"/scripts/base/startFaststart.sh && sync

# Same two upstream hooks extensions/patching/Dockerfile installs
# (unmodified copies, not our own code - see that Dockerfile's own comment
# for what each does), copied here directly rather than referenced across
# extensions (buildExtensions.sh gives each extension its own directory as
# build context, so `../patching/...` isn't reachable from here). Installed
# unconditionally - regardless of whether BASE_IMAGE came from
# extensions/patching (already has them; this is a harmless identical
# overwrite) or a Gold Image built with patching=false (never had them
# before this): startFaststart.sh's persistence support (see
# ../patching/README.md's "Persistence and datapatch" section) needs
# runDatapatch.sh to actually be present to have anything to call.
# BASE_IMAGE_LEAN has none of this either way - the base stage never had
# it - so it's added here, not inherited.
ENV DATAPATCH_FILE="runDatapatch.sh" \
    LSPATCHES_FILE="savePatchSummary.sh" \
    SKIP_DATAPATCH=false
COPY --chown=oracle:dba runDatapatch.sh "$ORACLE_BASE"/scripts/extensions/startup/
COPY --chown=oracle:dba savePatchSummary.sh "$ORACLE_BASE"/scripts/extensions/setup/
RUN chmod ug+x "$ORACLE_BASE"/scripts/extensions/startup/*.sh \
               "$ORACLE_BASE"/scripts/extensions/setup/*.sh && sync

# extensions/patching/Dockerfile re-runs these two after its own analogous
# COPY --from=<flattened stage> onto a lean base - mirrored here rather
# than assumed unnecessary, since this is the same "recopy a patched
# ORACLE_HOME onto a pristine base" operation, just one level up.
USER root
RUN "$ORACLE_BASE"/oraInventory/orainstRoot.sh && \
    "$ORACLE_HOME"/root.sh
USER oracle

HEALTHCHECK --interval=1m --start-period=2m --timeout=30s \
   CMD $ORACLE_BASE/$CHECK_DB_FILE >/dev/null || exit 1

CMD [ "/bin/bash", "-c", "exec $ORACLE_BASE/scripts/base/startFaststart.sh" ]
