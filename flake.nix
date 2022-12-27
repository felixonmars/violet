{
  description = "violet programming language";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    idris-lang.url = "github:idris-lang/Idris2";
    idris-lang.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, idris-lang }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        stdenv = pkgs.stdenv;
        makeWrapper = pkgs.makeWrapper;

        idris2 = idris-lang.packages.${system}.idris2;
        rlwrap = pkgs.rlwrap;

        violet = stdenv.mkDerivation {
          name = "violet";
          version = "0.0.1";
          src = ./.;

          buildInputs = [ idris2 ];
          nativeBuildInputs = [ makeWrapper ];
          installPhase = ''
            export HOME=$(pwd)
            make build
            mkdir -p $out/bin
            mv ./build/exec/violet $out/bin/
            mv ./build/exec/violet_app/ $out/bin/
          '';
        };
      in rec {
        packages = { violet = violet; };
        packages.default = packages.violet;
        devShells.default = pkgs.mkShell {
          buildInputs = [ idris2 rlwrap violet ];
        };
      }
    );
}
