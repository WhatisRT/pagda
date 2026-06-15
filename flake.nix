{
  description = "Pagda, the package manager for Agda";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

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
      packages = forAllSystems (pkgs: rec {
        # Built without the test suites so installs are fast and robust.
        pagda = import ./default.nix { inherit pkgs; };
        default = pagda;
      });

      apps = forAllSystems (pkgs: rec {
        pagda = {
          type = "app";
          program = nixpkgs.lib.getExe (import ./default.nix { inherit pkgs; });
        };
        default = pagda;
      });

      # An overlay so downstream flakes / NixOS / home-manager configs can pull
      # pagda into their package set: `overlays = [ pagda.overlays.default ]`.
      overlays.default = final: prev: {
        pagda = import ./default.nix { pkgs = final; };
      };

      # `nix flake check` builds pagda and runs its test suites,
      # including the end-to-end tests in test/e2e.
      checks = forAllSystems (pkgs: {
        pagda = import ./default.nix {
          inherit pkgs;
          doCheck = true;
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ (import ./default.nix { inherit pkgs; }).env ];
          packages = [
            pkgs.cabal-install
            pkgs.git
          ];
        };
      });
    };
}
