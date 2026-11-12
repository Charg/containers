#!/usr/bin/env bash
# Shared shell setup sourced by every other script in hack/.
#
# Tool versions are not pinned here: the nix flake (flake.nix + flake.lock) is the single source
# of truth, and every script expects to run inside its dev shell (`nix develop`, or
# `nix develop -c just <recipe>`).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="${REPO_ROOT}/images"

# BuildKit daemon every build runs in, pinned by digest: it writes the layer tarballs and
# compresses them, so a different BuildKit can produce different bytes from the same inputs.
# Renovate bumps it (see .github/renovate.json5).
# renovate: datasource=docker depName=moby/buildkit
BUILDKIT_IMAGE="moby/buildkit:v0.34.2@sha256:c5f8862f52499773af85bc07695b2379ef08e8002352b0df2c4864c91d78dabe"
BUILDKIT_VERSION="${BUILDKIT_IMAGE#*:}"
BUILDKIT_VERSION="${BUILDKIT_VERSION%@*}"

# buildx builder shared by every build. The docker-container driver is what makes multi-platform
# builds and attestations work; the default docker driver supports neither. The BuildKit version
# is in the name, so a bump gets a new builder rather than silently reusing an old one.
export BUILDER="${BUILDER:-containers-${BUILDKIT_VERSION}}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

# Fixed timestamp for image config, history and (with rewrite-timestamp) every file in the layers
# a build adds, so rebuilding the same inputs gives the same digests. 1980-01-01, the value nix's
# dev shell already exported before this was set explicitly; published images keep that date.
export SOURCE_DATE_EPOCH=315532800

# Version of how images are built from their inputs. It's part of image_inputs, so bumping it
# republishes every image: do that when a change here or in publish.sh changes the bytes of an
# image built from unchanged inputs (2: SOURCE_DATE_EPOCH with rewrite-timestamp). BUILDKIT_IMAGE
# is part of image_inputs too, so a BuildKit bump republishes on its own.
BUILD_SCHEME=2

# Index annotation that records which inputs a published image was built from (see plan.sh).
export INPUTS_ANNOTATION="dev.charg.containers.inputs"

# GHCR rejects uppercase path segments; this repo's owner (Charg) has one.
OWNER="$(printf '%s' "${GITHUB_REPOSITORY_OWNER:-Charg}" | tr '[:upper:]' '[:lower:]')"

require_tools() {
  local missing=0 tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || {
      echo "missing tool: ${tool}" >&2
      missing=1
    }
  done
  if [ "${missing}" -ne 0 ]; then
    echo "enter the dev shell first: 'nix develop' (or run the recipe as 'nix develop -c just <recipe>')" >&2
    return 1
  fi
}

# The nix-provided buildx, called directly so a different docker CLI plugin on the host can't
# shadow it.
buildx() {
  docker-buildx "$@"
}

# Creates builder ${1} on the pinned BuildKit image unless it exists, and starts it.
create_builder() {
  if ! buildx inspect "${1}" >/dev/null 2>&1; then
    buildx create --name "${1}" --driver docker-container \
      --driver-opt "image=${BUILDKIT_IMAGE}" >/dev/null
  fi
  buildx inspect --bootstrap "${1}" >/dev/null
}

ensure_builder() {
  create_builder "${BUILDER}"
}

# GitHub Actions layer-cache arguments for building image ${1} for the comma-separated platforms
# ${2}, appended to the array named ${3}. Each platform has its own cache scope, so CI's parallel
# single-platform builds don't overwrite each other's cache index, and a multi-platform publish
# reads and refreshes every platform's scope. Blobs are shared between scopes, so this costs
# little extra cache storage.
gha_cache_args() {
  local name="$1" platform scope
  local -n cache_args_out="$3"
  local -a cache_platforms
  IFS=, read -ra cache_platforms <<<"$2"
  for platform in "${cache_platforms[@]}"; do
    scope="${name}-${platform//\//-}"
    cache_args_out+=(--cache-from "type=gha,scope=${scope}" --cache-to "type=gha,mode=max,scope=${scope}")
  done
}

# Platform of the docker daemon's host, e.g. linux/amd64: what a build without --platform targets.
host_platform() {
  docker version --format '{{.Server.Os}}/{{.Server.Arch}}'
}

# Images present in the repo, one name per line. Empty output is valid: every recipe must succeed
# on a checkout with no images.
list_images() {
  [ -d "${IMAGES_DIR}" ] || return 0
  find "${IMAGES_DIR}" -mindepth 2 -maxdepth 2 -name Dockerfile -print0 |
    xargs -0 -r -n1 dirname |
    xargs -r -n1 basename |
    sort
}

require_image() {
  [ -f "${IMAGES_DIR}/${1}/Dockerfile" ] || {
    echo "no such image: ${1} (expected images/${1}/Dockerfile)" >&2
    return 1
  }
}

# The upstream version an image is tagged with: the default of the first `ARG <NAME>_VERSION=...`
# declared before the first FROM.
image_version() {
  local version
  version="$(awk '
    /^FROM[[:space:]]/ { exit }
    /^ARG[[:space:]]+[A-Z0-9_]+_VERSION=/ { sub(/^ARG[[:space:]]+[A-Z0-9_]+_VERSION=/, ""); print; exit }
  ' "${IMAGES_DIR}/${1}/Dockerfile")"
  [ -n "${version}" ] || {
    echo "images/${1}/Dockerfile: no 'ARG <NAME>_VERSION=<version>' before the first FROM" >&2
    return 1
  }
  printf '%s\n' "${version}"
}

# Content hash of everything that goes into an image: every file in its directory except the
# smoke test, plus BUILD_SCHEME and BUILDKIT_IMAGE. Two checkouts with the same hash build the same image, so plan.sh
# can tell a Dockerfile change or base-image digest bump apart from a no-op.
image_inputs() {
  (
    echo "build-scheme ${BUILD_SCHEME}"
    echo "buildkit ${BUILDKIT_IMAGE}"
    cd "${IMAGES_DIR}/${1}"
    find . -type f ! -name test.sh -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
  ) | sha256sum | cut -c1-64
}

# Immutable tag for an image: its upstream version plus a short hash of its inputs, e.g.
# 26.09.4-1a2b3c4d5e6f. Unlike the version tag it never moves; publish.sh never overwrites it.
image_build_tag() {
  local version inputs
  version="$(image_version "${1}")"
  inputs="$(image_inputs "${1}")"
  printf '%s-%s\n' "${version}" "${inputs:0:12}"
}

# Repository path of an image under ghcr.io. Images live under containers/ so they never collide
# with a Helm chart of the same name, which Charg/charts publishes under charts/.
image_repo() {
  printf '%s/containers/%s\n' "${OWNER}" "${1}"
}

image_ref() {
  printf 'ghcr.io/%s\n' "$(image_repo "${1}")"
}

# Local tag `just build` loads into the docker daemon, and `just test` / `just scan` use.
local_tag() {
  printf 'localhost/%s:dev\n' "${1}"
}

# Pull token for ghcr.io/${1} (owner/name). Authenticated when GITHUB_TOKEN is set, anonymous
# otherwise. Prints nothing and returns non-zero on failure.
ghcr_token() {
  local repo="$1" auth=()
  if [ -n "${GITHUB_TOKEN:-}" ] && [ "${2:-}" != anonymous ]; then
    auth=(-u "${GITHUB_ACTOR:-token}:${GITHUB_TOKEN}")
  fi
  curl -fsSL "${auth[@]}" "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" |
    jq -er '.token'
}

# GETs the manifest for ghcr.io/${1}:${2} with token ${3}. Writes the body to ${4} and prints the
# HTTP status. A transport failure prints nothing and returns non-zero.
ghcr_manifest() {
  local repo="$1" ref="$2" token="$3" out="$4"
  curl -s -o "${out}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "https://ghcr.io/v2/${repo}/manifests/${ref}"
}

# Platform images of the index ${1} (ref@digest), one "<os>/<arch>[/<variant>] <digest>" per line,
# skipping attestation manifests. Fails if there are none.
index_platforms() {
  buildx imagetools inspect --raw "${1}" | jq -er '
    [.manifests[] | select(.platform.os != "unknown")]
    | if length == 0 then error("no platform images") else .[] end
    | "\(.platform.os)/\(.platform.architecture)\(if .platform.variant then "/" + .platform.variant else "" end) \(.digest)"
  '
}
