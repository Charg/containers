#!/usr/bin/env bash
# Scans the locally built image with Trivy. Fails on HIGH/CRITICAL findings that have a fix
# available; unfixed ones are reported but can't be acted on here.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools docker trivy

NAME="${1:?usage: scan.sh <name>}"
require_image "${NAME}"

TAG="$(local_tag "${NAME}")"
docker image inspect "${TAG}" >/dev/null 2>&1 || {
  echo "${TAG} not found; run 'just build ${NAME}' first" >&2
  exit 1
}

echo "==> scanning ${TAG}"
trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 "${TAG}"
