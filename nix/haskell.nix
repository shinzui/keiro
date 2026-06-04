# Dev shell, built from the haskell-nix-dev base flake's mkDevShell (GHC 9.12.4 +
# cabal + HLS). This flake is dev-shell-only (no package build), so there is no
# ../flake.module.nix. Add project-specific dev tools via
# `haskellProject.extraDevPackages`, or directly in the extraNativeBuildInputs
# list below.
#
# mkDevShell already provides: the GHC compiler, cabal, HLS (when withHls),
# pkg-config, and zlib, plus a LANG=en_US.UTF-8 export. Only list tools BEYOND
# those in extraNativeBuildInputs.
{ inputs, lib, flake-parts-lib, ... }:
{
  options.perSystem = flake-parts-lib.mkPerSystemOption ({ ... }: {
    options.haskellProject.extraDevPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.ghciwatch ]";
      description = "Extra packages to add to the dev shell.";
    };
  });

  config.perSystem = { system, pkgs, config, ... }:
    let
      hsdev = inputs.haskell-nix-dev.lib.${system};

      mkProjectShell = ghc: hsdev.mkDevShell {
        inherit ghc;
        withHls = true;
        extraNativeBuildInputs =
          [
            pkgs.rdkafka
            pkgs.jq
            pkgs.just
            pkgs.nodejs_22
            pkgs.pnpm
            pkgs.postgresql_18
            pkgs.z3
            pkgs.process-compose
          ]
          ++ config.haskellProject.extraDevPackages;
        shellHook = ''
          ${config.pre-commit.installationScript}

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
    in
    {
      devShells.default = mkProjectShell "ghc9124";
      devShells.ghc9124 = mkProjectShell "ghc9124";
    };
}
