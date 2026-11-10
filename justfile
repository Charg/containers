# Container images: dev tasks. Every recipe assumes the nix toolchain is on PATH; run inside the
# dev shell (`nix develop`) or invoke a recipe directly as `nix develop -c just <recipe>`.

set shell := ["bash", "-cu"]

# List available recipes.
_default:
    @just --list --unsorted

# Lint: shellcheck, hadolint, actionlint, yamllint.
lint:
    hack/lint.sh

# List images, one per line.
images:
    @bash -c 'source hack/tools.sh && list_images'

# Build an image for the host platform and load it as localhost/<name>:dev.
build name:
    hack/build.sh {{ name }}

# Build an image for every published platform (no export; proves the cross-builds compile).
build-all name:
    hack/build.sh {{ name }} --all

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

# Build for every platform, push, sign and verify one image (CI only).
publish name:
    hack/publish.sh {{ name }}
