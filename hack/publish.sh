#!/usr/bin/env bash
# Builds one image for every platform, pushes it to ghcr.io/<owner>/<name>:<version>, signs it
# keylessly with cosign, verifies the signature and checks the package is publicly pullable.
#
# Assumes the caller has logged in to ghcr.io (hack/registry-login.sh) and is running in GitHub
# Actions with an OIDC token available (id-token: write), which cosign picks up ambiently. Only
# publish what `just plan` says needs publishing: this overwrites the version tag.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools docker docker-buildx cosign curl jq git

NAME="${1:?usage: publish.sh <name>}"
require_image "${NAME}"

: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
: "${GITHUB_WORKFLOW_REF:?GITHUB_WORKFLOW_REF must be set (used as the signer identity to verify against)}"

VERSION="$(image_version "${NAME}")"
INPUTS="$(image_inputs "${NAME}")"
REF="$(image_ref "${NAME}")"
SOURCE="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}"
DESCRIPTION="$(grep -oE 'org\.opencontainers\.image\.description="[^"]*"' \
  "${IMAGES_DIR}/${NAME}/Dockerfile" | head -1 | cut -d'"' -f2 || true)"

metadata="$(mktemp)"
trap 'rm -f "${metadata}"' EXIT

args=(
  --builder "${BUILDER}"
  --file "${IMAGES_DIR}/${NAME}/Dockerfile"
  --platform "${PLATFORMS}"
  --tag "${REF}:${VERSION}"
  --label "org.opencontainers.image.revision=$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  # GHCR reads package metadata from the index of a multi-platform image, not its manifests.
  --annotation "index:org.opencontainers.image.source=${SOURCE}"
  --annotation "index:org.opencontainers.image.description=${DESCRIPTION}"
  --annotation "index:org.opencontainers.image.version=${VERSION}"
  --annotation "index:${INPUTS_ANNOTATION}=${INPUTS}"
  --provenance mode=max
  --sbom true
  --metadata-file "${metadata}"
  --push
)
if [ "${CACHE:-}" = gha ]; then
  args+=(--cache-from "type=gha,scope=${NAME}" --cache-to "type=gha,mode=max,scope=${NAME}")
fi

ensure_builder
echo "==> building and pushing ${REF}:${VERSION} (${PLATFORMS})"
buildx build "${args[@]}" "${IMAGES_DIR}/${NAME}"

# The digest buildx reports is the only identifier trusted from here on. The tag is mutable, so a
# signature over it would assert nothing.
DIGEST="$(jq -er '."containerimage.digest"' "${metadata}")" || {
  echo "no digest in buildx metadata; refusing to sign an unidentified image" >&2
  exit 1
}

echo "==> signing ${REF}@${DIGEST} (keyless, OIDC)"
cosign sign --yes "${REF}@${DIGEST}"

echo "==> verifying ${REF}@${DIGEST}"
cosign verify \
  --certificate-identity "https://github.com/${GITHUB_WORKFLOW_REF}" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "${REF}@${DIGEST}" >/dev/null

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "name=${NAME}"
    echo "version=${VERSION}"
    echo "digest=${DIGEST}"
    echo "ref=${REF}"
  } >>"${GITHUB_OUTPUT}"
fi

echo "==> checking ${REF} is publicly pullable"
body="$(mktemp)"
trap 'rm -f "${metadata}" "${body}"' EXIT
token="$(ghcr_token "${OWNER}/${NAME}" anonymous)" || token=""
status=""
if [ -n "${token}" ]; then
  status="$(ghcr_manifest "${OWNER}/${NAME}" "${DIGEST}" "${token}" "${body}")" || status=""
fi
if [ "${status}" != 200 ]; then
  echo "::error::${REF} is not publicly pullable (anonymous pull got HTTP ${status:-none})." \
    "GHCR creates new packages as private: an admin must set it to public once at" \
    "the package's settings page (Package settings > Change visibility), found under" \
    "https://github.com/${GITHUB_REPOSITORY_OWNER}?tab=packages" >&2
  exit 1
fi

echo "published ${REF}:${VERSION}@${DIGEST}"
