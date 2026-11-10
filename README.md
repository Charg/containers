# containers

Container images published to GitHub Packages at `ghcr.io/charg/<name>`, built for
`linux/amd64` and `linux/arm64`, signed keylessly with cosign, with SBOM and build provenance
attached. Companion to [Charg/charts](https://github.com/Charg/charts).

| Image | Description |
| ----- | ----------- |
| [anki-sync-server](images/anki-sync-server) | Anki's self-hosted sync server, built from upstream source on distroless. |

## Using an image

```bash
docker run -d -p 8080:8080 -e SYNC_USER1=user:pass \
  -v anki-data:/anki_data ghcr.io/charg/anki-sync-server:26.09.4
```

Tags follow the upstream version. A tag is rebuilt in place when its base image picks up
security fixes, so pin by digest if you need byte-for-byte reproducibility.

Verify a signature:

```bash
cosign verify ghcr.io/charg/anki-sync-server:26.09.4 \
  --certificate-identity-regexp '^https://github.com/Charg/containers/\.github/workflows/release\.yaml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Local development

Requires nix with flakes enabled and a working Docker daemon. The flake provides the whole
toolchain (buildx, trivy, cosign, shellcheck, hadolint, actionlint, yamllint, just).

```bash
nix develop
just                          # list recipes
just lint                     # shellcheck, hadolint, actionlint, yamllint
just check anki-sync-server   # build for the host, run its smoke test, scan it
just build-all anki-sync-server  # cross-build every platform
just plan                     # what the release workflow would publish
```

CI runs these same recipes.

## Layout

```
flake.nix          the toolchain; flake.lock pins every tool version
justfile           recipes; each is a one-line shim over hack/
hack/              every real command
images/<name>/     Dockerfile and test.sh for one image
.github/           workflows and Renovate config
```

## Releases

Pull requests build, test and scan each changed image, and cross-build every platform.

Every push to `main` runs `just plan`, which asks the registry what's published. An image is
published when its version tag is missing, or when the hash of `images/<name>/` recorded on the
published image doesn't match the checkout (a base-image digest bump, a Dockerfile change). Each
published image is signed by digest, verified in the same run, and checked to be pullable
anonymously.

Renovate bumps upstream versions (e.g. `ANKI_VERSION` from the ankitects/anki releases), base
image digests, GitHub Actions and the flake lock, and auto-merges once CI passes.

Every image must be public. New packages have come out public with no manual step, apparently
because each image's source annotation links it to this public repo. The release job still checks
each publish with an anonymous pull and fails if it's denied.
