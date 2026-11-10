#!/usr/bin/env bash
# Builds one image.
#
#   build.sh <name>         build for the host platform and load it as localhost/<name>:dev
#   build.sh <name> --all   build every platform in $PLATFORMS without exporting (proves the
#                           cross-builds compile; `just publish` is what pushes)
#
# CACHE=gha switches on the GitHub Actions layer cache (CI only).

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools docker docker-buildx

NAME="${1:?usage: build.sh <name> [--all]}"
MODE="${2:-}"
require_image "${NAME}"

args=(--builder "${BUILDER}" --file "${IMAGES_DIR}/${NAME}/Dockerfile")

case "${MODE}" in
  "") args+=(--load --tag "$(local_tag "${NAME}")") ;;
  --all) args+=(--platform "${PLATFORMS}" --output type=cacheonly) ;;
  *)
    echo "unknown mode: ${MODE}" >&2
    exit 1
    ;;
esac

if [ "${CACHE:-}" = gha ]; then
  args+=(--cache-from "type=gha,scope=${NAME}" --cache-to "type=gha,mode=max,scope=${NAME}")
fi

ensure_builder
echo "==> building ${NAME} $(image_version "${NAME}") ${MODE:+(${PLATFORMS})}"
buildx build "${args[@]}" "${IMAGES_DIR}/${NAME}"
