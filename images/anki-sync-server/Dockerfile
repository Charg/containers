# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
#
# Anki's self-hosted sync server. Adapted from upstream's docs/syncserver/Dockerfile.distroless:
# same cargo install and runtime layout, but cross-compiled on the build host (no QEMU), run as
# distroless' nonroot user, and with both base images pinned by digest.

# The published tag is this version. Renovate bumps it from the ankitects/anki GitHub releases,
# together with the commit the release tag points at. The source is fetched by that commit, not
# by the tag, because upstream can move a tag; the build fails if the tag no longer matches.
# renovate: datasource=github-releases depName=ankitects/anki
ARG ANKI_VERSION=26.09.4
ARG ANKI_COMMIT=c06370ff4d87cb48d825f90cc83e02b9a4e84ecd

# Builder runs natively on the build host and cross-compiles for the target platform; compiling
# Anki under QEMU emulation takes over an hour. Keep the Rust release in step with the
# rust-toolchain.toml of the Anki tag being built.
FROM --platform=$BUILDPLATFORM rust:1.99.1-trixie@sha256:8a4e90c7946b74626488b1446f712c0fe0ed1a596cbd3d871684bc9c5433ae07 AS builder

ARG ANKI_VERSION
ARG ANKI_COMMIT
ARG TARGETARCH
ARG BUILDARCH

RUN <<EOF
set -eu
case "${TARGETARCH}" in
  amd64) echo x86_64-unknown-linux-gnu >/rust-target; gnu=x86_64-linux-gnu; pkg=x86-64-linux-gnu; libc=amd64 ;;
  arm64) echo aarch64-unknown-linux-gnu >/rust-target; gnu=aarch64-linux-gnu; pkg=aarch64-linux-gnu; libc=arm64 ;;
  *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;;
esac
packages="protobuf-compiler"
if [ "${TARGETARCH}" != "${BUILDARCH}" ]; then
  packages="${packages} gcc-${pkg} g++-${pkg} libc6-dev-${libc}-cross"
  # Tell cargo and the cc crate (bundled sqlite, zstd, ...) which cross toolchain to use.
  target_env="$(tr 'a-z-' 'A-Z_' </rust-target)"
  target_cc="$(tr '-' '_' </rust-target)"
  {
    echo "export CARGO_TARGET_${target_env}_LINKER=${gnu}-gcc"
    echo "export CC_${target_cc}=${gnu}-gcc"
    echo "export CXX_${target_cc}=${gnu}-g++"
    echo "export AR_${target_cc}=${gnu}-ar"
  } >/cross-env
else
  : >/cross-env
fi
# Install from the Debian snapshot the builder image records it was made from, so a rebuild gets
# the same compilers and protoc, and they move only when Renovate bumps the builder's digest.
snapshot="$(sed -n '\|^# http://snapshot.debian.org/archive/debian/[0-9TZ]*$| { s|.*/||p; q }' \
  /etc/apt/sources.list.d/debian.sources)"
[ -n "${snapshot}" ] || { echo "builder image records no Debian snapshot" >&2; exit 1; }
# A snapshot's Release files expire a week after it was taken (Valid-Until); the snapshot is fixed
# and its signatures are still checked, so ignore the expiry or the build breaks after a week.
apt-get update --snapshot "${snapshot}" -o Acquire::Check-Valid-Until=false
# shellcheck disable=SC2086 # word splitting of the package list is intended
apt-get install --snapshot "${snapshot}" -y --no-install-recommends ${packages}
rm -rf /var/lib/apt/lists/*
rustup target add "$(cat /rust-target)"
EOF

RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/cargo-target,id=anki-sync-server-target-${TARGETARCH} <<EOF
set -eu
# Upstream can move a tag; the commit is what gets built. Refuse if they no longer agree. For an
# annotated tag, the peeled ^{} line is the commit.
git ls-remote https://github.com/ankitects/anki.git \
  "refs/tags/${ANKI_VERSION}" "refs/tags/${ANKI_VERSION}^{}" >/tmp/anki-tag
tagged="$(awk 'NR == 1 || /\^\{\}$/ { c = $1 } END { print c }' /tmp/anki-tag)"
if [ "${tagged}" != "${ANKI_COMMIT}" ]; then
  echo "anki tag ${ANKI_VERSION} points at '${tagged}', expected ${ANKI_COMMIT}; refusing to build" >&2
  exit 1
fi
. /cross-env
CARGO_TARGET_DIR=/cargo-target CARGO_PROFILE_RELEASE_STRIP=true \
  cargo install --git https://github.com/ankitects/anki.git \
    --rev "${ANKI_COMMIT}" \
    --target "$(cat /rust-target)" \
    --root /anki-server \
    --locked \
    anki-sync-server
# Data directory, owned by distroless' nonroot user so the server can write to it.
mkdir -p /rootfs/anki_data
EOF

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:cc66d222f0a7ec996b78a99fe76a969bc80b539a5016ad866c14d1949bc6d0ab

ARG ANKI_VERSION

COPY --from=builder /anki-server/bin/anki-sync-server /usr/bin/anki-sync-server
COPY --from=builder --chown=65532:65532 /rootfs/anki_data /anki_data

# Users set SYNC_USER1=user:pass (SYNC_USER2, ...); the port and data path are fixed so the
# healthcheck and volume stay correct.
ENV SYNC_PORT=8080 \
    SYNC_BASE=/anki_data

USER 65532:65532
EXPOSE 8080
VOLUME /anki_data

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD ["anki-sync-server", "--healthcheck"]

CMD ["anki-sync-server"]

LABEL org.opencontainers.image.title="anki-sync-server" \
      org.opencontainers.image.description="Anki's self-hosted sync server, built from upstream source on distroless." \
      org.opencontainers.image.version="${ANKI_VERSION}" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.url="https://github.com/ankitects/anki" \
      org.opencontainers.image.source="https://github.com/Charg/containers"
