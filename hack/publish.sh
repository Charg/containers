#!/usr/bin/env bash
# Builds one image for every platform, pushes it to ghcr.io/<owner>/<name>:<version> and to the
# immutable tag <version>-<inputs>, signs it keylessly with cosign, verifies the signature, attaches
# a signed Trivy vulnerability attestation to each platform image and checks the package is
# publicly pullable.
#
# The immutable tag is never overwritten. When it already exists (the image directory was reverted
# to inputs that were published before), the existing signed image is re-pointed to by the version
# tag instead of being rebuilt.
#
# Assumes the caller has logged in to ghcr.io (hack/registry-login.sh) and is running in GitHub
# Actions with an OIDC token available (id-token: write), which cosign picks up ambiently. Only
# publish what `just plan` says needs publishing: this overwrites the version tag.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools docker docker-buildx cosign trivy curl jq git

NAME="${1:?usage: publish.sh <name>}"
require_image "${NAME}"

: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
: "${GITHUB_WORKFLOW_REF:?GITHUB_WORKFLOW_REF must be set (used as the signer identity to verify against)}"

VERSION="$(image_version "${NAME}")"
INPUTS="$(image_inputs "${NAME}")"
REF="$(image_ref "${NAME}")"
BUILD_TAG="$(image_build_tag "${NAME}")"
SOURCE="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}"
DESCRIPTION="$(grep -oE 'org\.opencontainers\.image\.description="[^"]*"' \
  "${IMAGES_DIR}/${NAME}/Dockerfile" | head -1 | cut -d'"' -f2 || true)"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
metadata="${work}/metadata.json"
body="${work}/manifest.json"

IDENTITY="https://github.com/${GITHUB_WORKFLOW_REF}"
ISSUER="https://token.actions.githubusercontent.com"

# Prints the digest ghcr.io/<owner>/<name>:${1} resolves to, or fails.
resolve_digest() {
  local token status
  token="$(ghcr_token "${OWNER}/${NAME}")" || return 1
  status="$(ghcr_manifest "${OWNER}/${NAME}" "${1}" "${token}" "${body}")" || return 1
  [ "${status}" = 200 ] || return 1
  printf 'sha256:%s\n' "$(sha256sum <"${body}" | cut -c1-64)"
}

# Has this exact set of inputs been published before? Only a definitive answer will do.
token="$(ghcr_token "${OWNER}/${NAME}")" || {
  echo "registry auth failed for ${REF}; aborting (fail closed)" >&2
  exit 1
}
existing="$(ghcr_manifest "${OWNER}/${NAME}" "${BUILD_TAG}" "${token}" "${body}")" || {
  echo "registry unreachable checking ${REF}:${BUILD_TAG}; aborting (fail closed)" >&2
  exit 1
}

case "${existing}" in
  404)
    args=(
      --builder "${BUILDER}"
      --file "${IMAGES_DIR}/${NAME}/Dockerfile"
      --platform "${PLATFORMS}"
      --tag "${REF}:${VERSION}"
      --tag "${REF}:${BUILD_TAG}"
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
    cosign verify --certificate-identity "${IDENTITY}" --certificate-oidc-issuer "${ISSUER}" \
      "${REF}@${DIGEST}" >/dev/null
    ;;

  200)
    DIGEST="$(printf 'sha256:%s' "$(sha256sum <"${body}" | cut -c1-64)")"
    echo "==> ${REF}:${BUILD_TAG} already exists (${DIGEST}); re-pointing ${VERSION} at it, not rebuilding"

    # Only re-point the version tag at an image this workflow signed.
    cosign verify --certificate-identity "${IDENTITY}" --certificate-oidc-issuer "${ISSUER}" \
      "${REF}@${DIGEST}" >/dev/null || {
      echo "${REF}@${DIGEST} has no valid signature from ${IDENTITY}; refusing to re-tag it" >&2
      exit 1
    }
    buildx imagetools create --tag "${REF}:${VERSION}" "${REF}@${DIGEST}"

    moved="$(resolve_digest "${VERSION}")" || moved=""
    if [ "${moved}" != "${DIGEST}" ]; then
      echo "${REF}:${VERSION} resolves to '${moved}' after re-tagging, expected ${DIGEST}" >&2
      exit 1
    fi
    ;;

  *)
    echo "ambiguous registry response (HTTP ${existing}) for ${REF}:${BUILD_TAG}; aborting (fail closed)" >&2
    exit 1
    ;;
esac

# Attach a signed vulnerability scan to every platform image. This records what was known at
# publish time; it doesn't gate the publish (CI's `just scan` already did, on the same inputs).
echo "==> attesting vulnerability scans for ${REF}@${DIGEST}"
platforms="$(buildx imagetools inspect --raw "${REF}@${DIGEST}" | jq -er '
  .manifests[]
  | select(.platform.os != "unknown")
  | "\(.platform.os)/\(.platform.architecture)\(if .platform.variant then "/" + .platform.variant else "" end) \(.digest)"
')" || {
  echo "could not list the platform images of ${REF}@${DIGEST}" >&2
  exit 1
}
while read -r platform platform_digest; do
  echo "    ${platform} ${platform_digest}"
  scan="${work}/vuln-${platform_digest#sha256:}.json"
  trivy image --quiet --scanners vuln --format cosign-vuln --output "${scan}" \
    "${REF}@${platform_digest}"
  cosign attest --yes --type vuln --predicate "${scan}" "${REF}@${platform_digest}"
  cosign verify-attestation --type vuln \
    --certificate-identity "${IDENTITY}" --certificate-oidc-issuer "${ISSUER}" \
    "${REF}@${platform_digest}" >/dev/null
done <<<"${platforms}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "name=${NAME}"
    echo "version=${VERSION}"
    echo "digest=${DIGEST}"
    echo "ref=${REF}"
    echo "build_tag=${BUILD_TAG}"
  } >>"${GITHUB_OUTPUT}"
fi

echo "==> checking ${REF} is publicly pullable"
token="$(ghcr_token "${OWNER}/${NAME}" anonymous)" || token=""
status=""
if [ -n "${token}" ]; then
  status="$(ghcr_manifest "${OWNER}/${NAME}" "${DIGEST}" "${token}" "${body}")" || status=""
fi
if [ "${status}" != 200 ]; then
  echo "::error::${REF} is not publicly pullable (anonymous pull got HTTP ${status:-none})." \
    "Every image here must be public. Check that the image's org.opencontainers.image.source" \
    "annotation names this repo, and set the package to public in its settings" \
    "(Package settings > Change visibility), found under" \
    "https://github.com/${GITHUB_REPOSITORY_OWNER}?tab=packages" >&2
  exit 1
fi

echo "published ${REF}:${VERSION} and ${REF}:${BUILD_TAG} @ ${DIGEST}"
