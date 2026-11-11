#!/usr/bin/env bash
# Smoke test: run the server with the hardened profile the chart recommends (read-only root
# filesystem, every capability dropped, no privilege escalation) and check it reports the expected
# version, answers /alive, serves the web vault and the API, runs as non-root and creates its
# database on the data volume.
#
# usage: test.sh <image>

set -euo pipefail

IMAGE="${1:?usage: test.sh <image>}"
NAME="vaultwarden-smoke-$$"
# A named volume, as in a real deployment: Vaultwarden refuses to start on Docker's anonymous
# VOLUME, since that data is lost with the container.
VOLUME="${NAME}-data"

cleanup() {
  local status=$?
  if [ "${status}" -ne 0 ]; then
    echo "--- container logs ---" >&2
    docker logs "${NAME}" >&2 || true
  fi
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker volume rm "${VOLUME}" >/dev/null 2>&1 || true
  exit "${status}"
}
trap cleanup EXIT

version="$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "${IMAGE}")"
reported="$(docker run --rm "${IMAGE}" --version)"
case "${reported}" in
  *"${version}"*) echo "ok: --version reports ${version}" ;;
  *)
    echo "FAIL: --version printed '${reported}', expected it to contain '${version}'" >&2
    exit 1
    ;;
esac

docker volume create "${VOLUME}" >/dev/null
docker run -d --name "${NAME}" \
  -v "${VOLUME}:/data" \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  -e SIGNUPS_ALLOWED=false \
  -e DOMAIN=http://localhost:8080 \
  -p 127.0.0.1::8080 \
  "${IMAGE}" >/dev/null

port="$(docker port "${NAME}" 8080/tcp | head -1 | awk -F: '{print $NF}')"
base="http://127.0.0.1:${port}"
echo "server mapped to ${base}"

for _ in $(seq 1 30); do
  if curl -fsS "${base}/alive" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "${base}/alive" >/dev/null || {
  echo "FAIL: /alive did not answer within 30s" >&2
  exit 1
}
echo "ok: /alive answers"

curl -fsS "${base}/" | grep -qi '<html' || {
  echo "FAIL: / did not serve the web vault" >&2
  exit 1
}
echo "ok: web vault served"

server="$(curl -fsS "${base}/api/config" | jq -er '.server.name')" || {
  echo "FAIL: /api/config did not return a server name" >&2
  exit 1
}
[ "${server}" = Vaultwarden ] || {
  echo "FAIL: /api/config reports server '${server}', expected Vaultwarden" >&2
  exit 1
}
echo "ok: API answers as ${server}"

user="$(docker inspect -f '{{.Config.User}}' "${NAME}")"
case "${user%%:*}" in
  "" | 0 | root)
    echo "FAIL: container runs as root (User='${user}')" >&2
    exit 1
    ;;
esac
echo "ok: runs as ${user}"

docker cp "${NAME}:/data/db.sqlite3" - >/dev/null || {
  echo "FAIL: /data/db.sqlite3 was not created; data volume not writable?" >&2
  exit 1
}
echo "ok: database created in /data"
