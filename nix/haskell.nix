# Haskell project wiring: dev shells (via the haskell-nix-dev base flake) and the
# project package (via callCabal2nix). seihou-managed — to add project-specific
# dev tools without editing this file, set `haskellProject.extraDevPackages` from
# ./flake.module.nix (see flake.module.nix.example).
{ inputs, lib, flake-parts-lib, ... }:
{
  options.perSystem = flake-parts-lib.mkPerSystemOption ({ ... }: {
    options.haskellProject = {
      runtime = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            runtimeSelection = lib.mkOption {
              type = lib.types.raw;
              description = "Explicit retained name, generation, channel and compiler/build configuration.";
            };
            applicationSelections = lib.mkOption {
              type = lib.types.raw;
              description = "Explicit complementary application selections for this retained runtime.";
            };
            applicationCohort = lib.mkOption { type = lib.types.nullOr lib.types.attrs; default = null; };
            applicationRegistry = lib.mkOption { type = lib.types.attrs; default = { }; };
          };
        });
        default = null;
        description = "Opt into one checked retained scope for project builds and the primary development shell.";
      };
      ownPackages = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "All application-owned recipes. The root or dependent scaffold declares its own packages.";
      };
      applicationOverlays = lib.mkOption {
        type = lib.types.listOf lib.types.raw;
        default = [ ];
        description = "Application-only overlays composed in declaration order; shared/runtime overrides are rejected in runtime mode.";
      };
      packageSource = lib.mkOption {
        type = lib.types.nullOr lib.types.raw;
        default = null;
        description = "Audited source for the built-in root package; null preserves the complete original flake source.";
      };
      applicationScope = lib.mkOption {
        type = lib.types.raw;
        readOnly = true;
        description = "Checked project scope; select production packages from this same scope.";
      };
      packageSetIdentity = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        readOnly = true;
        description = "Retained runtime diagnostics, or null for a bare shell.";
      };
      extraDevPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        example = lib.literalExpression "[ pkgs.ghciwatch pkgs.haskellPackages.hpack ]";
        description = "Additional native development tools from the unmanaged extension.";
      };
      extraBuildInputs = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "Additional native libraries and headers.";
      };
      inputsFrom = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "Compatible environment inheritance; runtime mode rejects a second compiler.";
      };
      withHls = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Runtime mode follows actual HLS availability when null; explicit unsupported requests fail.";
      };
      shellHook = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Project hook appended once after the generated service environment.";
      };
    };
  });

  config.perSystem = { system, pkgs, config, ... }:
    let
      hsdev = inputs.haskell-nix-dev.lib.${system};
      project = config.haskellProject;
      runtimeEnabled = project.runtime != null;
      applicationOverlay =
        assert lib.assertMsg (builtins.all builtins.isFunction project.applicationOverlays)
          "haskellProject.applicationOverlays must contain overlay functions";
        lib.composeManyExtensions project.applicationOverlays;
      barePackages = pkgs.haskell.packages."ghc9124";
      bareScope =
        if project.applicationOverlays == [ ] then barePackages
        else barePackages.override { overrides = applicationOverlay; };
      applicationScope = if runtimeEnabled then runtimeShell.applicationScope else bareScope;

      baseDevPackages = [
        pkgs.zlib
        pkgs.just
        pkgs.pkg-config
        # All three postgres entries are load-bearing for anything that builds
        # postgresql-libpq (hasql, postgresql-simple, persistent-postgresql, ...).
        # `pkgs.postgresql` is only the `out` output; `lib/pkgconfig/libpq.pc`
        # lives in `dev`, and that .pc file in turn declares
        # `Requires.private: libssl libcrypto`, which postgresql.dev does not
        # propagate. Drop either `.dev` and pkg-config cannot resolve libpq at
        # all, so postgresql-libpq dies in its configure step.
        #
        # This failure hides well: once that unit is in the cabal store a plain
        # `cabal build` never reconfigures it, so the shell looks fine until
        # something forces a fresh configure -- `cabal build --enable-profiling`
        # does exactly that, because the profiling way changes the unit-id hash.
        pkgs.postgresql_18
        pkgs.postgresql_18.dev
        pkgs.openssl.dev
        pkgs.jq
        # librdkafka (nixpkgs: rdkafka). hw-kafka-client links -lrdkafka; both
        # the runtime lib and its .dev (headers + pkg-config) are needed.
        pkgs.rdkafka
        pkgs.rdkafka.dev
        pkgs.process-compose
      ];

      shellHook = ''
        ${config.pre-commit.installationScript}

        export PGHOST="$PWD/db"
        export PGDATA="$PGHOST/db"
        export PGLOG=$PGHOST/postgres.log
        export PGDATABASE=keiro
        export PG_CONNECTION_STRING="postgresql://$(jq -rn --arg x "$PGHOST" '$x|@uri')/$PGDATABASE"

        mkdir -p "$PGHOST"
        mkdir -p .dev

        if [ ! -d "$PGDATA" ]; then
          initdb --auth=trust --no-locale --encoding=UTF8
        fi

        # Make librdkafka discoverable to GHC's linker, the C preprocessor, and
        # pkg-config (hw-kafka-client links -lrdkafka).
        export CPATH="${pkgs.rdkafka.dev}/include''${CPATH:+:$CPATH}"
        export LIBRARY_PATH="${pkgs.rdkafka}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
        export PKG_CONFIG_PATH="${pkgs.rdkafka.dev}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
      '';

      runtimeLibraries = [ pkgs.zlib ]
        ++ [ pkgs.postgresql_18.dev pkgs.openssl.dev ]
        ++ [ pkgs.rdkafka pkgs.rdkafka.dev ]
      ;
      runtimeShell =
        assert lib.assertMsg (inputs.haskell-nix.lib ? mkProjectDevShell && hsdev ? mkProjectShell)
          "haskellProject.runtime requires the published retained-runtime shell APIs";
        assert lib.assertMsg (project.runtime.runtimeSelection.configuration.compiler == "ghc9124")
          "haskellProject.runtime compiler must match the configured primary ghc.version";
        inputs.haskell-nix.lib.mkProjectDevShell {
          inherit pkgs;
          inherit (project.runtime) runtimeSelection applicationSelections applicationCohort applicationRegistry;
          inherit (project) ownPackages withHls inputsFrom;
          applicationOverrides = applicationOverlay;
          toolchainLib = hsdev;
          extraNativeBuildInputs = builtins.filter (p: !(builtins.elem p runtimeLibraries)) baseDevPackages
            ++ project.extraDevPackages;
          extraBuildInputs = runtimeLibraries ++ project.extraBuildInputs;
          shellHook = shellHook + project.shellHook;
        };
      mkBareShell = ghc:
        assert lib.assertMsg (builtins.hasAttr ghc hsdev.ghcVersions)
          "Unknown or unavailable Haskell compiler: ${ghc}";
        assert lib.assertMsg
          (project.withHls != true
            || (hsdev.toolchainCapabilities.compilers.${ghc}.hlsAvailable or false))
          "HLS explicitly requested but unavailable for ${ghc} on ${system}";
        let
          legacy = hsdev.mkDevShell {
            inherit ghc;
            extraNativeBuildInputs = baseDevPackages ++ project.extraDevPackages;
            withHls = if project.withHls == null then true else project.withHls;
            shellHook = shellHook + project.shellHook;
          };
        in
        if project.extraBuildInputs == [ ] && project.inputsFrom == [ ] then legacy
        else
          pkgs.mkShell {
            inputsFrom = [ legacy ] ++ project.inputsFrom;
            buildInputs = project.extraBuildInputs;
          };
      primaryShell = if runtimeEnabled then runtimeShell else mkBareShell "ghc9124";
    in
    {
      # Match the toolchain's import, including its library metadata. Explicit
      # caller package-set overrides retain their normal higher priority.
      _module.args.pkgs = lib.mkIf runtimeEnabled
        (lib.mkDefault (import inputs.nixpkgs { inherit system; }));
      haskellProject = {
        inherit applicationScope;
        packageSetIdentity = if runtimeEnabled then runtimeShell.packageSetIdentity else null;
      };
      devShells.default = primaryShell;
      devShells."ghc9124" = primaryShell;
    };
}
