# containers: dev tasks. Every recipe assumes the nix toolchain is on PATH: run inside the
# dev shell (`nix develop`, or direnv via .envrc), or one-shot as `nix develop -c just <recipe>`.
# Recipes are one-line shims over scripts in hack/; CI calls the same recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]

# List available recipes.
_default:
    @just --list --unsorted

# Run every linter: what CI and the pre-commit hook run.
lint:
    hack/lint.sh

# Format nix files.
fmt:
    git ls-files -z -- '*.nix' | xargs -0 --no-run-if-empty nixfmt

# Install the prek git hooks from .pre-commit-config.yaml (once per clone).
install-hooks:
    prek install

# List the dev shell's packages and the versions flake.lock pins them to.
versions:
    @nix eval --raw ".#devShells.$(nix eval --impure --raw --expr builtins.currentSystem).default.nativeBuildInputs" \
      --apply 'ps: builtins.concatStringsSep "" (map (p: "${p.pname or p.name} ${p.version or "-"}\n") ps)'

# List images, one per line.
images:
    @bash -c 'source hack/tools.sh && list_images'

# Build an image for the host platform and load it as localhost/<name>:dev.
build name:
    hack/build.sh {{ name }}

# Build an image for every published platform (no export; proves the cross-builds compile).
build-all name:
    hack/build.sh {{ name }} --all

# Copy an image's BuildKit cache mounts to (export) or from (import) a host directory (CI only).
cache-mounts action name arch dir:
    hack/cache-mounts.sh {{ action }} {{ name }} {{ arch }} {{ dir }}

# Run the image's smoke test against the locally built image.
test name:
    hack/test.sh {{ name }}

# Scan the locally built image for fixable HIGH/CRITICAL vulnerabilities.
scan name:
    hack/scan.sh {{ name }}

# Build, test and scan one image: what CI runs on a pull request.
check name: (build name) (test name) (scan name)

# List images changed relative to a base ref.
changed base="origin/main":
    hack/changed.sh {{ base }}

# Show which images need publishing (queries the registry, fails closed).
plan:
    hack/plan.sh

# Rebuild published images from scratch and check they're byte-identical (all when no name).
repro name="":
    hack/repro.sh {{ name }}

# Build for every platform, push, sign and verify one image (CI only).
publish name:
    hack/publish.sh {{ name }}
