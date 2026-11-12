#!/usr/bin/env bash
# Copies an image's BuildKit cache mounts (`RUN --mount=type=cache`, e.g. a cargo target dir)
# between the builder and a directory on the host, so CI can keep them in the Actions cache.
# BuildKit's gha layer cache stores layers only; without this, a runner's cache mounts start empty
# and any change above a compile step means compiling everything from scratch.
#
#   cache-mounts.sh import <name> <arch> <dir>   seed the mounts from <dir>/<mount id>/, if present
#   cache-mounts.sh export <name> <arch> <dir>   replace <dir> with the mounts' current contents
#
# <arch> is the TARGETARCH the mounts were built for (amd64, arm64); mount ids may use
# ${TARGETARCH}. An image without cache mounts is a no-op.
#
# For CI on pull requests only: a published build starts from empty mounts on a fresh runner,
# so nothing restored here can reach a published image.

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

require_tools docker docker-buildx

ACTION="${1:?usage: cache-mounts.sh <import|export> <name> <arch> <dir>}"
NAME="${2:?usage: cache-mounts.sh <import|export> <name> <arch> <dir>}"
ARCH="${3:?usage: cache-mounts.sh <import|export> <name> <arch> <dir>}"
DIR="${4:?usage: cache-mounts.sh <import|export> <name> <arch> <dir>}"
require_image "${NAME}"

# The ids of the cache mounts the Dockerfile declares (a mount without an id is keyed by its
# target), with ${TARGETARCH} resolved.
mount_ids() {
  local mount opt id target
  grep -oE -- '--mount=type=cache,[^[:space:]]+' "${IMAGES_DIR}/${NAME}/Dockerfile" |
    while IFS= read -r mount; do
      id="" target=""
      IFS=, read -ra opts <<<"${mount#--mount=}"
      for opt in "${opts[@]}"; do
        case "${opt}" in
          id=*) id="${opt#id=}" ;;
          target=* | dst=* | destination=*) target="${opt#*=}" ;;
        esac
      done
      id="${id:-${target}}"
      id="${id//\$\{TARGETARCH\}/${ARCH}}"
      id="${id//\$TARGETARCH/${ARCH}}"
      case "${id}" in
        *'$'*)
          echo "cache mount id '${id}' uses a variable other than TARGETARCH; unsupported" >&2
          return 1
          ;;
        */*)
          echo "cache mount id '${id}' contains '/'; give it an id without one" >&2
          return 1
          ;;
      esac
      printf '%s\n' "${id}"
    done | sort -u
}

ids="$(mount_ids)"
if [ -z "${ids}" ]; then
  echo "==> ${NAME} has no cache mounts"
  exit 0
fi

# The pinned BuildKit image doubles as the utility image: it's already trusted and has a shell
# and cp. Unset SOURCE_DATE_EPOCH so nothing clamps file times: cargo decides what to rebuild by
# comparing them. Not --no-cache, which gives every cache mount a fresh empty directory; a
# throwaway RUN_ID build arg makes the copy step run every time instead.
utility() {
  env -u SOURCE_DATE_EPOCH docker-buildx build --builder "${BUILDER}" \
    --build-arg "RUN_ID=$(date +%s%N)-$$" "$@"
}

ensure_builder
case "${ACTION}" in
  import)
    while IFS= read -r id; do
      if [ ! -d "${DIR}/${id}" ]; then
        echo "==> no saved cache mount ${id}; starting empty"
        continue
      fi
      echo "==> importing cache mount ${id} ($(du -sh "${DIR}/${id}" | cut -f1))"
      utility --output type=cacheonly --file - "${DIR}" <<EOF
FROM ${BUILDKIT_IMAGE}
ARG RUN_ID
RUN --mount=type=cache,id=${id},target=/mount --mount=type=bind,source=${id},target=/saved \
    cp -a /saved/. /mount/
EOF
      # The builder has its own copy now; free the disk for the build.
      rm -rf "${DIR:?}/${id}"
    done <<<"${ids}"
    ;;

  export)
    rm -rf "${DIR}"
    mkdir -p "${DIR}"
    empty="$(mktemp -d)"
    trap 'rm -rf "${empty}"' EXIT
    while IFS= read -r id; do
      utility --output "type=local,dest=${DIR}/${id}" --file - "${empty}" <<EOF
FROM ${BUILDKIT_IMAGE} AS copy
ARG RUN_ID
RUN --mount=type=cache,id=${id},target=/mount mkdir /saved && cp -a /mount/. /saved/
FROM scratch
COPY --from=copy /saved /
EOF
      # An empty mount (nothing was compiled in this builder) isn't worth saving, and saving it
      # under the inputs' key would stop a later run saving a real one.
      if [ -z "$(ls -A "${DIR}/${id}")" ]; then
        echo "==> cache mount ${id} is empty; not saving it"
        rmdir "${DIR}/${id}"
        continue
      fi
      echo "==> exported cache mount ${id} ($(du -sh "${DIR}/${id}" | cut -f1))"
    done <<<"${ids}"
    ;;

  *)
    echo "unknown action: ${ACTION} (import or export)" >&2
    exit 1
    ;;
esac
