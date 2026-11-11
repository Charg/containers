# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=skip=FromPlatformFlagConstDisallowed
#
# Vaultwarden, the Bitwarden-compatible server. Adapted from upstream's docker/Dockerfile.debian:
# the same release build of the same source, with these differences:
#   - SQLite only (DB=sqlite, bundled into the binary). MySQL and PostgreSQL support would pull
#     libpq and libmariadb, and their dependency trees, into the runtime image.
#   - Runtime is distroless cc (glibc, libgcc_s, OpenSSL 3, CA certificates, tzdata) as the
#     nonroot user, with no shell: upstream's start.sh and curl-based healthcheck.sh are dropped,
#     and the binary is the entrypoint. Kubernetes probes GET /alive directly.
#   - Cross-compiled with Debian's gcc cross toolchain instead of tonistiigi/xx.
#   - Hermetic: build-stage apt packages come from the snapshot.debian.org timestamp the builder
#     image was made from, every crate is fetched against the checksums in Cargo.lock, and the
#     compile runs with no network.
#   - Listens on 8080, not 80, so it runs unprivileged.
#
# OpenSSL is linked dynamically against the runtime image's libssl3, not vendored, so OpenSSL
# fixes arrive with a distroless digest bump and scanners can see the package.

# The published tag is this version. Renovate bumps it from the dani-garcia/vaultwarden GitHub
# releases, together with the commit the release tag points at. The source is fetched by that
# commit; the build fails if the tag no longer matches.
# renovate: datasource=github-releases depName=dani-garcia/vaultwarden
ARG VAULTWARDEN_VERSION=1.37.5
ARG VAULTWARDEN_COMMIT=6ed6921cc2b0e03b4d74189574d2a5e71c512e97

# The web vault (Bitwarden's web client, patched for Vaultwarden) is a prebuilt, platform-neutral
# set of static files that upstream publishes and pins per release in docker/DockerSettings.yaml.
# The build fails unless this is the digest the Vaultwarden release pins, so Renovate's web-vault
# bumps only merge together with the server release that adopts them (they share a group).
ARG WEB_VAULT_IMAGE=docker.io/vaultwarden/web-vault:v2026.10.1@sha256:7baaa7d5349742548b6c44e557c1512157b22010cdf314ccc399ffdcacb5eb52

# amd64 only upstream, and the files are the same for every platform.
# hadolint ignore=DL3029
FROM --platform=linux/amd64 ${WEB_VAULT_IMAGE} AS vault

# Builder runs natively on the build host and cross-compiles for the target platform. The Rust
# release must match the rust-toolchain.toml of the Vaultwarden tag being built; the build checks.
FROM --platform=$BUILDPLATFORM rust:1.99.1-trixie@sha256:8a4e90c7946b74626488b1446f712c0fe0ed1a596cbd3d871684bc9c5433ae07 AS builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Always the builder image's toolchain. Without this, upstream's rust-toolchain.toml makes rustup
# download the extra components it lists (rustfmt, clippy) in /src.
ENV RUSTUP_TOOLCHAIN=${RUST_VERSION}

ARG TARGETARCH
ARG BUILDARCH

RUN <<EOF
set -euo pipefail
case "${TARGETARCH}" in
  amd64) echo x86_64-unknown-linux-gnu >/rust-target; gnu=x86_64-linux-gnu; pkg=x86-64-linux-gnu ;;
  arm64) echo aarch64-unknown-linux-gnu >/rust-target; gnu=aarch64-linux-gnu; pkg=aarch64-linux-gnu ;;
  *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;;
esac
target="$(cat /rust-target)"
target_env="$(printf '%s' "${target}" | tr 'a-z-' 'A-Z_')"
target_cc="$(printf '%s' "${target}" | tr '-' '_')"
packages="pkg-config libssl-dev:${TARGETARCH}"
: >/cross-env
if [ "${TARGETARCH}" != "${BUILDARCH}" ]; then
  dpkg --add-architecture "${TARGETARCH}"
  packages="${packages} gcc-${pkg} libc6-dev-${TARGETARCH}-cross"
  # Tell cargo and the cc crate (bundled SQLite, ring) which cross toolchain to use, and
  # openssl-sys where the target's OpenSSL is. rpath-link lets the linker resolve libssl's own
  # dependencies from the target's multiarch directory.
  {
    echo "export CARGO_TARGET_${target_env}_LINKER=${gnu}-gcc"
    echo "export CC_${target_cc}=${gnu}-gcc"
    echo "export AR_${target_cc}=${gnu}-ar"
    echo "export ${target_env}_OPENSSL_LIB_DIR=/usr/lib/${gnu}"
    echo "export ${target_env}_OPENSSL_INCLUDE_DIR=/usr/include"
    echo "export RUSTFLAGS_CROSS='-C link-arg=-Wl,-rpath-link,/usr/lib/${gnu}'"
  } >>/cross-env
fi
# Upstream links arm64 with the Cortex-A53 erratum workaround (vaultwarden#7754); Debian's gcc
# does this by default, but say so explicitly rather than depend on it.
if [ "${TARGETARCH}" = arm64 ]; then
  echo "export RUSTFLAGS_ARCH='-C link-arg=-Wl,--fix-cortex-a53-843419'" >>/cross-env
fi
echo "export CARGO_TARGET_${target_env}_RUSTFLAGS=\"\${RUSTFLAGS_CROSS:-} \${RUSTFLAGS_ARCH:-}\"" >>/cross-env
# Install from the Debian snapshot the builder image records it was made from, so a rebuild gets
# the same compilers and headers, and they move only when Renovate bumps the builder's digest.
# The image's own packages came from the live archive a little later, so allow apt to step one
# back to the snapshot's version: libssl-dev for the target must match the host's exactly. Build
# stage only; the runtime OpenSSL is the distroless image's.
snapshot="$(sed -n '\|^# http://snapshot.debian.org/archive/debian/[0-9TZ]*$| { s|.*/||p; q }' \
  /etc/apt/sources.list.d/debian.sources)"
[ -n "${snapshot}" ] || { echo "builder image records no Debian snapshot" >&2; exit 1; }
apt-get update --snapshot "${snapshot}"
# shellcheck disable=SC2086 # word splitting of the package list is intended
apt-get install --snapshot "${snapshot}" --allow-downgrades -y --no-install-recommends ${packages}
rm -rf /var/lib/apt/lists/*
rustup target add "${target}"
EOF

ARG VAULTWARDEN_VERSION
ARG VAULTWARDEN_COMMIT
ARG WEB_VAULT_IMAGE

# Fetch every input while the network is available: the source at the pinned commit and every
# crate in Cargo.lock (each checked against its recorded sha256). Fetched into image layers rather
# than cache mounts, so the offline build below always finds them, even on a runner whose layer
# cache was restored without the cache mounts.
WORKDIR /src
RUN <<EOF
set -euo pipefail
# Upstream can move a tag; the commit is what gets built. Refuse if they no longer agree. For an
# annotated tag, the peeled ^{} line is the commit.
git ls-remote https://github.com/dani-garcia/vaultwarden.git \
  "refs/tags/${VAULTWARDEN_VERSION}" "refs/tags/${VAULTWARDEN_VERSION}^{}" >/tmp/vw-tag
tagged="$(awk 'NR == 1 || /\^\{\}$/ { c = $1 } END { print c }' /tmp/vw-tag)"
if [ "${tagged}" != "${VAULTWARDEN_COMMIT}" ]; then
  echo "vaultwarden tag ${VAULTWARDEN_VERSION} points at '${tagged}', expected ${VAULTWARDEN_COMMIT}; refusing to build" >&2
  exit 1
fi
git init -q .
git fetch -q --depth 1 https://github.com/dani-garcia/vaultwarden.git "${VAULTWARDEN_COMMIT}"
git checkout -q FETCH_HEAD
rm -rf .git
# The web vault must be the one this release was built and tested with.
pinned="$(sed -n 's/^vault_image_digest: *"\(sha256:[0-9a-f]*\)"/\1/p' docker/DockerSettings.yaml)"
if [ -z "${pinned}" ] || [ "${WEB_VAULT_IMAGE##*@}" != "${pinned}" ]; then
  echo "vaultwarden ${VAULTWARDEN_VERSION} pins web-vault '${pinned}', WEB_VAULT_IMAGE has ${WEB_VAULT_IMAGE##*@}" >&2
  exit 1
fi
# Build with the Rust release upstream pins, which must be the builder image's.
want="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml)"
if [ "${want}" != "${RUST_VERSION}" ]; then
  echo "vaultwarden ${VAULTWARDEN_VERSION} wants Rust ${want}, builder has ${RUST_VERSION}; bump the rust image" >&2
  exit 1
fi
# Build scripts and proc macros run on the build host, so fetch the host's crates too.
cargo fetch --locked --target "$(cat /rust-target)" --target "$(rustc -vV | sed -n 's/^host: //p')"
EOF

# The compile has no network: nothing a build script does can pull in an unpinned input.
# VW_VERSION stops build.rs from asking git for the version.
RUN --network=none \
    --mount=type=cache,target=/cargo-target,id=vaultwarden-target-${TARGETARCH} <<EOF
set -euo pipefail
. /cross-env
export VW_VERSION="${VAULTWARDEN_VERSION}"
CARGO_TARGET_DIR=/cargo-target cargo build --frozen --release \
  --features sqlite --target "$(cat /rust-target)"
mkdir -p /out /rootfs/data
cp "/cargo-target/$(cat /rust-target)/release/vaultwarden" /out/vaultwarden
EOF

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:cc66d222f0a7ec996b78a99fe76a969bc80b539a5016ad866c14d1949bc6d0ab

ARG VAULTWARDEN_VERSION

# Vaultwarden resolves web-vault/ and data/ against the working directory.
WORKDIR /
COPY --from=vault /web-vault /web-vault
COPY --from=builder /out/vaultwarden /vaultwarden
COPY --from=builder --chown=65532:65532 /rootfs/data /data

ENV ROCKET_PROFILE=release \
    ROCKET_ADDRESS=0.0.0.0 \
    ROCKET_PORT=8080

USER 65532:65532
EXPOSE 8080
VOLUME /data

# No HEALTHCHECK: the image has no shell or HTTP client to run one. Probe GET /alive instead.
ENTRYPOINT ["/vaultwarden"]

LABEL org.opencontainers.image.title="vaultwarden" \
      org.opencontainers.image.description="Vaultwarden (Bitwarden-compatible server), built from upstream source on distroless, SQLite only." \
      org.opencontainers.image.version="${VAULTWARDEN_VERSION}" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.url="https://github.com/dani-garcia/vaultwarden" \
      org.opencontainers.image.source="https://github.com/Charg/containers"
