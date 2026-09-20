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

COPY --from=sevenzip /tmp/7z/7zzs /usr/bin/7zzs
COPY --from=sevenzip /tmp/7z/License.txt /usr/share/licenses/7zip/License.txt
COPY --from=builder --chown=oracle:dba /opt/oracle/faststart-oradata.7z "$ORACLE_BASE"/
COPY --chown=oracle:dba startFaststart.sh "$ORACLE_BASE"/scripts/base/
RUN chmod ug+x "$ORACLE_BASE"/scripts/base/startFaststart.sh && sync

HEALTHCHECK --interval=1m --start-period=2m --timeout=30s \
   CMD $ORACLE_BASE/$CHECK_DB_FILE >/dev/null || exit 1

CMD [ "/bin/bash", "-c", "exec $ORACLE_BASE/scripts/base/startFaststart.sh" ]
