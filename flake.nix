{
  description = "Meddle with files in the nix store without breaking your system";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
  flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages = rec {
        nix-merge = with import nixpkgs { system = system; };
        stdenv.mkDerivation {
        name = "nix-merge";
        phases = "installPhase";
        source = self;
        installPhase = ''
          mkdir -p $out/bin
          cp $source/nix-merge.sh $out/bin/nix-merge
          '';
        };
        default = nix-merge;
      };
      devShells.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          gum
          oil
        ];
        # shellHook = ''
        #   PYTHONPATH=${python-with-my-packages}/${python-with-my-packages.sitePackages}
        # '';
      };
    });
}

