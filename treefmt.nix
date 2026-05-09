{ pkgs, ... }:
{
  projectRootFile = "flake.nix";
  programs.nixpkgs-fmt.enable = true;
  programs.fourmolu.enable = true;
  programs.cabal-fmt.enable = true;
}
