-- SE2-Lizenzfalle: Oracle legt Oracle-Text-/JSON-Search-Indizes standardmaessig
-- mit Advanced Index Compression (COMPRESS 2) an - das ist unter Standard
-- Edition 2 nicht lizenziert. Die System-Default-Storage-Preference wird
-- deshalb auf NOCOMPRESS umgestellt, damit auch Indizes, die ohne eigene
-- PARAMETERS-Klausel angelegt werden (z.B. per Liquibase "FOR JSON"),
-- automatisch unkomprimiert entstehen.
-- Quelle: https://www.database-blog.at/2026/03/05/oracle-lizenzfalle-oracle-standard-edition-und-oracle-text-indizes/
whenever sqlerror exit failure
begin
    ctxsys.ctx_ddl.set_attribute('CTXSYS.DEFAULT_STORAGE', 'I_INDEX_CLAUSE', 'NOCOMPRESS');
    ctxsys.ctx_ddl.set_attribute('CTXSYS.DEFAULT_STORAGE', 'I_TABLE_CLAUSE', 'NOCOMPRESS');
end;
/
whenever sqlerror continue
exit
