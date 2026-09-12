# treefmt-nix as a flake-parts module. This automatically wires `nix fmt`
# (the flake `formatter`) and a `treefmt` flake check. seihou-managed.
{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem = { ... }: {
    treefmt = {
      projectRootFile = "flake.nix";
      programs.nixpkgs-fmt.enable = true;
      programs.fourmolu.enable = true;
      # fourmolu can't auto-detect "manual" extensions, so they must be passed
      # explicitly. Override treefmt-nix's defaults (BangPatterns,
      # PatternSynonyms, TypeApplications) with what this project actually needs.
      programs.fourmolu.ghcOpts = [ "GHC2024" "DuplicateRecordFields" "ImportQualifiedPost" "NoFieldSelectors" "OverloadedLabels" "OverloadedRecordDot" ];
      # cabal-gild (github.com/tfausak/cabal-gild) formats *.cabal plus
      # cabal.project/cabal.project.local, and can discover module lists from
      # the filesystem via `-- cabal-gild: discover <dir>` pragmas.
      programs.cabal-gild.enable = true;
    };
  };
}
