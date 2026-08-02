# git-hooks.nix (pre-commit) as a flake-parts module. The dev shell installs the
# hooks via `config.pre-commit.installationScript` (see ./haskell.nix). The old
# flake declared no custom hooks, so only treefmt is wired here.
{ inputs, ... }:
{
  imports = [ inputs.pre-commit-hooks.flakeModule ];

  perSystem = { config, pkgs, ... }: {
    pre-commit.settings.hooks = {
      extension-policy = {
        enable = true;
        name = "global Haskell extension policy";
        entry = "${pkgs.bash}/bin/bash -c 'PATH=${pkgs.git}/bin:${pkgs.ripgrep}/bin:$PATH scripts/check-extension-policy.sh'";
        pass_filenames = false;
      };
      treefmt = {
        enable = true;
        package = config.treefmt.build.wrapper;
        # Keep the hook aligned with nix/treefmt.nix. Pre-commit supplies the
        # staged paths explicitly, so treefmt's own global excludes are not
        # sufficient for create-once and generated conformance fixtures.
        excludes = [ "^keiro-dsl/test/conformance" ];
      };
    };
  };
}
