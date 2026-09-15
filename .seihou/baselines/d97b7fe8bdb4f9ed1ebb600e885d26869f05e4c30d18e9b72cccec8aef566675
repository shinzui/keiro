# git-hooks.nix (pre-commit) as a flake-parts module. The dev shell installs the
# hooks via `config.pre-commit.installationScript` (see ./nix/haskell.nix).
# seihou-managed.
{ inputs, ... }:
{
  imports = [ inputs.pre-commit-hooks.flakeModule ];

  perSystem = { config, pkgs, ... }: {
    pre-commit.settings.hooks = {
      commit-message-newlines = {
        enable = true;
        name = "literal newline escapes in commit message";
        entry = "${pkgs.writeShellScript "check-commit-message-newlines" ''
          set -eu

          if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
            echo >&2 "commit-msg hook expected one commit message file"
            exit 2
          fi

          if ${pkgs.gnugrep}/bin/grep -nF '\n' "$1" >&2; then
            echo >&2
            echo >&2 'Commit message contains a literal \n escape; use real line breaks.'
            exit 1
          fi
        ''}";
        stages = [ "commit-msg" ];
      };
      treefmt = {
        enable = true;
        package = config.treefmt.build.wrapper;
      };
    };
  };
}
