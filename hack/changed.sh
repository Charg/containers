#!/usr/bin/env bash
# Lists the images a change touches, relative to a base ref (default origin/main). A change to
# the shared tooling (hack/, the flake, workflows) counts as touching every image.
#
# Prints one name per line, and writes `images=<json array>` to $GITHUB_OUTPUT when set.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools git jq

BASE="${1:-origin/main}"
cd "${REPO_ROOT}"

merge_base="$(git merge-base "${BASE}" HEAD)"
files="$(git diff --name-only "${merge_base}" HEAD)"

if printf '%s\n' "${files}" | grep -qE '^(hack/|flake\.(nix|lock)$|justfile$|\.github/workflows/)'; then
  images="$(list_images)"
else
  images="$(printf '%s\n' "${files}" | sed -nE 's#^images/([^/]+)/.*#\1#p' | sort -u |
    while IFS= read -r name; do
      # Skip images that were deleted.
      [ -f "${IMAGES_DIR}/${name}/Dockerfile" ] && printf '%s\n' "${name}"
    done || true)"
fi

printf '%s\n' "${images}" | sed '/^$/d'
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "images=$(printf '%s\n' "${images}" | jq -Rsc 'split("\n") | map(select(length > 0))')" >>"${GITHUB_OUTPUT}"
fi
