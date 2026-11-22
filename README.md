# containers

Container images at `ghcr.io/charg/containers/<name>`, built from upstream source for
`linux/amd64` and `linux/arm64`. Every image is reproducible, signed with cosign, and ships with an
SBOM and build provenance. Companion to [Charg/charts](https://github.com/Charg/charts).

| Image | Description |
| ----- | ----------- |
| [anki-sync-server](images/anki-sync-server) | Anki's self-hosted sync server, on distroless. |
| [vaultwarden](images/vaultwarden) | Bitwarden-compatible server, on distroless, SQLite only. |

## Usage

```bash
docker run -d -p 8080:8080 -e SYNC_USER1=user:pass \
  -v anki-data:/anki_data ghcr.io/charg/containers/anki-sync-server:26.09.4
```

Tags:

- `26.09.4`: the upstream version. Moves when the image is rebuilt (base-image fixes, Dockerfile
  changes).
- `26.09.4-<hash>`: immutable; the release job refuses to overwrite it. The hash covers the
  image's inputs (`images/<name>/`).

In production, pin by digest, or use the immutable tag and verify it (below). Every image is
public: no login needed to pull.

## Verifying

```bash
IMG=ghcr.io/charg/containers/anki-sync-server:26.09.4
ID=https://github.com/Charg/containers/.github/workflows/release.yaml@refs/heads/main
ISSUER=https://token.actions.githubusercontent.com

cosign verify "$IMG" --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER"
gh attestation verify "oci://$IMG" --repo Charg/containers
```

Each platform digest (listed by `docker buildx imagetools inspect "$IMG"`) also carries a signed
Trivy report, readable with `cosign verify-attestation --type vuln` and the same identity flags.

## Development

Requires nix (with flakes) and Docker. The flake pins the whole toolchain.

```bash
nix develop
just                    # list recipes
just lint
just check <name>       # build for the host, smoke test, scan
just build-all <name>   # cross-build every platform
just plan               # what merging to main would publish
just repro [name]       # amd64, at the publishing commit: rebuild and compare digests
```

CI runs the same recipes. Adding an image is covered in [AGENTS.md](AGENTS.md).

## Releases

1. **Open a PR.** CI builds, tests, scans and cross-builds each changed image.
2. **Merge to `main`.** Any image whose version tag is missing, or whose inputs changed, is
   published, signed and verified.

That's it. Renovate opens the PRs for upstream releases, base-image digests, actions and the flake
lock, waits 7 days after each release, and auto-merges patches, minors and digest bumps once CI
passes. These wait for a human:

- Major updates, and Rust or BuildKit minor bumps.
- A `moved-tag` PR: upstream moved a release tag to a new commit.
- A red `vaultwarden` PR: the web vault bumped before the server release that pins it.

A weekly job rebuilds every published image from scratch and fails unless the digests match.
