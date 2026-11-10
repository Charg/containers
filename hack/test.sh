#!/usr/bin/env bash
# Runs images/<name>/test.sh against the image `just build <name>` loaded locally.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools docker curl

NAME="${1:?usage: test.sh <name>}"
require_image "${NAME}"

TAG="$(local_tag "${NAME}")"
docker image inspect "${TAG}" >/dev/null 2>&1 || {
  echo "${TAG} not found; run 'just build ${NAME}' first" >&2
  exit 1
}

TEST="${IMAGES_DIR}/${NAME}/test.sh"
[ -x "${TEST}" ] || {
  echo "images/${NAME}/test.sh missing or not executable" >&2
  exit 1
}

echo "==> testing ${TAG}"
"${TEST}" "${TAG}"
