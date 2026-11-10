#!/usr/bin/env bash
# Decides which images need publishing by asking the registry, not by diffing git history: a
# push can touch several images at once, and a re-run after a partial failure must reach the
# same answer without knowing what the last run did.
#
# An image needs publishing when ghcr.io/<owner>/<name>:<version> doesn't exist, or when it
# exists but was built from different inputs (its index annotation doesn't match the hash of
# images/<name>/). The second case is how base-image digest bumps (CVE fixes) get republished
# under the same upstream version tag.
#
# Fails closed: anything other than a definitive 200 or 404 from the registry aborts the run.
# Uses GITHUB_TOKEN when set, anonymous access otherwise (enough for public packages).
#
# Prints a summary, and writes `images=<json array of names>` to $GITHUB_OUTPUT when set.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools curl jq

body="$(mktemp)"
trap 'rm -f "${body}"' EXIT

publish=()
while IFS= read -r name; do
  [ -n "${name}" ] || continue
  version="$(image_version "${name}")"
  inputs="$(image_inputs "${name}")"
  repo="${OWNER}/${name}"

  token="$(ghcr_token "${repo}")" || {
    echo "registry auth failed for ${repo}; aborting (fail closed)" >&2
    exit 1
  }
  status="$(ghcr_manifest "${repo}" "${version}" "${token}" "${body}")" || {
    echo "registry unreachable checking ${repo}:${version}; aborting (fail closed)" >&2
    exit 1
  }

  case "${status}" in
    404)
      echo "publish  ${name}:${version}  (not in registry)"
      publish+=("${name}")
      ;;
    200)
      published="$(jq -r --arg k "${INPUTS_ANNOTATION}" '.annotations[$k] // ""' "${body}")"
      if [ "${published}" = "${inputs}" ]; then
        echo "skip     ${name}:${version}  (up to date)"
      else
        echo "publish  ${name}:${version}  (inputs changed: ${published:-none} -> ${inputs})"
        publish+=("${name}")
      fi
      ;;
    *)
      echo "ambiguous registry response (HTTP ${status}) for ${repo}:${version};" \
        "aborting (fail closed). Set GITHUB_TOKEN if the package is private." >&2
      exit 1
      ;;
  esac
done < <(list_images)

json="$(printf '%s\n' "${publish[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
echo "images=${json}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "images=${json}" >>"${GITHUB_OUTPUT}"
fi
