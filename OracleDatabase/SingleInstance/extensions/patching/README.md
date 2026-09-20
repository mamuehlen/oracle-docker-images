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

### Character sets: the seed is US7ASCII, the setup hook converts it

Finding (2026-09-20): dbca does **not** convert the character set of a CDB
clone template. With `ORACLE_CHARACTERSET=WE8ISO8859P15` it only warns

    [WARNING] [DBT-11153] Character set specified (WE8ISO8859P15) is different from that of the character set (AL32UTF8) in the template.

and creates the database in the template's character set (tested; also with
the `<characterSet>` element removed from the `.dbc`). That would have left
the image AL32UTF8-only, while ASSET customers run WE8ISO8859P15 and
cargo/longhaultraffic AL32UTF8.

How does the *stock* seed manage it? Its alert log tells: `Database
Characterset is US7ASCII` - Oracle ships the seed in US7ASCII and dbca then
runs, after `ALTER DATABASE OPEN`,

    ALTER DATABASE CHARACTER SET INTERNAL_CONVERT WE8ISO8859P15;      -- CDB$ROOT
    ALTER PLUGGABLE DATABASE PDB$SEED CLOSE IMMEDIATE;
    ALTER PLUGGABLE DATABASE PDB$SEED OPEN RESTRICTED;
    ALTER DATABASE CHARACTER SET INTERNAL_CONVERT WE8ISO8859P15;      -- in PDB$SEED
    ALTER PLUGGABLE DATABASE PDB$SEED CLOSE IMMEDIATE;
    ALTER PLUGGABLE DATABASE PDB$SEED OPEN READ ONLY;

US7ASCII is a strict subset of every character set, so this is the
legitimate subset→superset direction; the dictionary is pure ASCII, so the
conversion is a metadata update (~1 s).

Therefore `regenerateSeedTemplate.sh` creates the throw-away CDB in
**US7ASCII** (the template is byte-identical in size either way), and the
extension's setup hook `scripts/extensions/setup/10_seedCreatePDB.sh` replays
exactly dbca's statement sequence at first container start whenever
`ORACLE_CHARACTERSET` differs from US7ASCII - validated against
`V$NLS_VALID_VALUES`, refused if the database isn't US7ASCII. The whole CDB
(root, PDB$SEED, PDB) ends up in `ORACLE_CHARACTERSET`, exactly like the
stock image. (`INTERNAL_CONVERT` is dbca-internal and not a user-facing
statement; we use it on the same kind of database, in the same state and
direction dbca does. Mixed character sets inside the CDB would also be
possible - Oracle allows them when CDB$ROOT is AL32UTF8 - but are not needed.)

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

Root must end up AL32UTF8 - not just preference, Oracle enforces it: a PDB
can only be opened/plugged into a root whose character set is a superset
of the PDB's. So `INTERNAL_CONVERT` order matters, since it only works
subset->superset:

1. build the throwaway CDB in US7ASCII (as today)
2. clone the WE8ISO8859P15-target PDB from the *still-US7ASCII* PDB$SEED
   first, then convert *that PDB* to WE8ISO8859P15 - valid (US7ASCII is a
   subset of WE8ISO8859P15)
3. only *afterwards* convert CDB$ROOT + PDB$SEED themselves to AL32UTF8
4. clone the AL32UTF8-target PDB from the now-AL32UTF8 PDB$SEED - no
   conversion needed, it already matches

Converting root to AL32UTF8 *before* branching off the ISO PDB would break
step 2 (AL32UTF8 -> WE8ISO8859P15 is the forbidden superset->subset
direction - the same DBT-11153 condition dbca itself warns about).

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

### Possible future step: a "faststart" CI variant (not implemented)

Measured (build 5): of the ~8.5-9 min container start, `dbca`'s own restore+
completion machinery accounts for ~7:15 (RMAN restore 2:09, instance start
2:06, "Completing Database Creation" 2:53, post-config ~7s) - `datapatch`
itself is down to ~10-20s and our own hooks (charset conversion + PDB
creation + SE2 settings) add ~1:15-1:40. So `dbca` itself, not patching, is
now the dominant cost, and "Completing Database Creation" - which re-runs
`catcon`-based completion/validation SQL against the restored template on
*every* container start, even though the seed's content never changes - is
the biggest single piece of it.

A `gvenzl/oci-oracle-free`-style `-faststart` variant (ship a *fully
completed* CDB$ROOT+PDB$SEED, already past all completion/validation SQL,
as a 7z archive; at container start just decompress + `startup`, no
`dbca -createDatabase` at all) would skip most of that phase. The character-
set trick (US7ASCII seed + `INTERNAL_CONVERT` before the customer PDB is
created) still works unchanged in that model - it's independent of whether
the seed is a dbca *template* (current approach) or an already-created CDB.

The trade-off: skipping `dbca -createDatabase` also skips the step that
currently keeps `ORACLE_SID` runtime-configurable (dbca generates fresh
SID-specific control files/redo/spfile from the template on every create).
A fully pre-created CDB bakes the SID in at build time - the same trade-off
`database/free`'s `ORACLE_SID=FREE` and its fixed `AL32UTF8` charset make
(see "Character sets" above). Renaming afterwards (`DBNEWID`/`nid`) rewrites
every datafile header and regenerates redo - likely costs more than the
`dbca` overhead it would replace, and is more fragile than the cheap
metadata-only `INTERNAL_CONVERT`.

Compression refinement: naively building the WE8ISO8859P15 and AL32UTF8
variants *independently* (two separate `dbca -createDatabase` runs) would
compress poorly together - two independently created databases differ at
almost every block (SCN, checksums, DBID-dependent headers), so a compressor
finds little to deduplicate. But `INTERNAL_CONVERT` is a metadata-only
operation (the underlying bytes are already valid 7-bit ASCII in every
target character set; only a handful of dictionary blocks - `PROPS$`'s
`NLS_CHARACTERSET` row, the controlfile header - actually change). So
deriving *both* variants from one identical US7ASCII snapshot (build it
once, convert one copy to each target character set) makes them byte-
identical except for that handful of blocks - a solid 7z archive (or a
binary delta of one against the other, e.g. `xdelta3`/`rdiff`) covering
both would compress close to "one copy plus a small diff", not "two full
copies". Applies at either granularity: a full CDB$ROOT+PDB$SEED archive,
or just a PDB-level archive (`INTERNAL_CONVERT` works the same way inside a
PDB context - `ALTER SESSION SET CONTAINER=<pdb>` first - which is in fact
exactly the second step of dbca's own stock-seed conversion sequence, see
"Character sets" above).

Refined design (2026-09-20, not implemented): ship *both* charset variants
as pre-created PDBs inside one faststart archive - one CDB$ROOT+PDB$SEED,
plus two fully-completed PDBs (one converted to WE8ISO8859P15, one to
AL32UTF8), all derived from the identical US7ASCII source above. At
container start: decompress, `startup`, `DROP PLUGGABLE DATABASE <unwanted>
INCLUDING DATAFILES` (cheap - just removes files + a dictionary entry), then
rename the kept one to `$ORACLE_PDB`:

    ALTER SESSION SET CONTAINER = <builtin_name>;
    ALTER PLUGGABLE DATABASE <builtin_name> CLOSE;
    ALTER PLUGGABLE DATABASE <builtin_name> OPEN RESTRICTED;
    ALTER PLUGGABLE DATABASE <builtin_name> RENAME GLOBAL_NAME TO <ORACLE_PDB>;

Even lighter for service-name (EZCONNECT, `//host:port/service`) consumers
specifically: skip the rename entirely and just register an *additional*
service name on the already-open PDB - no CLOSE/OPEN RESTRICTED bounce at
all, purely additive, can be done while the PDB is serving traffic:

    ALTER SESSION SET CONTAINER = <builtin_name>;
    EXEC DBMS_SERVICE.CREATE_SERVICE(service_name => '<ORACLE_PDB>', network_name => '<ORACLE_PDB>');
    EXEC DBMS_SERVICE.START_SERVICE('<ORACLE_PDB>');

This only helps service-name consumers, though - see the SID-vs-service
split below.

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
