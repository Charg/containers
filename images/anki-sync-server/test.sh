#!/usr/bin/env bash
# Smoke test: start the server with one user and check it answers on :8080, passes its own
# healthcheck, runs as non-root and can write to its data volume.
#
# usage: test.sh <image>

set -euo pipefail

IMAGE="${1:?usage: test.sh <image>}"
NAME="anki-sync-server-smoke-$$"

cleanup() {
  local status=$?
  if [ "${status}" -ne 0 ]; then
    echo "--- container logs ---" >&2
    docker logs "${NAME}" >&2 || true
  fi
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  exit "${status}"
}
trap cleanup EXIT

docker run -d --name "${NAME}" \
  -e SYNC_USER1=smoke:smoke \
  -p 127.0.0.1::8080 \
  "${IMAGE}" >/dev/null

port="$(docker port "${NAME}" 8080/tcp | head -1 | awk -F: '{print $NF}')"
echo "server mapped to 127.0.0.1:${port}"

for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "http://127.0.0.1:${port}/health" >/dev/null || {
  echo "FAIL: /health did not answer within 30s" >&2
  exit 1
}
echo "ok: /health answers"

docker exec "${NAME}" anki-sync-server --healthcheck || {
  echo "FAIL: built-in healthcheck failed" >&2
  exit 1
}
echo "ok: built-in healthcheck passes"

user="$(docker inspect -f '{{.Config.User}}' "${NAME}")"
case "${user%%:*}" in
  "" | 0 | root)
    echo "FAIL: container runs as root (User='${user}')" >&2
    exit 1
    ;;
esac
echo "ok: runs as ${user}"

# The server creates a folder per configured user under SYNC_BASE at startup.
docker cp "${NAME}:/anki_data/smoke" - >/dev/null || {
  echo "FAIL: /anki_data/smoke was not created; data volume not writable?" >&2
  exit 1
}
echo "ok: user data folder created in /anki_data"
