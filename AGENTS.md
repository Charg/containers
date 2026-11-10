# AGENTS.md

Container images published to `ghcr.io/charg/<name>`, signed keylessly with cosign. Sibling of
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
images/<name>/Dockerfile   upstream version in the first `ARG <NAME>_VERSION=` before FROM; base images pinned by digest
images/<name>/test.sh      smoke test: `test.sh <image>`, runs it and asserts it serves; exit non-zero on failure
hack/                      the scripts behind every recipe; tools.sh holds the shared helpers
.github/workflows/         ci.yaml (PRs: lint, check and cross-build changed images), release.yaml (main: plan, publish)
.github/renovate.json5     bumps upstream version ARGs, base-image digests, actions, flake.lock
```

The image name is the directory name. The published tag is the upstream version
(`anki-sync-server:26.09.4`), never a repo-level SemVer.

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
```

## How publishing works

`plan.sh` publishes an image when `ghcr.io/charg/<name>:<version>` is missing, or when the
`dev.charg.containers.inputs` index annotation on it doesn't match `image_inputs` (a hash of
`images/<name>/` except `test.sh`). That's how base-image digest bumps (CVE fixes, via Renovate)
republish under the same tag. Editing anything in an image directory other than `test.sh`
republishes it on merge.

Builders compile natively on the build host and cross-compile for the target (`--platform=$BUILDPLATFORM`);
don't rely on QEMU, it's far too slow for source builds.

## Adding an image

1. Create `images/<name>/` with a `Dockerfile` (prefer upstream's own) and an executable
   `test.sh`. Run as non-root; set OCI labels including `org.opencontainers.image.description`.
2. Put `# renovate: datasource=... depName=...` on the line above the version ARG; the
   generic regex manager in `.github/renovate.json5` picks it up. Add a `packageRules` entry
   if the upstream's versioning needs it.
3. Add a row to the image table in `README.md`.
4. `just lint && just check <name> && just build-all <name>` must pass.

## Gotchas

- GHCR rejects uppercase path segments; the owner `Charg` is lowercased to `charg` in scripts.
- **Every published image must be public.** GHCR creates a new package as private and has no API
  to change that, so the first publish of a new image needs an admin to flip it to public once in
  the GitHub UI (later pushes inherit it). `publish.sh` checks with an anonymous pull and fails
  if that pull is denied, so a private package can't go unnoticed.
- Anonymous `just plan` aborts for an image that has never been published (GHCR answers 403,
  not 404). CI passes `GITHUB_TOKEN` with `packages: read`.
- This repo is public. No secrets, internal hostnames or private registry references in any file.

## Commits

Conventional commits, scoped by image: `feat(anki-sync-server): ...`, `ci: ...`, `chore: ...`.
Work on a branch and open a PR; don't commit to `main` directly.
