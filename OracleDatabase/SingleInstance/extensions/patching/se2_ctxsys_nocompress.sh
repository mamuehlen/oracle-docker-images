#!/bin/bash
# SE2-Lizenzfalle: Oracle legt Oracle-Text-/JSON-Search-Indizes standardmaessig
# mit Advanced Index Compression (COMPRESS 2) an - das ist unter Standard
# Edition 2 nicht lizenziert. Die System-Default-Storage-Preference wird
# deshalb auf NOCOMPRESS umgestellt, damit auch Indizes, die ohne eigene
# PARAMETERS-Klausel angelegt werden (z.B. per Liquibase "FOR JSON"),
# automatisch unkomprimiert entstehen.
# Quelle: https://www.database-blog.at/2026/03/05/oracle-lizenzfalle-oracle-standard-edition-und-oracle-text-indizes/
#
# WICHTIG - dieses Skript war bislang eine .sql-Datei, die von
# runUserScripts.sh per "sqlplus / as sysdba" ausgefuehrt wurde. Diese
# OS-Auth-Verbindung landet immer in CDB$ROOT, nie in $ORACLE_PDB.
# CTXSYS ist zwar ein "common user" (gleiche Definition/Objekte in jedem
# Container), aber CTX_DDL.SET_ATTRIBUTE schreibt PDB-lokale Daten
# (CTXSYS.DR$PREFERENCE / DEFAULT_STORAGE) - die Einstellung landete also
# seit dem allerersten Commit dieser Extension nur in CDB$ROOT, wo nie ein
# Oracle-Text-Index entsteht, und wirkte in der eigentlichen PDB nie.
# Gefunden und behoben 2026-09-20 beim Testen der Seed-Regenerierung.
#
# Als .sh (statt .sql) implementiert, weil runUserScripts.sh .sql-Dateien
# immer mit einem blanken "sqlplus / as sysdba" ausfuehrt (kein Platz fuer
# ein ALTER SESSION SET CONTAINER davor) - ein .sh-Skript wird dagegen
# gesourced und kann $ORACLE_PDB aus der Umgebung von runOracle.sh nutzen.
set -e

TARGET_CONTAINER="CDB\$ROOT"
if [ "${NON_CDB:-false}" != "true" ] && [ -n "${ORACLE_PDB}" ]; then
  TARGET_CONTAINER="${ORACLE_PDB}"
fi

echo "Setting CTXSYS default storage to NOCOMPRESS in container ${TARGET_CONTAINER} (SE2 licensing safeguard)"
sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER = ${TARGET_CONTAINER};
BEGIN
  ctxsys.ctx_ddl.set_attribute('CTXSYS.DEFAULT_STORAGE', 'I_INDEX_CLAUSE', 'NOCOMPRESS');
  ctxsys.ctx_ddl.set_attribute('CTXSYS.DEFAULT_STORAGE', 'I_TABLE_CLAUSE', 'NOCOMPRESS');
END;
/
EXIT
SQL
