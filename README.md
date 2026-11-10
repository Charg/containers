# containers

Container images published to GitHub Packages at `ghcr.io/charg/containers/<name>`, built for
`linux/amd64` and `linux/arm64`, signed keylessly with cosign, with SBOM and build provenance
attached. Companion to [Charg/charts](https://github.com/Charg/charts).

| Image | Description |
| ----- | ----------- |
| [anki-sync-server](images/anki-sync-server) | Anki's self-hosted sync server, built from upstream source on distroless. |

## Using an image

```bash
docker run -d -p 8080:8080 -e SYNC_USER1=user:pass \
  -v anki-data:/anki_data ghcr.io/charg/containers/anki-sync-server:26.09.4
```

Each image is published under two tags:

- `26.09.4`: the upstream version. It **moves**: it's rebuilt in place when the base image picks
  up security fixes or the image's Dockerfile changes.
- `26.09.4-<hash>`: the version plus the first 12 hex digits of a hash of the image's inputs
  (`images/<name>/`). It **never moves**; the release job refuses to overwrite it.

For deployments, pin by digest (`ghcr.io/charg/containers/anki-sync-server@sha256:...`), or use the immutable
tag and check that it resolves to a signed digest.

### Verifying an image

Every image index is signed keylessly by the release workflow on `main`:

```bash
cosign verify ghcr.io/charg/containers/anki-sync-server:26.09.4 \
  --certificate-identity https://github.com/Charg/containers/.github/workflows/release.yaml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Build provenance (SLSA, from GitHub's attestation service):

```bash
gh attestation verify oci://ghcr.io/charg/containers/anki-sync-server:26.09.4 --repo Charg/containers
```

Each platform image also carries a signed Trivy vulnerability report (cosign `vuln` attestation)
recorded at publish time. These are attached to the per-platform digests, which
`docker buildx imagetools inspect ghcr.io/charg/containers/anki-sync-server:26.09.4` lists:

```bash
cosign verify-attestation --type vuln \
  --certificate-identity https://github.com/Charg/containers/.github/workflows/release.yaml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/charg/containers/anki-sync-server@sha256:<platform digest> | jq -r .payload | base64 -d | jq .predicate
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
published image is signed by digest, verified in the same run, given a signed vulnerability
attestation per platform, and checked to be pullable anonymously. If the immutable tag for the
current inputs already exists (a revert), the version tag is pointed back at that signed image
rather than rebuilt.

Builds take no mutable references: base images and the Dockerfile frontend are pinned by digest,
and upstream source is fetched by commit (`ANKI_COMMIT`), not by tag. The build fails if the
upstream release tag no longer points at that commit.

Renovate bumps upstream versions with their commits (e.g. `ANKI_VERSION` and `ANKI_COMMIT` from
the ankitects/anki releases), base image digests, GitHub Actions and the flake lock, and
auto-merges once CI passes. A new commit under an unchanged version means upstream moved a
release tag; that PR is labelled `moved-tag` and waits for a human.

Every image must be public. New packages have come out public with no manual step, apparently
because each image's source annotation links it to this public repo. The release job still checks
each publish with an anonymous pull and fails if it's denied.
