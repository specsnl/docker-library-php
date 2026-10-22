# specsnl/docker-library-php

A fork of [docker-library/php](https://github.com/docker-library/php) that builds our own PHP images and publishes them
to GHCR as `ghcr.io/specsnl/php`.

The official `php` image only ships the latest patch of each branch, and only once its pipeline gets to it. This fork
builds an **exact** PHP version (e.g. `8.4.13`) on demand, from upstream's own templates, as a multi-arch image for
`linux/amd64` and `linux/arm64`.

> GitHub shows this file on the repository home page in place of the root `README.md`. The root README belongs to
> upstream; leave it alone (see [the fork rule](#the-fork-rule-only-add-files)).

## Running a build

Run the **Build** workflow ([`build.yml`](workflows/build.yml)) from Actions → Build → Run workflow. It is only ever
started by hand.

| Input                  | Default               | Meaning                                                                                                                    |
|------------------------|-----------------------|----------------------------------------------------------------------------------------------------------------------------|
| `php_version`          | (required)            | Exact PHP version, e.g. `8.4.13`. Pre-releases like `8.6.0RC1` need `prerelease` in `build-config.json` (see below).       |
| `variants`             | `build-config.json`'s | Comma-separated override, e.g. `cli` or `cli,zts`.                                                                         |
| `base`                 | newest Debian suite   | Suite to build on, e.g. `bookworm`. The default is the first Debian suite `versions.json` lists for the branch.            |
| `update_floating_tags` | `false`               | Also move the floating tags (see below). Refused together with a `base` override.                                          |
| `upstream_ref`         | this branch           | A docker-library/php ref (branch, tag or SHA) whose templates and `versions.json` to build from, without merging it first. |

The jobs run in this order:

1. **prepare** pins `versions.json` to the requested version
   ([`scripts/pin-version.sh`](../scripts/pin-version.sh)), renders that branch's Dockerfiles, and builds the job
   matrix ([`scripts/select-matrix.sh`](../scripts/select-matrix.sh)). Nothing it changes is committed.
2. **build** builds each variant on a native runner per platform and pushes it **by digest only**, with provenance and
   SBOM attestations.
3. **smoke-test** runs [`scripts/smoke-test.sh`](../scripts/smoke-test.sh) against each pushed digest: `php -v`,
   `php -m`, plus `php-fpm -t` for `fpm` and `apache2ctl -t` for `apache`. It also fails an image whose
   `PHP_VERSION` differs from `php_version`, or whose `php -m` lacks any of `build-config.json`'s
   `required_extensions`.
4. **merge** combines the platforms of each variant into one manifest list and applies the tags
   ([`scripts/compute-tags.sh`](../scripts/compute-tags.sh)).

Tags are only applied once every digest has passed the smoke test, so a run that fails halfway never leaves a broken
tag behind.

### Tag scheme

For `php_version=8.4.13`, variant `fpm`, suite `trixie`:

| Tag                                     | Applied                               |
|-----------------------------------------|---------------------------------------|
| `ghcr.io/specsnl/php:8.4.13-fpm-trixie` | always                                |
| `ghcr.io/specsnl/php:8.4-fpm-trixie`    | only with `update_floating_tags`      |
| `ghcr.io/specsnl/php:8-fpm`             | only with `update_floating_tags`      |
| `ghcr.io/specsnl/php:fpm`               | only with `update_floating_tags`      |
| `ghcr.io/specsnl/php:latest`            | only with `update_floating_tags`, cli |

**Why floating tags are opt-in:** a run that rebuilds an older patch release (say `8.4.12` after `8.4.13` is out) must
not move `8.4-fpm-trixie` backwards. The input moves all floating tags at once, so only turn it on when building the
newest patch of the **newest** branch: on the newest `8.3` patch it would also point `8-fpm`, `fpm` and `latest` back
at 8.3.

The suite-less tags (`8-fpm`, `fpm`, `latest`) follow the default suite, which is why the workflow refuses
`update_floating_tags` together with a `base` override. Pre-releases never move the floating tags, whatever the input
says: `8.6.0RC1` with `fpm` on `trixie` only gets `ghcr.io/specsnl/php:8.6.0RC1-fpm-trixie`.

## The fork rule: only add files

Upstream commits the rendered `<branch>/<suite>/<variant>/Dockerfile` files, `versions.json`, the templates and its own
workflows. Any edit to one of those conflicts on the next upstream merge. So the fork **only adds files**, and never
modifies a file upstream commits:

- `.github/README.md`, `.github/dependabot.yml`
- `.github/workflows/build.yml`, `.github/workflows/test.yml`
- `build-config.json`, `compose.yml`, `Taskfile.dist.yml`, `.hadolint.yml`
- `scripts/`, `test/`

Leave the unused Windows, Alpine and ZTS templates and Dockerfiles in place: deleting them conflicts just the same, and
keeping them costs nothing. Version pinning and template rendering happen inside the workflow run, never in a commit.

**Deliberate exceptions** (files upstream owns that the fork modifies): none. If one is ever unavoidable, keep the
patch as small as possible and list it here, with the reason.

### Upstream workflows

Upstream's workflows are left unedited. Each one either runs as-is or is switched off in the repository settings:

- **`GitHub CI`** ([`ci.yml`](workflows/ci.yml)) is **disabled** in the repository's Actions settings. It builds
  upstream's whole image matrix (every version, Alpine and ZTS included) on every push and pull request, and nothing in
  the fork's pipeline relies on it. To run it once anyway, re-enable it under Actions → GitHub CI. If upstream renames
  the file, the renamed workflow shows up enabled and needs disabling again. (Editing its triggers was tried and
  dropped in [#18](https://github.com/specsnl/docker-library-php/pull/18).)
- **`Verify Templating`** ([`verify-templating.yml`](workflows/verify-templating.yml)) stays **enabled**. It is one
  quick job, and it catches an upstream sync whose rendered files don't match the templates. It runs twice per pull
  request (once for `push`, once for `pull_request`); that is accepted rather than fixed by editing an upstream file.
- If upstream adds a workflow that should not run here, disable it the same way, and add it to `exclude-paths` in
  [`dependabot.yml`](dependabot.yml) in the same merge.

## Configuration: `build-config.json`

[`build-config.json`](../build-config.json) sets what a run builds when the inputs don't say otherwise:

```json
{
  "families": { "debian": true, "alpine": false },
  "variants": ["cli", "fpm", "apache"],
  "platforms": ["linux/amd64", "linux/arm64"],
  "prerelease": false,
  "required_extensions": ["Core", "ctype", "curl", "...", "Zend OPcache", "zlib"]
}
```

- **`families`**: which suite families a `base` may come from. Windows belongs to no family and is never built.
- **`variants`**: the variants a run builds when the `variants` input is empty.
- **`platforms`**: the platforms each variant is built for. Each needs a native GitHub-hosted runner, so only
  `linux/amd64` and `linux/arm64` are supported.
- **`prerelease`**: whether `php_version` may be a pre-release (`RC`, `alpha` or `beta`). With `false`, the prepare
  job rejects one before it fetches anything.
- **`required_extensions`**: the extensions every image must have; the smoke test fails an image whose `php -m` lacks
  any of them. Names are compared case-insensitively, and extensions beyond the list are fine. It holds what the stock
  image lists on every branch from 8.2 on, so an extension only some branches have does not belong here: neither 8.5's
  new `lexbor` and `uri`, nor `mbstring`, which upstream stopped building in from 8.6 on (it came with PEAR/PECL).

**Building a pre-release:** set `"prerelease": true`, then run the workflow with e.g. `php_version: 8.6.0RC1`. Note
that:

- Upstream keys pre-releases as `<branch>-rc` in `versions.json`, with Dockerfiles under `<branch>-rc/`. That entry
  is `null` whenever php.net has no pre-release of the branch, so merge upstream (or pass `upstream_ref`) first.
- The tarball and checksum come from php.net's
  [pre-release builds](https://www.php.net/pre-release-builds.php?format=json), which list only the newest
  pre-release of each branch. Older pre-releases can't be built; the error names the ones that can.
- A pre-release only ever gets its exact tag (see [Tag scheme](#tag-scheme)).

**Turning ZTS back on:** add `"zts"` to `variants`, or pass `variants: cli,zts` for a single run. Upstream dropped the
separate `zts` variant from PHP 8.6 on (every 8.6+ image is built with ZTS), so `zts` only exists for 8.5 and older.

**Turning Alpine back on:** set `"alpine": true` under `families`, then pass the suite as `base`, e.g.
`base: alpine3.24`. The default `base` stays the newest Debian suite. Alpine has no `apache` variant, so pass
`variants: cli,fpm` as well (or drop `apache` from `variants`). Since `base` is overridden, Alpine runs never move the
floating tags.

## Local checks

Only [Docker](https://docs.docker.com/get-docker/) and [Task](https://taskfile.dev) are needed on the host.

| Command         | What it runs                                                                                 |
|-----------------|----------------------------------------------------------------------------------------------|
| `task test`     | The bats suites in `test/`, in a container with no network access                            |
| `task checkall` | `shellcheck` over the scripts and tests, `hadolint` over `test/bats.Dockerfile`, then `test` |

Extra arguments go to bats, e.g. `task test -- --filter resolve_source`. The **Test** workflow
([`test.yml`](workflows/test.yml)) runs `task checkall` on pull requests and pushes to `master` that touch
`scripts/`, `test/` or the tooling around them.

The workflow logic (pinning, matrix, tags, smoke checks) lives in `scripts/` so it can be tested this way. **Any change
to `scripts/` comes with a matching case in `test/*.bats`.** The suite fakes `curl` and `docker`
([`test/helpers/bin/`](../test/helpers/bin)) and reads php.net responses from
[`test/fixtures/`](../test/fixtures), so a test that reaches for the network fails instead of passing by luck.

## Syncing with upstream

1. Add the upstream remote (once):

   ```sh
   git remote add upstream https://github.com/docker-library/php.git
   ```

2. Fetch and merge:

   ```sh
   git fetch upstream && git merge upstream/master
   ```

3. There should be no conflicts, because the fork only adds files. If one happens, a file that upstream also owns was
   modified. Move that change into one of the fork's own files instead of resolving the conflict in place.
4. Merge **before** building a new PHP minor (e.g. the first `8.6.x`), a new pre-release or on a new Debian suite.
   `pin-version.sh` and `select-matrix.sh` only know the branches (and `<branch>-rc` entries) and suites in
   `versions.json`, and fail with `merge upstream docker-library/php first` for anything else.

To try a newer upstream without merging it, pass its ref as `upstream_ref`. The run lays upstream's tree over this
branch before pinning, which only works because the fork adds files and never changes upstream's.

If upstream adds or renames a workflow in the merge, handle it as described under
[Upstream workflows](#upstream-workflows).

## Known gotchas

- **No automatic base-image refresh.** An image is built once, on whatever `debian:<suite>-slim` was current at the
  time. To pick up Debian security updates, re-run the workflow with the same `php_version` (and
  `update_floating_tags` if the floating tags point at it). A scheduled check is tracked in
  [#14](https://github.com/specsnl/docker-library-php/issues/14).
- **Docker Hub rate limits.** The builds pull `debian:<suite>-slim` from Docker Hub, anonymously by default, which
  counts against the runner IP's limit. Set the `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` repository secrets to pull
  as an account instead; the build job logs in only when they are set.
- **GPG keyserver flakiness.** Upstream's Dockerfiles fetch the release managers' keys from `keyserver.ubuntu.com`,
  which fails now and then. Re-run the failed jobs. The template stays untouched (see
  [the fork rule](#the-fork-rule-only-add-files)).
- **Untagged versions pile up in GHCR.** Every push by digest, and every rebuild that moves a tag, leaves untagged
  package versions behind. Cleaning them up is tracked in [#12](https://github.com/specsnl/docker-library-php/issues/12).
- **Checking a second platform locally.** With Docker's containerd image store, `docker run --platform` on one
  platform after the other fails with `content digest ... not found`, because the first run only pulled its own
  layers. Pull each platform explicitly first: `docker pull --platform linux/arm64 <image>`.
