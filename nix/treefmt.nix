# treefmt-nix as a flake-parts module (wires `nix fmt` + a treefmt flake check).
# fourmolu is taken from the ghc9124 package set so it matches the project's
# compiler. Formatter set preserved from the old top-level treefmt.nix:
# nixpkgs-fmt + fourmolu + cabal-fmt.
{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem = { pkgs, ... }:
    let
      haskellPkgs = pkgs.haskell.packages.ghc9124;
    in
    {
      treefmt = {
        projectRootFile = "flake.nix";
        programs.nixpkgs-fmt.enable = true;
        programs.fourmolu.enable = true;
        programs.fourmolu.package = haskellPkgs.fourmolu;
        programs.cabal-fmt.enable = true;
      };
    };
}
