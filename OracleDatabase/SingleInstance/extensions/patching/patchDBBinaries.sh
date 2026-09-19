#!/bin/bash
# shellcheck disable=SC2086,SC2231,SC2236
# shellcheck disable=SC2206
# shellcheck disable=SC2012
# shellcheck disable=SC2068
# LICENSE UPL 1.0
#
# Copyright (c) 2020-2026 Oracle and/or its affiliates. All rights reserved.
#
# Since: March, 2020
# Author: rishabh.y.gupta@oracle.com
# Description: Applies the patches provided by the user on the oracle home.
#
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS HEADER.
#

# JAVA_HOME is not set anywhere by the base Dockerfile/environment, and the JRE
# bundled inside the refreshed OPatch (from the one_offs/p6880880 zip, unpacked
# below) is broken in this download (wrong/corrupted variant - same issue seen
# manually earlier: OPatch/jre/bin/java errors with "No such file or directory").
# opatchauto's Java detection (DBUtilServices.pm) has no fallback for that and
# fails with "No valid java found for patching" unless JAVA_HOME points
# somewhere that actually works - $ORACLE_HOME/jdk (installed as part of the
# base 19.3.0 software) is that known-good JDK.
export JAVA_HOME="${ORACLE_HOME}/jdk"
export PATH="${JAVA_HOME}/bin:${PATH}"

RU_DIR="${PATCH_DIR}/release_update"
ONE_OFFS_DIR="${PATCH_DIR}/one_offs"

ru_count=$(ls $RU_DIR/*.zip 2> /dev/null | wc -l)
if [ $ru_count -ge 2 ]; then
    echo "Error: Only 1 Release Update can be applied."
    exit 1;
elif [ $ru_count == 1 ]; then
    ru_patch="$(ls $RU_DIR/*.zip)"
    echo "Unzipping $ru_patch";
    unzip -qo $ru_patch -d $PATCH_DIR;
    ru_patch=$(echo ${ru_patch##*/} | cut -d_ -f1 | cut -dp -f2)
else
    echo "No Release Update to be installed."
fi

ONE_OFFS_LIST=()

if ls $ONE_OFFS_DIR/*.zip 2> /dev/null; then
    for patch_zip in $ONE_OFFS_DIR/*.zip; do
        patch_no=$(echo ${patch_zip##*/} | cut -d_ -f1 | cut -dp -f2)
        if [ $patch_no == "6880880" ]; then
            echo "Removing directory ${ORACLE_HOME}/OPatch";
            rm -rf ${ORACLE_HOME}/OPatch;
            echo "Unzipping OPatch archive $patch_zip to ${ORACLE_HOME}";
            unzip -qo $patch_zip -d $ORACLE_HOME;
            # The JRE bundled in this OPatch download is broken (wrong/corrupted
            # variant - "No such file or directory" when actually executing
            # OPatch/jre/bin/java, even though the file exists). opatchauto's
            # Java detection (DBUtilServices.pm) hardcodes OPatch/jre as its
            # first check in every code path, including a separate bootstrap
            # Perl sub-session it spawns later - passing -jre on the command
            # line only covers the first check, not that sub-session's own
            # re-detection. Replacing OPatch/jre with a symlink to the known-good
            # $ORACLE_HOME/jdk fixes every one of those checks at once.
            echo "Replacing broken bundled OPatch/jre with a symlink to \$ORACLE_HOME/jdk";
            rm -rf ${ORACLE_HOME}/OPatch/jre;
            ln -s ${ORACLE_HOME}/jdk ${ORACLE_HOME}/OPatch/jre;
        else
            ONE_OFFS_LIST+=($patch_no);
            echo "Unzipping $patch_zip";
            unzip -qo $patch_zip -d $PATCH_DIR;
        fi
    done
else
    echo "No one-offs to be installed."
fi

export PATH=${ORACLE_HOME}/perl/bin:$PATH;

if [ ! -z $ru_patch ]; then
    echo "Applying Release Update: $ru_patch";
    cmd="${ORACLE_HOME}/OPatch/opatchauto apply -binary -oh $ORACLE_HOME ${PATCH_DIR}/${ru_patch} -target_type rac_database -jre $ORACLE_HOME/jdk";
    echo "Running: $cmd";
    $cmd || {
        echo "RU application failed for patchset: ${ru_patch}";
        exit 1;
    }
fi

for patch in ${ONE_OFFS_LIST[@]}; do
    echo "Applying patch: $patch";
    cmd="${ORACLE_HOME}/OPatch/opatchauto apply -binary -oh $ORACLE_HOME ${PATCH_DIR}/${patch} -target_type rac_database -jre $ORACLE_HOME/jdk";
    echo "Running: $cmd";
    $cmd || {
        echo "Patch application failed for ${patch}";
        exit 1;
    }
done
