#!/usr/bin/env bash
# Rebuilds published images from this checkout and checks they come out byte-identical.
#
#   repro.sh [<name>]   one image, or every image when no name is given
#
# For each image: the published index must record the same inputs as the checkout (otherwise this
# would compare different sources), then every platform is rebuilt from scratch in a fresh builder
# (no layer cache and no cache mounts) and its manifest digest compared with the published
# platform digest. The index digest is never compared: it covers the provenance and SBOM
# attestations, which differ on every build.
#
# Must run on an amd64 host, as the release job does: platform images are cross-compiled from the
# build host, and a different host architecture runs a different builder stage.
#
# Fails closed: a registry error, an inputs mismatch or a digest mismatch all fail the run.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools docker docker-buildx curl jq

if [ "$(uname -m)" != x86_64 ]; then
  echo "repro must run on an amd64 host, like the release job (this is $(uname -m))" >&2
  exit 1
fi

work="$(mktemp -d)"
builders=()
cleanup() {
  local b
  for b in "${builders[@]}"; do
    buildx rm "${b}" >/dev/null 2>&1 || true
  done
  rm -rf "${work}"
}
trap cleanup EXIT

# Rebuilds one image; returns non-zero on any mismatch or error.
repro() {
  local name="$1" version inputs repo ref token status published index platforms revision
  local builder platform digest rebuilt failed=0
  version="$(image_version "${name}")"
  inputs="$(image_inputs "${name}")"
  repo="$(image_repo "${name}")"
  ref="$(image_ref "${name}")"

  token="$(ghcr_token "${repo}")" || {
    echo "registry auth failed for ${ref}" >&2
    return 1
  }
  status="$(ghcr_manifest "${repo}" "${version}" "${token}" "${work}/index.json")" || {
    echo "registry unreachable checking ${ref}:${version}" >&2
    return 1
  }
  if [ "${status}" != 200 ]; then
    echo "${ref}:${version} not available (HTTP ${status}); nothing to reproduce" >&2
    return 1
  fi
  published="$(jq -r --arg k "${INPUTS_ANNOTATION}" '.annotations[$k] // ""' "${work}/index.json")"
  if [ "${published}" != "${inputs}" ]; then
    echo "${ref}:${version} was built from inputs ${published:-unknown}, this checkout has" \
      "${inputs}; check out the commit that published it (or wait for the release job)" >&2
    return 1
  fi
  index="sha256:$(sha256sum <"${work}/index.json" | cut -c1-64)"
  platforms="$(index_platforms "${ref}@${index}")" || {
    echo "could not list the platform images of ${ref}@${index}" >&2
    return 1
  }
  # publish.sh labels the image with the commit it ran at, which needn't be this checkout's even
  # when the inputs match. Use the published value; it's the same for every platform.
  revision="$(buildx imagetools inspect "${ref}@${index}" --format '{{json .Image}}' |
    jq -er '[.[].config.Labels["org.opencontainers.image.revision"]] | unique
            | if length == 1 and .[0] != null then .[0] else error("no single revision label") end')" || {
    echo "could not read the revision label of ${ref}@${index}" >&2
    return 1
  }

  builder="repro-$$-${name}"
  builders+=("${builder}")
  create_builder "${builder}"

  echo "==> reproducing ${ref}:${version} @ ${index} (inputs ${inputs:0:12}, revision ${revision:0:12})"
  while read -r platform digest; do
    echo "--> ${platform}: rebuilding"
    buildx build \
      --builder "${builder}" \
      --no-cache \
      --file "${IMAGES_DIR}/${name}/Dockerfile" \
      --platform "${platform}" \
      --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
      --label "org.opencontainers.image.revision=${revision}" \
      --provenance false \
      --sbom false \
      --metadata-file "${work}/metadata.json" \
      --output "type=oci,dest=${work}/image.tar,rewrite-timestamp=true" \
      "${IMAGES_DIR}/${name}" </dev/null || {
      echo "FAIL ${platform}: rebuild failed" >&2
      failed=1
      continue
    }
    rebuilt="$(jq -er '."containerimage.digest"' "${work}/metadata.json")" || {
      echo "FAIL ${platform}: no digest in buildx metadata" >&2
      failed=1
      continue
    }
    if [ "${rebuilt}" = "${digest}" ]; then
      echo "ok   ${platform}: ${rebuilt}"
    else
      echo "FAIL ${platform}: rebuilt ${rebuilt}, published ${digest}" >&2
      failed=1
    fi
  done <<<"${platforms}"

  buildx rm "${builder}" >/dev/null 2>&1 || true
  return "${failed}"
}

if [ -n "${1:-}" ]; then
  require_image "$1"
  names="$1"
else
  names="$(list_images)"
fi

failed=()
while IFS= read -r name; do
  [ -n "${name}" ] || continue
  repro "${name}" || failed+=("${name}")
done <<<"${names}"

if [ "${#failed[@]}" -ne 0 ]; then
  echo "not reproducible: ${failed[*]}" >&2
  exit 1
fi
echo "every image reproduced byte-for-byte"
