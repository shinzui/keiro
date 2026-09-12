# git-hooks.nix (pre-commit) as a flake-parts module. The dev shell installs the
# hooks via `config.pre-commit.installationScript` (see ./nix/haskell.nix).
# seihou-managed.
{ inputs, ... }:
{
  imports = [ inputs.pre-commit-hooks.flakeModule ];

  perSystem = { config, ... }: {
    pre-commit.settings.hooks = {
      treefmt = {
        enable = true;
        package = config.treefmt.build.wrapper;
      };
    };
  };
}
