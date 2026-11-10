#!/usr/bin/env bash
# Logs docker in to ghcr.io. buildx (pushing) and cosign (signing) both read the Docker config,
# so one login covers both. Credentials come from the environment, never from arguments, so they
# can't leak into the process list or a workflow's command trace.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools docker

: "${GITHUB_ACTOR:?GITHUB_ACTOR must be set}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"

printf '%s' "${GITHUB_TOKEN}" | docker login ghcr.io --username "${GITHUB_ACTOR}" --password-stdin
