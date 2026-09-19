# CI: Build and push via GitHub Actions

`.github/workflows/build-and-push.yml` builds any version/edition in this
repo and pushes the result to the internal registry
(`vsdock01.pcsoft.de:5000`), using a self-hosted runner on
`vazraddevdocker4` (same host as the registry, so pushes are fast and
don't hit the timeouts a remote push runs into).

## Trigger

Manual only (`workflow_dispatch`) - no automatic push/PR trigger, since
the runner's mounted docker socket is effectively root on the host.

Dispatch it either from the GitHub UI (Actions → "Build and push Oracle
DB image" → Run workflow → branch `zedas-patches`) or via the API:

```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/mamuehlen/oracle-docker-images/actions/workflows/build-and-push.yml/dispatches \
  -d @- <<'PAYLOAD'
{
  "ref": "zedas-patches",
  "inputs": { ... see examples below ... }
}
PAYLOAD
```

`$TOKEN` needs `repo` + `workflow` scopes and admin/write access to this
repo (it's a personal-namespace repo, so a collaborator token maxes out
at "Write" - use a token from the repo owner's own account, not a bot
account added as a collaborator).

**`patching` must be a real JSON boolean in the API payload
(`"patching": true`), not the string `"true"`.** It's declared as
`type: boolean` in the workflow. Sending it as a string was the first
version of this bug. The second, subtler version: even with a real
boolean, `${{ inputs.patching == 'true' && '-p' || '' }}` in the "Build
image" step is *itself* wrong - GitHub Actions expressions compare a
boolean and a string by converting both to numbers, `'true'` becomes
`NaN`, and `NaN != 1` (true's numeric form), so the comparison is
always false regardless of the input's actual value. Use the boolean
directly instead: `${{ inputs.patching && '-p' || '' }}`. Both versions
of this bug shipped an *unpatched* `19.32.0.0-se2` at least once each,
only caught by an independent `opatch lspatches` check on another host
after the push (see "Verifying a push" below) - the "Push to internal
registry" step's plain string interpolation (`[ "${{ inputs.patching }}"
= "true" ]`) doesn't have this problem, which is exactly what made the
second bug so confusing: the push step correctly went looking for the
`-ext` image while the build step had silently never built one.

## Inputs

| Input | Meaning |
|---|---|
| `version` | Version directory under `OracleDatabase/SingleInstance/dockerfiles/`, e.g. `19.3.0`, `23.26.0` |
| `edition_flag` | `-e` (EE), `-s` (SE2), `-x` (XE), `-f` (Free) |
| `patching` | `true` to also apply `extensions/patching` (RU/DPBP/OPatch on top of the base install) |
| `image_tag` | Local tag the image gets built as |
| `build_arg_overrides` | Optional extra `--build-arg ...` passthrough (rarely needed - see 23.26 example) |
| `fetch_map` | One `"zft/relative/path/file.zip repo/relative/dest/dir"` pair per line - see below |
| `push_tag` | Tag pushed to `vsdock01.pcsoft.de:5000` |
| `expected_patches` | Space-separated OPatch patch numbers that must be present before pushing is allowed (e.g. `"39472050 39657094"`) - **always set this when `patching=true`**, see "Verifying a push" below |

### `fetch_map`

The RU/DPBP/OPatch patches and the base installer/goldimage don't live
in the same repo directory (`dockerfiles/<version>/` vs
`extensions/patching/patches/{one_offs,release_update}/`), so each file
needs its own destination. `https://zft.zedas.com/download/` currently
has **no auth** on the nginx side (should be fixed - see below), so the
workflow's `-u` is a no-op placeholder for whenever that changes.

## Examples

### 19.3.0 SE2, patched to RU 19.32 (`oradb19c-zedas` equivalent)

```json
{
  "version": "19.3.0",
  "edition_flag": "-s",
  "patching": true,
  "image_tag": "oracle/database:19.32.0.0-se2",
  "build_arg_overrides": "",
  "fetch_map": "ora/Ora19/LINUX.X64_193000_db_home.zip OracleDatabase/SingleInstance/dockerfiles/19.3.0\nora/Ora19/patches/p6880880_190000_LINUX.zip OracleDatabase/SingleInstance/extensions/patching/patches/one_offs\nora/Ora19/patches/p39657094_1932000DBRU_Generic.zip OracleDatabase/SingleInstance/extensions/patching/patches/one_offs\nora/Ora19/patches/p39472050_190000_Linux-x86-64.zip OracleDatabase/SingleInstance/extensions/patching/patches/release_update",
  "push_tag": "oracle/database:19.32.0.0-se2",
  "expected_patches": "39472050 39657094"
}
```

To build a *different* RU later: swap the two `patches/` filenames and
patch numbers in `fetch_map` **and** `expected_patches` for the new
RU/DPBP zips (upload them to `zft.zedas.com` first, same
`Ora19/patches/` layout). OPatch (`p6880880`) rarely needs to change.

### 23.26.0 SE2 via the 23.26.3 Gold Image

The `23.26.0/Containerfile` on this branch already defaults
`INSTALL_FILE_1` and the version labels to 23.26.3 (see git log), so no
`build_arg_overrides` needed unless building a *different* Gold Image
release than what's currently the default:

```json
{
  "version": "23.26.0",
  "edition_flag": "-s",
  "patching": false,
  "image_tag": "oracle/database:23.26.3-se2",
  "build_arg_overrides": "",
  "fetch_map": "ora/Ora23.26/p39581612_230000_Linux-x86-64.zip OracleDatabase/SingleInstance/dockerfiles/23.26.0",
  "push_tag": "oracle/database:23.26.3-se2",
  "expected_patches": "39578879"
}
```

(`39578879` is the Gold Image's own baked-in Database RU - 26ai ships the RU as part of the install file itself rather than a separate patch step, but it's still a normal registered OPatch entry, so the same safety net applies.)

To build a future Gold Image release (e.g. 23.26.4 once that RU exists):
override the install file without touching the Containerfile:

```json
"build_arg_overrides": "--build-arg INSTALL_FILE_1=p<newpatch>_230000_Linux-x86-64.zip"
```

and point `fetch_map` at the new zip's location on zft.zedas.com.

## One-time host setup (already done on `vazraddevdocker4`)

- Self-hosted runner registered per the Confluence doc "Self-hosted
  GitHub Actions Runner (Docker)" (`git.zedas.com/zedas/docker`,
  `dockerfiles/github-runner/`).
- `vsdock01.pcsoft.de:5000` added to the host's Docker
  `insecure-registries` (that endpoint is plain HTTP on purpose, to
  bypass the Traefik proxy's 60s timeout in front of the HTTPS route).
- `REGISTRY_USER` / `REGISTRY_PASSWORD` GitHub repo secrets set (Nexus
  credentials for `vsdock01.pcsoft.de:5000`).
- `docker-ce` upgraded to 29.8.1+ on the host - 29.7.0 had a reproducible
  bug (`failed to register layer: openat dev/ptmx: no such file or
  directory`) pulling any Oracle Linux base image (both 8 and 9), fixed
  in this version.

## Verifying a push

The workflow has a built-in **"Verify patch level"** step: set
`expected_patches` and it runs `opatch lspatches` against the freshly
built image and fails the job (before anything gets pushed) if any
expected patch number is missing. This is the actual fix for the
`patching` bugs described above, not just documentation - **always set
`expected_patches` whenever you set `patching=true`**, and it's cheap
to set even when `patching=false` (see the 23.26 example).

That said, the check only proves the image the runner just built and
pushed has the right patches *at push time* - if you want to confirm
what's *actually sitting in the registry* right now (e.g. after a
manual push, or to double check months later), pull independently from
a host that was never involved in the build/push (a different
machine's local image cache can otherwise silently mask a bad push):

```bash
docker pull vsdock01.pcsoft.de:5000/oracle/database:<tag>
docker run --rm --entrypoint bash vsdock01.pcsoft.de:5000/oracle/database:<tag> \
  -c '$ORACLE_HOME/OPatch/opatch lspatches'
```

For a 19.x RU/DPBP build, expect to see the RU and DPBP patch numbers
from `fetch_map` in the output - if all you see is the base install's
original RU (e.g. `29517242;Database Release Update : 19.3.0.0.190416`
for a plain 19.3.0 base), the patching step didn't actually run.

## Known open item

`https://zft.zedas.com/download/` has no `auth_basic`/`auth_request` on
its nginx location - anyone who knows/guesses a file's URL can download
it without credentials, including these licensed Oracle installers.
Should be locked down (e.g. `auth_basic`) independently of this repo.
