# AGENTS.md

<!-- BEGIN TEMPLATE: managed by Charg/template through `copier update`. Edit it there, not here. -->

## Toolchain

- **The toolchain is the nix flake.** Run everything inside `nix develop` (direnv loads it through
  `.envrc`), or one-shot as `nix develop -c just <recipe>`. Never install tools ad hoc or pin a tool
  version in a script or workflow: add it to `flake.nix`, bump it with `nix flake update`.
- **`just` is the only interface.** Recipes are one-line shims over scripts in `hack/`, and CI calls
  the same recipes a developer runs locally. New behaviour goes in `hack/`, then gets a recipe, then
  CI calls the recipe. No logic in workflow YAML beyond setup and secrets.
- **`hack/` scripts** are bash and start with `source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"`,
  which sets `set -euo pipefail` and holds the shared helpers (`log`, `die`, `require_tools`,
  `repo_files`).
- Run `just lint` before committing. The prek hook (`just install-hooks`) runs it on commit.
- Plans, tickets and throwaway output go in `.scratch/` (gitignored).

## GitHub Actions

- Workflows start with `permissions: {}` and grant each job only what it needs. Check out with
  `persist-credentials: false`.
- Pin every `uses:` to a full commit SHA with a version comment.
- After adding or bumping an action, regenerate `.github/workflows/actions.lock` with
  `gh actions-lock --no-narrow`. Without `--no-narrow` it rewrites SHA pins to tags, which zizmor's
  `unpinned-uses` audit rejects.
- Renovate policy (release age, automerge, nix lock maintenance) comes from the shared preset in
  `Charg/template` (`renovate/default.json5`). `.github/renovate.json5` holds only this repo's
  additions.

## Commits

- Conventional commits: `feat:`, `fix:`, `chore:`, `ci:`, `docs:`, `refactor:`, `test:`,
  optionally scoped (`feat(api): ...`).
- Work on a branch and open a PR. PRs squash-merge. Don't commit to `main` directly.
- Commit only when asked.

## Container images

- The docker CLI and buildx come from the flake and talk to the host's daemon.
- `just lint` runs hadolint over every `Dockerfile` and `Containerfile` (`hack/lint.d/container-images.sh`).
  Accept a finding for one line with a `# hadolint ignore=DLxxxx` comment and the reason, or for the
  repo in `.hadolint.yaml`.
- Pin base images by digest (`image:tag@sha256:...`). Renovate keeps the digests current and
  merges digest-only bumps without the release-age wait: they are how base-image CVE fixes arrive.

## Template

- Shared files (flake, justfile, `hack/tools.sh`, `hack/lint.sh`, `hack/lint.d/`, lint configs, CI,
  this section) come from `Charg/template`; the answers are in `.copier-answers.yml`, which is
  never edited by hand. Pull template changes with `copier update` and resolve any conflicts it
  leaves. Add a flavour with `copier update --data 'flavours=[...]'`, listing every flavour wanted.
- Projects extend the shared files freely (packages in `flake.nix`, recipes, lint steps; a new lint
  step can be its own script in `hack/lint.d/`);
  `copier update` merges template changes around those edits.
- Only the text between the TEMPLATE markers in this file belongs to the template. Project rules go
  under `## Project

Container images published to `ghcr.io/charg/containers/<name>`, signed keylessly with cosign.
Sibling of the `Charg/charts` repo (Helm charts); this repo holds only images and shares its
conventions.

- `hack/` scripts must succeed on a checkout with no images. Call buildx through the `buildx`
  helper in `hack/tools.sh`, not `docker buildx`.
- **Fail closed when publishing.** Anything short of a definitive registry answer aborts the
  run rather than guessing. Only `just plan` decides what gets published.
- Commits are scoped by image: `feat(anki-sync-server): ...`.

### Layout

```
images/<name>/Dockerfile   upstream version in the first `ARG <NAME>_VERSION=` before FROM, its commit in
                           `ARG <NAME>_COMMIT=` right after; base images and `# syntax=` pinned by digest
images/<name>/test.sh      smoke test: `test.sh <image>`, runs it and asserts it serves; exit non-zero on failure
hack/                      the scripts behind every recipe; tools.sh holds the shared helpers
.github/workflows/         ci.yaml (PRs: lint; per changed image, check on amd64 and cross-build arm64 in
                           parallel), release.yaml (main: plan, publish)
.github/renovate.json5     bumps upstream version ARGs, base-image digests, actions, flake.lock
```

The image name is the directory name. The published tags are the upstream version
(`anki-sync-server:26.09.4`, moves on rebuilds) and `<version>-<first 12 of image_inputs>`
(immutable, never overwritten), never a repo-level SemVer.

### Recipes

```bash
just lint                # every linter (hack/lint.sh, hack/lint.d/)
just build <name>        # host platform, loaded as localhost/<name>:dev
just test <name>         # run images/<name>/test.sh against localhost/<name>:dev
just scan <name>         # trivy on localhost/<name>:dev; fails on fixable HIGH/CRITICAL
just check <name>        # build + test + scan (what CI runs per image)
just build-all <name>    # cross-build linux/amd64 and linux/arm64, no export
just changed [base]      # images touched since base (hack/, flake, workflows = all)
just plan                # which images need publishing (queries GHCR, fails closed)
just publish <name>      # CI only: push, sign, verify, check public
just cache-mounts <import|export> <name> <arch> <dir>   # CI only: BuildKit cache mounts <-> host dir
just repro [name]        # rebuild published images from scratch, require identical digests (amd64)
```

### How publishing works

`plan.sh` publishes an image when `ghcr.io/charg/containers/<name>:<version>` is missing, or when the
`dev.charg.containers.inputs` index annotation on it doesn't match `image_inputs` (a hash of
`images/<name>/` except `test.sh`, plus `BUILD_SCHEME` and the pinned `BUILDKIT_IMAGE` from
`hack/tools.sh`). That's how base-image digest bumps (CVE fixes, via Renovate)
republish under the same tag. Editing anything in an image directory other than `test.sh`
republishes it on merge. `publish.sh` pushes both tags, signs the index, and attaches a signed
Trivy `vuln` attestation to each platform digest. If the immutable tag already exists, it re-points
the version tag at that (verified-signed) image instead of rebuilding.

No mutable references in a build: fetch upstream source by commit, not tag, and fail the build
if the tag no longer points at that commit.

Builds are reproducible: the same inputs give byte-identical platform images, and the weekly
`repro` workflow (`just repro`) proves it against the registry. What keeps them that way:
- BuildKit is pinned by digest in `hack/tools.sh`, and every build uses `SOURCE_DATE_EPOCH` from
  there with `rewrite-timestamp=true`.
- Build-stage apt installs use `--snapshot` with the snapshot.debian.org timestamp the builder
  image records in `/etc/apt/sources.list.d/debian.sources`, never the live archive.
- Where upstream's own build isn't deterministic, fix it with a patch in `images/<name>/patches/`,
  applied with `git apply` before building (see anki-sync-server). A patch that stops applying
  fails the build, so it gets dropped once upstream fixes the cause.
- Anything that changes the bytes built from unchanged inputs (a new build flag in `publish.sh`)
  bumps `BUILD_SCHEME`, which republishes every image.

CI caches two things in the Actions cache (free up to 10 GB per repo; past that the oldest entries
are evicted, which only costs speed): BuildKit's layer cache, one scope per image and platform, and
the contents of `RUN --mount=type=cache` mounts (cargo target dirs), which the layer cache doesn't
carry. Pull requests restore cache mounts (`just cache-mounts`) so a change above a compile step
recompiles only what changed; release.yaml saves them after a publish. Publish and repro builds
never restore cache mounts: they compile from a fresh builder.

Builders compile natively on the build host and cross-compile for the target (`--platform=$BUILDPLATFORM`);
don't rely on QEMU, it's far too slow for source builds.

### Adding an image

1. Create `images/<name>/` with a `Dockerfile` (prefer upstream's own) and an executable
   `test.sh`. Run as non-root; set OCI labels including `org.opencontainers.image.description`.
2. Put `# renovate: datasource=... depName=...` on the line above the version ARG, and the
   `<NAME>_COMMIT` ARG on the line after it; the generic regex manager in
   `.github/renovate.json5` bumps both. Add a `packageRules` entry
   if the upstream's versioning needs it.
3. Add a row to the image table in `README.md`.
4. `just lint && just check <name> && just build-all <name>` must pass.

### Gotchas

- Images publish under `containers/` and charts (Charg/charts) under `charts/`, so an image and a
  chart can share a name. Never publish to `ghcr.io/charg/<name>` directly.
- GHCR rejects uppercase path segments; the owner `Charg` is lowercased to `charg` in scripts.
- **Every published image must be public.** New packages have come out public with no manual
  step, apparently because the `org.opencontainers.image.source` annotation links them to this
  public repo. Keep that annotation. `publish.sh` checks with an anonymous pull and fails if it's
  denied; if that happens, set the package to public in its GitHub settings.
- Anonymous `just plan` aborts for an image that has never been published (GHCR answers 403,
  not 404). CI passes `GITHUB_TOKEN` with `packages: read`.
- This repo is public. No secrets, internal hostnames or private registry references in any file.
