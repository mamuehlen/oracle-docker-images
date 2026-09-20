# PATCH APPLICATION

Applies patches on oracle home. Multiple one-offs can be applied in a single build but only 1 RU can be applied.

Download the release update and one-offs and place them under extensions/patching/patches directory inside subfolders release_update and one_offs respectively.

Once the patches have been placed in the correct directories, use the buildExtensions.sh script to build the extended image with patch support.

**NOTE**: For patching to work successfully, one should build the base container image by passing one additional build argument `--build-arg SLIMMING=false`. By default, SLIMMING is true to remove some components from the image with the intention of making the image slimmer. These removed components cause problems while patching and  result in unsuccessful patching operation.

Example build command to build the container image:

    ./buildContainerImage.sh -i -e -v 19.3.0 -o '--build-arg SLIMMING=false'

---

# ZEDAS additions (branch `zedas-patches`)

## Seed template regeneration (`seedgen` stage)

### The problem

Patching the Oracle Home with a Release Update patches the *binaries*. The
dbca seed database that ships with the 19c installer
(`$ORACLE_HOME/assistants/dbca/templates/Seed_Database.dfb`, referenced by
`General_Purpose.dbc`) stays at the 19.3.0 base level. So every container
that creates a new database:

1. restores a 19.3.0 dictionary from that seed (2 min),
2. then runs `datapatch` to bring CDB$ROOT, PDB$SEED and the PDB up to the
   RU level of the binaries.

With RU 19.32 + the Datapump bundle patch that datapatch step is **~30
minutes**, on every first start of every container (subsequent starts skip
it via `runDatapatch.sh`'s `.lspatches` comparison). It also runs *twice*:
the first pass ends `WITH ERRORS` (ORA-29913/ORA-04063 on
`KUPU$UTILITIES_INT` - the RU's Spatial external-table load runs before the
DPBP's SQL is in place), the second pass then succeeds. Harmless, but it
looks alarming in the log and it is the bulk of the wait.

26ai Gold Images ship their seed at the RU level, which is why the 23.26
containers are ready in ~13 min without any of this. For 19c, Oracle offers
no patched seed - and the Oracle Container Registry has no SE2 images at all.

### What the `seedgen` stage does

`Dockerfile` has a third stage, `seedgen`, between `patching` and the final
stage. It runs `regenerateSeedTemplate.sh` once, at build time:

1. creates a throw-away CDB (`SEEDCDB`, CDB$ROOT + PDB$SEED, **no user PDB**,
   no EM Express, **character set US7ASCII** - see "Character sets" below)
   from the stock seed - this is where the 30-minute datapatch run happens,
   once, at build time;
2. verifies - per container, via `dba_registry_sqlpatch` inside CDB$ROOT and
   inside PDB$SEED (the `CDB_*` views do **not** show PDB$SEED) - that every
   patch is `SUCCESS` and prints component versions and invalid-object counts
   into the build log (fails the build otherwise);
2b. removes OLAP (APS + XOQ, `catnoxoq.sql`/`catnoaps.sql` per container,
   then `utlrp`) and purges the optimizer statistics history
   (`DBMS_STATS.PURGE_STATS(PURGE_ALL)`) - see "What's in the seed" below;
   fails the build if anything is left INVALID or APS/XOQ aren't REMOVED;
3. shrinks what datapatch bloated: undo is swapped out and back in
   (1370 MB → 25 MB, a datafile can't be shrunk below its high-water mark),
   TEMP resized (260 MB → 20 MB);
4. pins RMAN's compression algorithm to `BASIC` and prints
   `SHOW COMPRESSION ALGORITHM` (see licensing below), then runs
   `dbca -createCloneTemplate -compressBackup true -rmanParallelism 4`,
   producing `General_Purpose_<RU>.dbc/.ctl/.dfb1..7` (`<RU>` is derived
   from `opatch lspatches`, e.g. `1932`, so the template name can never lie
   about the patch level);
5. deletes the throw-away CDB with `dbca -deleteDatabase` and removes every
   trace of it (oradata, diag, cfgtoollogs, audit, listener config, oratab
   entry, `$ORACLE_HOME/dbs` and `rdbms/log` files);
6. points `$ORACLE_BASE/scripts/base/dbca.rsp.tmpl` at the new template, sets
   `numberOfPDBs=0` there (see DBT-10312 below), drops the `<characterSet>`
   element from the `.dbc` (avoids dbca's DBT-11153 warning at every start),
   deletes the stock seed files and writes a `General_Purpose_<RU>.README`
   next to the template with the `opatch lspatches` output it was built from.

The final stage then does `COPY --from=seedgen $ORACLE_BASE $ORACLE_BASE`
instead of `--from=patching`. Because everything temporary is created *and*
deleted inside the `seedgen` stage, none of it ends up in a layer of the
final image - the only net additions are the template files and the two
edits above. (A `docker commit` of a container that did the same thing would
be ~1.4 GB larger: it would carry the stock seed as a whiteout, the
sqlpatch/dbca logs and the CVU temp files.)

### Result

Measured locally (podman, same host, `19.3.0` SE2 + RU 19.32 + DPBP 19.32):

| | stock seed | regenerated seed |
|---|---|---|
| container start → `DATABASE IS READY TO USE!` | ~30-35 min | **7 min 31 s** |
| of which RMAN restore of the seed | ~1 min | 2 min 10 s (7 pieces, 1.1 GB) |
| of which datapatch | ~25-30 min (2 passes) | 2 × 11 s ("nothing to apply") |
| `dba_registry_sqlpatch` after start | RU+DPBP SUCCESS (after WITH ERRORS) | only the template's own history rows, no new work |
| invalid objects | 0 | 0 |
| seed template on disk | 363 MB (`Seed_Database.dfb` 262 MB + `pdbseed.dfb` 83 MB + ctl) | 1.1 GB (7 RMAN pieces + ctl) |
| image size (podman, uncompressed) | 8.37 GB | 9.44 GB |

The image grows by ~1.1 GB: +0.7 GB for the template (the stock seed is a
19.3 dictionary; the patched one carries the RU's added/changed dictionary
objects, and PDB$SEED is a full copy in the CDB clone template rather than
the separate small `pdbseed.dfb`) and +0.25 GB for
`$ORACLE_HOME/sqlpatch/<patch>/<uid>/<patch>.zip`, which datapatch creates
on its first run against any database (it loads the patch's SQL files into
the dictionary from it). With the stock seed every container creates that
zip at first start in its own writable layer; here it's created once, at
build time, and shipped. Both parts are already compressed (RMAN BASIC /
zip), so the registry-side growth is about the same ~1 GB.

(Not to be confused with the `prebuiltdb` extension, which stores a fully
created database uncompressed - 4.2 GB on disk, ~0.5 GB in the registry -
and is a different trade-off; the seed approach keeps the normal "create a
fresh database at first start" semantics, `ORACLE_PWD`, `ORACLE_SID`,
`ORACLE_PDB`, `ORACLE_CHARACTERSET` handling and all.)

### What's in the seed (measured, 19.32 SE2)

`dba_segments` in a container from the regenerated seed, before the OLAP
removal / stats purge of step 2b (SYSTEM+SYSAUX, uncompressed MB):

| | CDB$ROOT | PDB$SEED | removable? |
|---|---|---|---|
| RU zip as BLOB in `REGISTRY$SQLPATCH_RU_INFO` (SYSTEM) | 243 | 243 | no - the RU's rollback scripts; `datapatch -purge_old_metadata` (19.25+) only purges *superseded* RUs |
| Java: `IDL_UB1$`, `JAVA$MC$`, `SOURCE$`, ... | 475 | ~200 | no - Spatial needs the JVM (MDSYS: 2 913 Java classes, 329 `LANGUAGE JAVA` call specs) |
| MDSYS (Spatial) | 267 | 187 | no - required by ZEDAS |
| XDB | 68 | 61 | no |
| OLAP leftovers (`AO` analytic workspace tables, APS/XOQ "OPTION OFF") | 46 | ~20 | **yes → step 2b** (not licensable in SE2; the Ansible role's dbca template has `CWMLITE=false`) |
| AWR structure (`WRH$/WRM$`, no snapshots) | 30 | 0 | not worth it |
| optimizer statistics history | 15 | 9 | **yes → step 2b** |
| Multimedia (ORDSYS/ORDDATA), WMSYS, DVSYS, OLS, Text catalog | < 20 | < 15 | not worth it |

So ~100 MB of a ~2.5 GB dictionary (~4 %) is trimmable; the three big
blocks (RU BLOB, Java, Spatial) are fixed. gvenzl/oci-oracle-free's big
lever - `DBMS_SPACE.SHRINK_TABLESPACE` - is a 23ai feature and doesn't
exist in 19c; his component removals (JVM, XDK, Text, Spatial) contradict
what ZEDAS needs. His undo-swap trick is exactly what step 3 does.

### Spatial indexes and SE2 (checked)

Unlike Oracle Text (see `se2_ctxsys_nocompress.sh`), Spatial has no
compression trap: a spatial index created without `PARAMETERS` gets a
`NOCOMPRESS` `MDRT_...$` table, a `NOCOMPRESS` SecureFile LOB and an
uncompressed index; `compression=LOW|MEDIUM|HIGH` is opt-in only (requires
`securefile=TRUE`, default `OFF`), and `DBA_FEATURE_USAGE_STATISTICS`
shows no compression feature after creating one. Verified on this image
(2026-09-20). Nothing to configure.

### SE2 licensing hygiene at first start (`20_se2LicenseSettings.sh`)

Also via the `scripts/setup` hook: `CONTROL_MANAGEMENT_PACK_ACCESS=NONE`
(default is `DIAGNOSTIC+TUNING`, i.e. the EE-only Diagnostics/Tuning Packs
are in use from minute one and recorded in feature usage), `HEAT_MAP=OFF`,
and the SQL Tuning Advisor auto task disabled in CDB$ROOT and `$ORACLE_PDB`.
Same settings the ZEDAS Ansible role applies to every customer database.

### Licensing note (Standard Edition 2)

The template is written as an RMAN **compressed** backupset. RMAN knows four
backup compression algorithms: `BASIC`, and `LOW`/`MEDIUM`/`HIGH`. Only
`BASIC` is included in every edition (Licensing Guide, "Backup and
Recovery" table: *RMAN basic compression - SE2: Y*). The other three belong
to the **Advanced Compression Option**, which is EE-only and cannot be
licensed for SE2 at all - RMAN doesn't technically block them in SE2, it
just records the usage in `DBA_FEATURE_USAGE_STATISTICS`.

`dbca -createCloneTemplate -compressBackup true` uses whatever the source
database's RMAN configuration says. The default is `BASIC`, but the script
doesn't rely on that: it runs `CONFIGURE COMPRESSION ALGORITHM 'BASIC'`
first, prints `SHOW COMPRESSION ALGORITHM` into the build log, and **fails
the build** if the effective algorithm is anything else. Look for

    CONFIGURE COMPRESSION ALGORITHM 'BASIC' AS OF RELEASE 'DEFAULT' OPTIMIZE FOR LOAD TRUE;

in the build output of the `seedgen` stage - that line is the evidence.

(The stock `Seed_Database.dfb` shipped in the SE2 installer is the same kind
of RMAN-compressed backupset, so this is not a new licensing exposure.)

### Character sets: the seed is US7ASCII, dbca converts it itself

Finding (2026-09-20, corrected 2026-09-20): with a **declared**
`<characterSet>` element in the `.dbc` (what `dbca -createCloneTemplate`
writes by default), dbca refuses to convert a CDB clone template and only
warns:

    [WARNING] [DBT-11153] Character set specified (WE8ISO8859P15) is different from that of the character set (AL32UTF8) in the template.

`regenerateSeedTemplate.sh` therefore strips `<characterSet>` from the
built template's `.dbc`. Once that element is gone, dbca behaves
differently than the DBT-11153 case suggested at first: it **does**
attempt an automatic conversion, right after `ALTER DATABASE OPEN`, to
whatever `ORACLE_CHARACTERSET` was requested - confirmed in the golden
image's own alert log:

    Database Characterset is US7ASCII
    ...
    Completed: ALTER DATABASE OPEN
    alter database character set INTERNAL_CONVERT AL32UTF8
    Completed: alter database character set INTERNAL_CONVERT AL32UTF8
    ...
    Database Characterset is AL32UTF8

(That line is ~570 lines before the setup hook's own `CREATE PLUGGABLE
DATABASE ORCLPDB1` in the same log - it happens inside dbca's own
`-createDatabase`, long before any of our hooks run.) This conversion
attempt only **succeeds** in the legitimate subset→superset direction
(the normal, documented rule for `ALTER DATABASE CHARACTER SET
INTERNAL_CONVERT` regardless of dbca); in the forbidden superset→subset
direction it fails **silently**, with no warning at all once `<characterSet>` is stripped,
leaving the database at its original charset. That silent-failure case is
exactly what an earlier test (`cstest2`) hit: the throw-away CDB used to
build that particular template was still AL32UTF8 at the time (built
before the US7ASCII change below), so requesting WE8ISO8859P15 against it
was the forbidden direction and silently did nothing - which looked at
the time like "dbca never converts a clone template's charset, full
stop." It converts fine; that test just asked for the wrong direction.

How does the *stock* seed manage the same problem? Its alert log tells:
`Database Characterset is US7ASCII` - Oracle ships the seed in US7ASCII
and dbca runs the identical two-step sequence (CDB$ROOT, then close/open
restricted/convert/close/open read-only for PDB$SEED) against it. US7ASCII
is a strict subset of every character set, so converting *from* it is
always the legitimate, always-succeeding direction - which is exactly why
building our own template in US7ASCII (rather than any real character
set) makes every `ORACLE_CHARACTERSET` reachable.

Therefore `regenerateSeedTemplate.sh` creates the throw-away CDB in
**US7ASCII** (the template is byte-identical in size either way, since the
dictionary is pure ASCII regardless), and dbca's own automatic conversion
- now that `<characterSet>` is stripped - does the rest by itself at every
container start, no extra code needed for that part.

The setup hook `scripts/extensions/setup/10_seedCreatePDB.sh` still
carries an explicit, defensive `INTERNAL_CONVERT` block replaying dbca's
own statement sequence, guarded by the same check (only runs if the
database isn't already at the target charset, and refuses if it isn't
still US7ASCII). Given the above, this is now believed to be a no-op
safety net rather than the active mechanism in practice - every test to
date shows dbca's own conversion already completing (visible in the
alert log, well before the hook's own `CREATE PLUGGABLE DATABASE` line)
before the hook even starts - but it's kept because it's a cheap,
idempotent, correctly-guarded fallback, and because it's the one thing in
this pipeline that hasn't been proven UNNECESSARY across the full input
space (e.g. it hasn't specifically been tested with a template that isn't
US7ASCII, which shouldn't happen given the build process but would be
exactly the case where dbca's own silent-fail behavior above would
otherwise leave the PDB\$SEED at the wrong charset with no error at all).

(`INTERNAL_CONVERT` is dbca-internal and not a documented user-facing
statement in the sense of being a supported public SQL command outside of
dbca's own use, but it is not exotic: it is the exact, unmodified sequence
dbca itself runs, on the same kind of database, in the same state and
direction. Mixed character sets inside one CDB would also be architecturally
possible - Oracle allows it when CDB$ROOT is AL32UTF8 - but are not needed
here, since each container only ever creates the one customer PDB.)

### The other half of "the character set is right": client-side NLS_LANG

Everything above is about the *database's* character set
(`ORACLE_CHARACTERSET`, what CDB$ROOT/PDB$SEED/the PDB actually store). It
says nothing about what a *client* connecting to that PDB assumes - and by
default, this image (like the stock one) sets neither `NLS_LANG` nor a
usable OS locale:

    LANG=            (empty - everything falls back to POSIX)
    NLS_LANG         not set anywhere (image env, .bashrc, profile)

When `NLS_LANG` is unset, Oracle client libraries (sqlplus, JDBC without
its own explicit charset config, etc.) default to `AMERICAN_AMERICA.
US7ASCII`. For pure-ASCII data this is harmless (US7ASCII is a subset of
everything). The moment non-ASCII text is involved - German umlauts, `€`,
anything outside 7-bit ASCII - a client stuck on that US7ASCII default
will silently mangle it on the way in or out (typically to `?` or garbled
multi-byte sequences), **even though the database itself is correctly at
AL32UTF8 or WE8ISO8859P15**. This is not something this image's seed work
introduced - the stock image has the identical gap - but it is exactly the
kind of silent failure the rest of this document worked hard to eliminate
on the server side, so it is worth calling out explicitly here rather than
assuming it is someone else's problem.

There is no single correct default to bake into the image: which
`NLS_LANG` is "right" depends on the connecting application's own target
character set (an AL32UTF8 consumer wants a different value than a
WE8ISO8859P15 one), which this image cannot know in advance. So: whoever
connects - an application's JDBC/OCI configuration, or a human running
`sqlplus` inside the container for troubleshooting - needs to set
`NLS_LANG` themselves, matching the PDB's actual character set, e.g.

    NLS_LANG=GERMAN_GERMANY.AL32UTF8        # for an AL32UTF8 PDB
    NLS_LANG=GERMAN_GERMANY.WE8ISO8859P15   # for a WE8ISO8859P15 PDB (ASSET)

(the territory/language part before the dot only affects things like date
formats and error-message language, not correctness of the character
data - it is the part after the dot, matching the DB's `NLS_CHARACTERSET`,
that actually matters here).

### DBT-10312: the PDB is created by the setup hook, not by dbca

A clone template made from a CDB carries a `<PluggableDatabases>` element.
dbca then refuses `numberOfPDBs`/`pdbName` from the response file:

    [WARNING] [DBT-10312] Additional PDBs cannot be created when Container database template is specified

(Removing the element from the `.dbc` makes dbca crash with INS-08101 -
tested.) Left alone, a container would come up with CDB$ROOT + PDB$SEED but
**no `ORCLPDB1`**.

Therefore:

- `regenerateSeedTemplate.sh` sets `numberOfPDBs=0` and removes
  `pdbName`/`pdbAdminPassword` from `dbca.rsp.tmpl`, so dbca doesn't even try;
- the same hook `10_seedCreatePDB.sh`, right after the character-set step,
  runs `CREATE PLUGGABLE DATABASE $ORACLE_PDB ADMIN USER PDBADMIN ...
  FILE_NAME_CONVERT=(<seed dir>, <oradata>/$ORACLE_SID/$ORACLE_PDB/)`, opens
  it, `SAVE STATE`, creates the `USERS` tablespace (`users01.dbf`, 5 MB
  autoextend) and makes it the PDB's default tablespace - exactly what dbca
  does for the PDB it builds itself (without it the first `CREATE TABLE` of
  an application user fails with ORA-00959) - and repeats createDB.sh's
  `OPS$oracle` grants for the health check. PDBADMIN gets `$ORACLE_PWD` (as
  dbca's `pdbAdminPassword` would) or a random password when `ORACLE_PWD`
  isn't set. Since PDB$SEED is already at the RU level this takes seconds.
- upstream `dockerfiles/19.3.0/createDB.sh` is untouched except for an 8-line
  guard that skips its own `ALTER PLUGGABLE DATABASE ... SAVE STATE` when the
  PDB doesn't exist yet (it would otherwise log ORA-65011 at every first
  start). Keeping the seed logic in the extension hook rather than in
  createDB.sh keeps "Sync fork" from upstream conflict-free.

With the stock seed (`REGENERATE_SEED=false`) the PDB exists after dbca and
the hook is a no-op, as it is for `NON_CDB=true`.

#### Build sequencing for the dual-charset faststart design

Three things learned the hard way (2026-09-20, by actually running each
approach and reading the resulting `ORA-` error) rule out every "obvious"
sequencing:

1. `ALTER DATABASE CHARACTER SET INTERNAL_CONVERT` only works against
   `CDB$ROOT`+`PDB$SEED` themselves - the exact sequence dbca uses for its
   own stock seed (see "Character sets" above). Running it against an
   already-created ordinary PDB (e.g. clone a PDB from PDB$SEED first,
   then try to convert *that PDB*) fails hard with `ORA-12715: invalid
   character set specified`, even though the charset name itself is valid
   (`v$nls_valid_values` lists it). Confirmed independently by
   mikedietrichde.com ("Can you select a PDB's character set?"): the only
   supported way to give a PDB a non-default character set is to clone it
   from an already-differently-charset `PDB$SEED`, never to convert the
   clone afterward.
2. `INTERNAL_CONVERT`'s subset/superset check is about **binary
   byte-encoding compatibility**, not abstract character-repertoire
   coverage. `WE8ISO8859P15 -> AL32UTF8` fails with `ORA-12712: new
   character set must be a superset of old character set`, even though
   Unicode obviously covers every ISO-8859-15 character - because
   ISO-8859-15's high bytes (0x80-0xFF) aren't encoded as the same bytes
   AL32UTF8 (UTF-8) would use for those characters. Only `US7ASCII` is a
   true binary subset of *every* other Oracle character set (byte values
   0-127 are identical everywhere), so it's the only safe common starting
   point - but that also means the two target variants **cannot be
   produced by chaining** one conversion after the other; both must start
   from `US7ASCII` independently.
3. So: since converting `CDB$ROOT`+`PDB$SEED` a second time from a
   different starting point isn't an option, get back to the *same*
   `US7ASCII` starting point twice via a filesystem-level snapshot/restore
   instead of a second `dbca -createDatabase` run (saves ~7-8 min of
   RMAN-restore time, and both variants end up derived from byte-identical
   source data, which matters for compression below):

       1. dbca creates the throwaway CDB in US7ASCII (as today)
       2. shut down; `cp -a` the whole oradata/<SID>/ tree aside (root+seed
          only - no PDBs exist yet at this point)
       3. start up; convert CDB$ROOT+PDB$SEED to WE8ISO8859P15; clone the
          ISO-variant PDB from the now-ISO PDB$SEED
       4. `ALTER PLUGGABLE DATABASE <iso> UNPLUG INTO '<xml>'` - keeps its
          datafiles on disk, just drops the dictionary entry
       5. shut down; delete everything in oradata/<SID>/ EXCEPT the ISO
          PDB's own subdirectory; restore the step-2 snapshot over it -
          CDB$ROOT+PDB$SEED are back to pristine US7ASCII, the unplugged
          ISO PDB's files sit untouched alongside them
       6. start up; convert CDB$ROOT+PDB$SEED to AL32UTF8 (valid: US7ASCII
          is a subset of AL32UTF8 too); clone the UTF8-variant PDB from the
          now-AL32UTF8 PDB$SEED
       7. `CREATE PLUGGABLE DATABASE <iso> USING '<xml>' NOCOPY TEMPFILE
          REUSE` - plugs the ISO PDB back in. `TEMPFILE REUSE` is required:
          UNPLUG doesn't preserve temp files (no persistent data in them),
          so PLUG IN always tries to create a fresh one, but the ISO PDB's
          own old tempfile is still sitting at that exact path (step 5
          deliberately left its subdirectory alone) - a plain `CREATE`
          fails with `ORA-27038: created file already exists` /
          `ORA-01119` without the `REUSE` clause.

   Root ends up AL32UTF8 either way - not just preference, Oracle enforces
   it: a CDB can only hold PDBs with a character set different from root's
   own if root itself is AL32UTF8 (checked during the step-7 plug-in's
   compatibility validation).

Also found by testing: `ALTER SYSTEM ENABLE RESTRICTED SESSION` only
blocks *new* connections - `INTERNAL_CONVERT` itself additionally requires
*zero* other sessions connected at all (`ORA-12721`), and dbca/createDB.sh
can leave a lingering session behind for a moment right after returning
control. The build script kills every non-background, non-self session
before each conversion attempt and retries a few times if `ORA-12721`
still shows up.

7z vs xz for the archive: same core algorithm (LZMA/LZMA2), so no
meaningful compression difference. 7z is a real multi-file archive with
solid-mode cross-file dedup *and* selective per-file extraction (`7z x
-x!pattern`, what gvenzl's own faststart uses to pull SYSTEM/SYSAUX
separately); `tar | xz` gets the same solid-style cross-PDB dedup with a
large enough dictionary (`--lzma2=dict=...`) but has to decompress the
whole stream sequentially to reach a given file - no partial extraction.
Since this design decompresses both PDBs and then drops the unwanted one
anyway, that difference mostly doesn't matter here; 7z is still the
better default choice simply because gvenzl's already-proven tooling uses
it (`7zzs`, a single static binary, no extra runtime dependency).

## Setup hooks shipped by this extension

All in `$ORACLE_BASE/scripts/extensions/setup/` (run by `runOracle.sh` via
`runUserScripts.sh` once after database creation, alphabetical order):

| script | purpose |
|---|---|
| `10_seedCreatePDB.sh` | character-set conversion + PDB creation for the regenerated seed (above) |
| `20_se2LicenseSettings.sh` | `CONTROL_MANAGEMENT_PACK_ACCESS=NONE`, `HEAT_MAP=OFF`, SQL Tuning Advisor auto task off in CDB$ROOT and `$ORACLE_PDB` (see below) |
| `30_se2CtxsysNocompress.sh` | Oracle Text default storage `NOCOMPRESS` in `$ORACLE_PDB` (Advanced Index Compression is EE-only) - a `.sh`, not `.sql`, see script header: fixed 2026-09-20, had silently been a no-op in `CDB$ROOT` since this extension's first commit |
| `savePatchSummary.sh` | upstream: records `opatch lspatches` for `runDatapatch.sh`'s "already patched" check |

Deliberately **not** in `/opt/oracle/scripts/setup`: that is the *user* hook
(`-v mydir:/opt/oracle/scripts/setup`), and a user volume mounted there
would hide our scripts.

### "faststart" CI variant (implemented, `../faststart/`)

Measured (build 5, the regular image): of the ~8.5-9 min container start,
`dbca`'s own restore+completion machinery accounts for ~7:15 (RMAN restore
2:09, instance start 2:06, "Completing Database Creation" 2:53, post-config
~7s) - `datapatch` itself is down to ~10-20s and our own hooks (charset
conversion + PDB creation + SE2 settings) add ~1:15-1:40. So `dbca` itself,
not patching, is the dominant cost, and "Completing Database Creation" -
which re-runs `catcon`-based completion/validation SQL against the restored
template on *every* container start, even though the seed's content never
changes - is the biggest single piece of it.

The `faststart` extension (`../faststart/`) ships a *fully completed*
CDB$ROOT+PDB$SEED, already past all completion/validation SQL, as an xz
archive; at container start it just decompresses + `startup`s, no
`dbca -createDatabase` at all. First version deferred the character-set
conversion itself to container start too (reusing `10_seedCreatePDB.sh`
unchanged) - measured at ~1:17 min total container start, a huge win. But
that number turned out to be measuring a no-op: a separate bug (see below)
meant the archived database was already AL32UTF8 at build time, so the
"runtime conversion" never actually ran. Once fixed, the **real**
`INTERNAL_CONVERT US7ASCII -> AL32UTF8` cost was measured at **~5:40 min by
itself** - it scans the whole ~1.9GB CDB$ROOT+PDB$SEED dictionary (RU BLOB,
Java, Spatial - see "What's in the seed" above) column by column, even
though the actual content is pure ASCII needing no byte remapping. That
swallowed almost all of the time faststart otherwise saves.

Fix: since only two character sets are ever needed in practice
(AL32UTF8, WE8ISO8859P15 - both ASSET and cargo need a working faststart
image), convert both once at build time instead (see "Build sequencing"
above) and ship both fully-completed PDBs in the archive. At container
start, `startFaststart.sh` just drops the unwanted variant
(`DROP PLUGGABLE DATABASE ... INCLUDING DATAFILES`) and renames the kept
one to `$ORACLE_PDB` (`ALTER PLUGGABLE DATABASE ... RENAME GLOBAL_NAME`) -
both cheap, mostly-metadata operations, seconds not minutes.

**Final measured result, both variants verified end-to-end (2026-09-20),
with `tar|xz` packaging:** decompress 54s, instance start 34s, variant
selection (drop+rename) 5s, remaining hooks 3s - **~1:38 min total**, vs.
~8-9 min for the regular image (~5.5x faster).

**After switching to solid-mode 7zzs packaging** (see "Compression note"
below - this actually shipped, not just measured in isolation): decompress
dropped from 54s to **4s** (~13x faster just for that step), total
**~49s** - a further ~2x on top of the above, ~10-11x faster than the
regular image overall. Both `ORACLE_CHARACTERSET=AL32UTF8` (default) and
`WE8ISO8859P15` re-verified working end-to-end on the 7zzs-packaged image
(correct `NLS_CHARACTERSET`, correct `$ORACLE_PDB` name, correct PDBs in
`v$pdbs`).

**Image size, after also fixing the whiteout problem** (2026-09-20): the
final stage used to `FROM ${BASE_IMAGE}` (the patched+seeded `-ext` image,
1.1GB regenerated seed template + ~250MB sqlpatch zips included) and `rm`
what it didn't need - which only whites those files out, since `rm` in a
later layer can't shrink bytes physically present in an inherited,
already-published lower layer (confirmed: image size didn't budge with
that approach). Fixed the same way `../patching/Dockerfile` fixes the
analogous problem for its own final stage: the faststart final stage now
starts `FROM ${BASE_IMAGE_LEAN}` (`oracle/database:19.32.0.0-se2-base` -
the pre-patching, pre-seed sibling, confirmed to still exist locally and
verified to be missing only 8 patching-specific ENV vars that nothing
this image runs actually references) instead, and `COPY --from=builder`
pulls in the builder stage's *already-slimmed* `$ORACLE_BASE` (the
template/sqlpatch/createDB.sh removal now happens inside the builder
stage itself, right after the archive is built) - `COPY --from=<stage>`
copies that stage's resolved filesystem view, not raw layers, so this
actually drops the bytes instead of just hiding them. Also re-runs
`orainstRoot.sh`/`root.sh` after the copy, mirroring what the patching
Dockerfile does for the identical "recopy a patched ORACLE_HOME onto a
pristine base" operation. Result: **8.82GB**, down from 10.1GB (7zzs
packaging alone, whiteout still present) and 10.8GB (original `tar|xz`
version) - smaller than `-ext` itself (9.4GB) despite carrying a complete
689MB prebuilt database, since it no longer carries the 1.1GB+250MB it
doesn't need. Both character-set variants re-verified working end-to-end
on this rebuilt image too.

Bugs found and fixed along the way (all by actually building and running
the image, not by inspection):
- `buildFaststart.sh` calls `createDB.sh` directly, bypassing
  `runOracle.sh`'s own `ORACLE_CHARACTERSET=${ORACLE_CHARACTERSET:-AL32UTF8}`
  default - left unset, dbca converted to AL32UTF8 **at build time**,
  silently defeating the whole "convert at container start" design (the bug
  behind the false ~1:17 min measurement above). Fixed by explicitly
  exporting `ORACLE_CHARACTERSET=US7ASCII` before calling `createDB.sh`.
- Redo log shrink (add 3x50M groups, drop the original 3x200M ones): a
  `tr -d '[:space:]'` meant to strip whitespace from a multi-row SQL result
  also ate the newlines, collapsing 3 group numbers into one bogus
  concatenated value - silently left all 3 old logs undropped. Fixed with
  `tr -d ' \t\r'` (newlines preserved).
- The retry loop for dropping a redo log group only *waited* on failure -
  on an idle, freshly created database nothing triggers a log switch on its
  own, so a group that happened to still be CURRENT would never become
  droppable no matter how long the loop waited. Fixed by actively issuing
  `ALTER SYSTEM SWITCH LOGFILE` on every failed attempt.
- Deleting old redo log files (`DROP LOGFILE GROUP` doesn't delete the OS
  file) was unconditional on the originally-captured file list, regardless
  of whether that specific group's drop actually succeeded - deleted a file
  the database still referenced as an active online log, crashing the
  instance with `ORA-00313`/`ORA-00312` on the next `OPEN`. Fixed by only
  deleting a group's file immediately after confirming its `DROP` succeeded.
- `ALTER SYSTEM ENABLE RESTRICTED SESSION` only blocks *new* connections -
  `INTERNAL_CONVERT` itself additionally requires *zero* other sessions
  connected at all (`ORA-12721`), and dbca/createDB.sh can leave a
  lingering session behind for a moment right after returning control.
  Fixed by killing every non-background, non-self session before each
  conversion attempt, retrying a few times if `ORA-12721` still shows up.
- Plugging the unplugged ISO-variant PDB back in (`CREATE PLUGGABLE
  DATABASE ... USING '<xml>' NOCOPY`) failed with `ORA-27038: created file
  already exists` / `ORA-01119` - `UNPLUG` doesn't preserve temp files (no
  persistent data in them), so `PLUG IN` always tries to create a fresh
  one, but the PDB's own old tempfile is still physically sitting at that
  exact path (its subdirectory was deliberately left untouched by the
  snapshot/restore). Fixed by adding `TEMPFILE REUSE` to the `CREATE
  PLUGGABLE DATABASE ... USING` statement.
- `ALTER PLUGGABLE DATABASE ... RENAME GLOBAL_NAME` failed with
  `ORA-65045: pluggable database not in a restricted mode` when the PDB
  was simply open (not restricted) - the rename needs the PDB closed and
  reopened in `RESTRICTED` mode first, then closed and reopened normally
  afterward to make it usable again. Fixed by adding that CLOSE/OPEN
  RESTRICTED/rename/CLOSE/OPEN bounce (see the code block below).
- A `sql()` helper used for both DDL (wanted `FEEDBACK ON`, to log
  "Database altered." confirmations) and a plain `SELECT` into a bash
  array left `FEEDBACK ON` for the latter too, so a leaked "N rows
  selected" footer line got parsed as if it were a redo group number,
  breaking the shrink step's arithmetic (`value too great for base`).
  Fixed by explicitly overriding `SET FEEDBACK OFF` for that one query,
  plus a `^[0-9]+:` filter as a second line of defense.

The trade-off: skipping `dbca -createDatabase` also skips the step that
currently keeps `ORACLE_SID` runtime-configurable (dbca generates fresh
SID-specific control files/redo/spfile from the template on every create).
A fully pre-created CDB bakes the SID in at build time - the same trade-off
`database/free`'s `ORACLE_SID=FREE` and its fixed `AL32UTF8` charset make
(see "Character sets" above). Renaming afterwards (`DBNEWID`/`nid`) rewrites
every datafile header and regenerates redo - likely costs more than the
`dbca` overhead it would replace, and is more fragile than the cheap
metadata-only `INTERNAL_CONVERT`.

Compression note - **implemented** (2026-09-20): the archive is now a
solid-mode `7zzs` archive, not `tar|xz`. Backed by actual measurements on
the full, correct content set (CDB$ROOT+PDB$SEED, ~3.7GB uncompressed -
bigger than earlier assumed - plus both ~1.5GB customer PDBs, ~6.9GB
uncompressed total):

- **Two separate archives** (root+seed duplicated into each, one PDB per
  archive) - the "obvious" alternative to shipping one combined archive -
  came out *larger* overall: 1.1G (root+seed+PDBUTF8) + 819M
  (root+seed+PDBISO) = **1.92G total**, worse than a single combined `xz`
  archive (1.4G), because root+seed's ~3.7GB gets compressed twice
  instead of once. Ruled out.
- `xz -6` gets **zero** cross-copy deduplication between the two customer
  PDBs - compressed separately (315M + 313M) or together (628M) comes out
  identical either way, because its default 8MiB dictionary can't span
  the ~1.5GB distance between the copies.
- A **solid-mode 7z archive of everything together** (root+seed + both
  PDBs, one archive) came out at **685M** - less than half the 1.4G `xz`
  baseline, and the earlier worry that per-block SCNs/checksums would
  defeat deduplication between the two independently-created PDBs turned
  out to be unfounded (most of each PDB's content is static dictionary
  data - Java/Spatial/RU BLOB - that's byte-identical between the two).

**Decompression speed - resolved, measured end-to-end in the real image**
(a host-side-only comparison had been unreliable earlier - see git history
- some benchmark output went to a tmpfs-backed `/tmp` instead of real
disk, giving misleadingly large numbers either way; this is the real,
final, in-container result that superseded it): decompressing the archive
dropped from **54s** (`tar|xz`) to **4s** (`7zzs x`) - both variants
re-verified working correctly afterward. `7zzs` is the official 7-Zip
project's single-file, fully static Linux binary
(`github.com/ip7z/7zip` releases - confirmed with `ldd`/`file`, no shared-
library dependencies at all) - the same binary gvenzl/oci-oracle-free uses
for the identical purpose. A distro `p7zip` package isn't an option
(not in Oracle Linux's default repos, would need EPEL), and a dynamically-
linked `7z` copied in from a non-Oracle-Linux host fails here with a
glibc/libstdc++ ABI mismatch (`CXXABI_1.3.15' not found`) - confirmed by
testing, not assumed. See the `Dockerfile`'s `sevenzip` build stage for
the download+checksum-pinned install (`SEVENZIP_VERSION`/
`SEVENZIP_SHA256` build args - no official checksum file is published
upstream, so the hash is computed once per version bump and hardcoded).

`startFaststart.sh`'s actual variant-selection logic (implemented) - the
rename requires the PDB to be open in RESTRICTED mode first, a plain OPEN
isn't enough (`ORA-65045`, caught by testing):

    -- both PDBUTF8 and PDBISO auto-open via their build-time SAVE STATE
    ALTER SESSION SET "_oracle_script" = TRUE;
    ALTER PLUGGABLE DATABASE <unwanted> CLOSE IMMEDIATE;
    DROP PLUGGABLE DATABASE <unwanted> INCLUDING DATAFILES;
    ALTER PLUGGABLE DATABASE <kept> CLOSE IMMEDIATE;
    ALTER PLUGGABLE DATABASE <kept> OPEN RESTRICTED;
    ALTER PLUGGABLE DATABASE <kept> RENAME GLOBAL_NAME TO <ORACLE_PDB>;
    ALTER PLUGGABLE DATABASE <ORACLE_PDB> CLOSE IMMEDIATE;
    ALTER PLUGGABLE DATABASE <ORACLE_PDB> OPEN;
    ALTER PLUGGABLE DATABASE <ORACLE_PDB> SAVE STATE;
    ALTER SYSTEM REGISTER;  -- immediate listener registration under the new name

`ORACLE_CHARACTERSET` therefore stays runtime-configurable in the
faststart image too, but restricted to exactly `AL32UTF8` (default) or
`WE8ISO8859P15` - the two variants actually shipped; anything else needs
the regular (non-faststart) image.

`RENAME GLOBAL_NAME` is a lightweight, standard, PDB-scoped dictionary
operation (comparable in cost to the character-set conversion) - NOT the
same class of operation as `DBNEWID`/`nid`, which is CDB/instance-wide and
rewrites every datafile header plus regenerates redo. This makes
`$ORACLE_PDB` freely choosable even in a faststart image, at effectively no
extra image size (thanks to the shared-source compression above covering
both PDB variants almost for free).

What remains fixed either way: the CDB's own identity (`ORACLE_SID`/
`DB_NAME`/`DB_UNIQUE_NAME`), since no `dbca -createDatabase` runs to
generate fresh instance-level artifacts (controlfiles, redo, spfile).

Checked against real ZEDAS deployment templates (2026-09-20,
`docker_deploy_stacks/templates/`) - the answer is product-dependent, not
universal:

- cargo/longhaultraffic use `jdbc:oracle:thin:@//host:port/<service>` -
  service-name (EZCONNECT) connections, which go through the PDB's service
  name (`$ORACLE_PDB`, see `createDB.sh`'s `setupTnsnames`) and never
  reference the CDB's SID at all. For this style, a fixed CDB identity is
  irrelevant - the dual-PDB-plus-rename design above is a clean win, no
  compromise.
- ASSET and Shunting (`asset344/.env.j2`: `DB_CONNECTION_URL=jdbc:oracle:
  thin:@${DB_HOST}:${DB_PORT}:${DB_SID}`; `shunting_4.3.0`: "only this is
  allowed: jdbc:oracle:thin:@[HOST][:PORT]:SID") use the *old* colon-form
  SID connect descriptor. That format always lands in CDB$ROOT, not a
  specific PDB - there is no PDB-level routing in it at all - which strongly
  implies these deployments are **non-CDB** (`CONTAINER_DATABASE=false`,
  same mode this image already supports). For non-CDB, there is no PDB to
  rename: the database's own identity (SID/DB_NAME) *is* what the
  connection targets, and fixing it would need the expensive `DBNEWID`-class
  rename - which likely erases the time saved by going faststart in the
  first place.

So: viable as a drop-in, no-compromise fast-start mode for CDB/PDB-style
consumers (cargo/longhaultraffic-like), but not a solution for ASSET/
Shunting as they connect *today* (the old SID connect descriptor) without
also solving CDB-level identity rename.

Important correction: the real dividing line is the **connect string
format**, not CDB-vs-non-CDB architecture. Service-name (EZCONNECT)
connections have been the general-purpose, recommended Oracle connect
method since 9i, entirely independent of multitenant - a plain non-CDB
database registers its own default service (`service_names` parameter,
normally = `db_unique_name`) and supports `DBMS_SERVICE.CREATE_SERVICE`
for additional aliases exactly like a PDB does (see above). So *if*
ASSET/Shunting migrate their connect strings from the old
`host:port:SID` format to `//host:port/service` - independent of any
future CDB/PDB migration - the additional-service-name alias trick
becomes available for them too, and a fixed-identity faststart image
would then work there as well. Today, with the SID-format connect
string still in use, it doesn't; this stays a CI/throwaway-only trade-off
for products still on that format.

Conclusion: worth building as a *separate*, fixed-SID image for CI/throwaway
containers (exactly the use case gvenzl's `-faststart` and Oracle's own
`prebuiltdb` extension - see `../prebuiltdb/README.md` - are meant for), not
as a replacement for this general-purpose image, which needs `ORACLE_SID` to
stay a runtime choice. Not implemented; noted here for later.

### Turning it off

`REGENERATE_SEED=true` is the default of the `seedgen` stage's build arg.
`false` makes the stage a no-op: stock seed, datapatch at first start,
image otherwise identical to before this change.

`buildContainerImage.sh -p` does **not** forward its `-o` options to the
extension build (they carry `BASE_IMAGE`/`INSTALL_FILE_1` for the base
build and would clash with the extension's own `--build-arg BASE_IMAGE`).
Use the `PATCHING_BUILD_OPTS` environment variable instead:

    PATCHING_BUILD_OPTS="--build-arg REGENERATE_SEED=false" \
      ./buildContainerImage.sh -v 19.3.0 -s -p -t oracle/database:19.32.0.0-se2

or, when calling the extension build directly:

    ../extensions/buildExtensions.sh -x patching -v 19.3.0 \
      -b oracle/database:19.32.0.0-se2 -t oracle/database:19.32.0.0-se2-ext \
      -o '--build-arg REGENERATE_SEED=false'

In CI this is the `regenerate_seed` workflow input (see `CI.md`).

### Build-time requirements

- **Time**: the stage adds ~40 min (measured: dbca create incl. datapatch
  32 min, verification + undo/temp shrink 5 min, clone template 2 min,
  delete/cleanup 1 min) - the datapatch minutes move from every
  container's first start into the one image build.
- **Memory**: the throw-away CDB uses the `totalMemory=2048` from
  `dbca.rsp.tmpl`; the build host needs ~3 GB free RAM.
- **Disk**: ~6 GB transient in the build container (datafiles + template)
  on top of the normal patching build; freed again within the stage.
- **/dev/shm**: not needed. The response file uses ASMM
  (`automaticMemoryManagement=FALSE`, `sga_target`), which uses SysV shared
  memory, not `/dev/shm`. The container-runtime default of 64 MB is fine
  (Oracle's own `prebuiltdb` extension runs dbca inside `docker build` the
  same way). AMM/`memory_target` would need `--shm-size` and is not used.
- Runs as `oracle` inside a `RUN` step; `/bin/sh -c` (bash) is PID 1 there
  and reaps the detached Oracle background processes - unlike `sleep` as PID
  1 in an interactive `podman run ... sleep infinity`, which produced
  zombies and an ORA-00600 [ksb_shut_detached_process3] on shutdown during
  the manual experiment (needed `--init` there).

### Verifying an image

    docker run --rm --entrypoint bash <image> -c '
      grep -E "^(templateName|numberOfPDBs)=" $ORACLE_BASE/scripts/base/dbca.rsp.tmpl
      ls -l $ORACLE_HOME/assistants/dbca/templates/
      cat $ORACLE_HOME/assistants/dbca/templates/General_Purpose_*.README'

Expected: `templateName=General_Purpose_<RU>.dbc`, `numberOfPDBs=0`, no
`Seed_Database.dfb`/`General_Purpose.dbc`, and the README listing the same
patches as `opatch lspatches`. The CI workflow does exactly this check in
its "Verify seed template" step before pushing.

After a container start, `cdb_registry_sqlpatch` shows only the rows the
template was created with (their `action_time` predates the container),
`v$pdbs` shows PDB$SEED and `$ORACLE_PDB` (READ WRITE), and the sqlpatch
invocation logs under `/opt/oracle/cfgtoollogs/sqlpatch/` are ~10 s each.

### Things to keep in mind

- **Existing datafiles** (a volume created by an older image) are
  unaffected: `runDatapatch.sh` still compares `.lspatches` and runs
  datapatch on them at start, exactly as before. Only *new* databases benefit.
- **Next RU**: rebuild the image with the new RU/DPBP in `patches/` - the
  template is regenerated from scratch every build and renamed
  (`General_Purpose_1933`, ...). Nothing to maintain by hand.
- **Character set**: freely selectable via `ORACLE_CHARACTERSET` as with the
  stock image (tested: WE8ISO8859P15 and AL32UTF8) - see "Character sets"
  above for why the template is US7ASCII and what the hook does.
- **Sept 2026 MRP 39971265** is not part of this build (decided as not
  needed); adding it to `one_offs/` would automatically flow into the seed.
