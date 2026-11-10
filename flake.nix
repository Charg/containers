{
  description = "Container images: development toolchain and CI environment";

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
            pkgs.just
            # Builds: the docker CLI talks to the host daemon; buildx drives a
            # docker-container builder so multi-arch builds work the same everywhere.
            pkgs.docker-client
            pkgs.docker-buildx
            # Scanning and signing.
            pkgs.trivy
            pkgs.cosign
            # Lint.
            pkgs.shellcheck
            pkgs.hadolint
            pkgs.actionlint
            pkgs.yamllint
            # Used by the scripts directly: registry probing and JSON assembly.
            pkgs.git
            pkgs.curl
            pkgs.jq
          ];
        };
      });
    };
}
