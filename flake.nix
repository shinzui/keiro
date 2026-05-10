{
  description = "A Haskell library that turns Postgres into a unified event-sourcing, process-manager, and durable-execution engine — all expressed as one type-checked state machine.";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        haskellPackages = pkgs.haskell.packages."ghc912";
      in
      {
        packages = {
          default = haskellPackages.keiro;
        };

        checks = {
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.zlib
            pkgs.just
            pkgs.nodejs_22
            pkgs.pnpm
            pkgs.cabal-install
            pkgs.pkg-config
            pkgs.postgresql_18
            (haskellPackages.ghcWithPackages (ps: [
              ps.haskell-language-server
            ]))
          ]
          ++ pkgs.lib.optional true pkgs.process-compose;

          shellHook = ''
            export LANG=en_US.UTF-8

            export PGHOST="$PWD/db"
            export PGDATA="$PGHOST/db"
            export PGLOG=$PGHOST/postgres.log
            export PGDATABASE=keiro
            export PG_CONNECTION_STRING=postgresql://$(jq -rn --arg x $PGHOST '$x|@uri')/$PGDATABASE

            mkdir -p $PGHOST
            mkdir -p .dev

            if [ ! -d $PGDATA ]; then
              initdb --auth=trust --no-locale --encoding=UTF8
            fi
          '';
        };
      }
    );
}
