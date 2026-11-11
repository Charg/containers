# AGENTS.md

Container images published to `ghcr.io/charg/containers/<name>`, signed keylessly with cosign. Sibling of
the `Charg/charts` repo (Helm charts); this repo holds only images and shares its conventions.

## Ground rules

- **The toolchain is the nix flake.** Run everything inside `nix develop`, or one-shot as
  `nix develop -c just <recipe>`. Never install tools ad hoc or pin a tool version in a script
  or workflow; bump tools with `nix flake update` (a `flake.lock` change).
- **`just` is the only interface.** Each recipe is a one-line shim over a script in `hack/`.
  CI calls the same recipes a developer runs locally. New behaviour goes in `hack/`, then gets
  a recipe, then CI calls the recipe. No logic in workflow YAML beyond setup and secrets.
- **`hack/` scripts** are bash, start with `source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"`
  (which sets `set -euo pipefail` and holds the shared helpers), and must succeed on a checkout
  with no images. Call buildx through the `buildx` helper, not `docker buildx`.
- **Fail closed when publishing.** Anything short of a definitive registry answer aborts the
  run rather than guessing. Only `just plan` decides what gets published.
- Run `just lint` before committing.

## Layout

```
images/<name>/Dockerfile   upstream version in the first `ARG <NAME>_VERSION=` before FROM, its commit in
                           `ARG <NAME>_COMMIT=` right after; base images and `# syntax=` pinned by digest
images/<name>/test.sh      smoke test: `test.sh <image>`, runs it and asserts it serves; exit non-zero on failure
hack/                      the scripts behind every recipe; tools.sh holds the shared helpers
.github/workflows/         ci.yaml (PRs: lint, check and cross-build changed images), release.yaml (main: plan, publish)
.github/renovate.json5     bumps upstream version ARGs, base-image digests, actions, flake.lock
```

The image name is the directory name. The published tags are the upstream version
(`anki-sync-server:26.09.4`, moves on rebuilds) and `<version>-<first 12 of image_inputs>`
(immutable, never overwritten), never a repo-level SemVer.

## Recipes

```bash
just lint                # shellcheck, hadolint, actionlint, yamllint
just build <name>        # host platform, loaded as localhost/<name>:dev
just test <name>         # run images/<name>/test.sh against localhost/<name>:dev
just scan <name>         # trivy on localhost/<name>:dev; fails on fixable HIGH/CRITICAL
just check <name>        # build + test + scan (what CI runs per image)
just build-all <name>    # cross-build linux/amd64 and linux/arm64, no export
just changed [base]      # images touched since base (hack/, flake, workflows = all)
just plan                # which images need publishing (queries GHCR, fails closed)
just publish <name>      # CI only: push, sign, verify, check public
just repro [name]        # rebuild published images from scratch, require identical digests (amd64)
```

## How publishing works

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
- Anything that changes the bytes built from unchanged inputs (a new build flag in `publish.sh`)
  bumps `BUILD_SCHEME`, which republishes every image.

Builders compile natively on the build host and cross-compile for the target (`--platform=$BUILDPLATFORM`);
don't rely on QEMU, it's far too slow for source builds.

## Adding an image

1. Create `images/<name>/` with a `Dockerfile` (prefer upstream's own) and an executable
   `test.sh`. Run as non-root; set OCI labels including `org.opencontainers.image.description`.
2. Put `# renovate: datasource=... depName=...` on the line above the version ARG, and the
   `<NAME>_COMMIT` ARG on the line after it; the generic regex manager in
   `.github/renovate.json5` bumps both. Add a `packageRules` entry
   if the upstream's versioning needs it.
3. Add a row to the image table in `README.md`.
4. `just lint && just check <name> && just build-all <name>` must pass.

## Gotchas

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

## Commits

Conventional commits, scoped by image: `feat(anki-sync-server): ...`, `ci: ...`, `chore: ...`.
Work on a branch and open a PR; don't commit to `main` directly.
