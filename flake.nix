{
  description = "Container images built from upstream source, published to ghcr.io/charg/containers";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            # Task runner and git hooks.
            pkgs.just
            pkgs.prek
            # Lint (hack/lint.sh).
            pkgs.actionlint
            pkgs.nixfmt
            pkgs.shellcheck
            pkgs.yamllint
            pkgs.zizmor
            # container-images flavour: builds through the host's docker daemon with buildx, so
            # multi-arch builds work the same everywhere; lint in hack/lint.d/container-images.sh.
            pkgs.docker-client
            pkgs.docker-buildx
            pkgs.hadolint
            # Used by the scripts directly.
            pkgs.git
            # Scanning and signing.
            pkgs.trivy
            pkgs.cosign
            # Registry probing and JSON assembly.
            pkgs.curl
            pkgs.jq
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
