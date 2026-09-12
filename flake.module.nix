# flake.module.nix — project-specific flake-parts customizations.
#
# seihou does NOT manage this file: it is never regenerated or overwritten by
# `seihou run` or module migrations, so it is the conflict-free home for every
# customization that must survive nix-haskell-flake template upgrades. See
# flake.module.nix.example for the full option list.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ REQUIRED: this file MUST be git-tracked (`git add flake.module.nix`).      │
# │ Nix flakes evaluate only files tracked by git, so flake.nix's             │
# │ `builtins.pathExists ./flake.module.nix` import guard sees an untracked   │
# │ file as ABSENT and silently ignores everything below.                     │
# └──────────────────────────────────────────────────────────────────────────┘
{ inputs, ... }:
{
  perSystem = { pkgs, config, ... }: {
    # Extra dev-shell tools with no module variable of their own. Relocated here
    # from the old inline nix/haskell.nix so template upgrades stop conflicting.
    #
    #   git: automation reactions run as `nix develop --command`, and the
    #        daemon's own PATH does not carry ~/.nix-profile/bin. Without git in
    #        the shell, scripts/record-release.sh dies on `git for-each-ref`.
    #   z3:  SMT solver used by the keiro-syntax / property test tooling.
    haskellProject.extraDevPackages = [ pkgs.git pkgs.z3 ];

    treefmt = {
      # Take fourmolu from the ghc9124 package set so it matches the project
      # compiler (nix/treefmt.nix leaves the package at treefmt-nix's default).
      programs.fourmolu.package = pkgs.haskell.packages.ghc9124.fourmolu;

      # The keiro-dsl conformance slice is captured/scaffolded fixture source
      # (the `-- @generated` Generated.* modules plus a hand-filled Holes.hs).
      # It must stay byte-stable: the scaffold-conformance test pins the live
      # `keiro-dsl scaffold` output against these files, and reformatting them
      # (e.g. reordering imports) would spuriously break that pin.
      settings.global.excludes = [
        "keiro-dsl/test/conformance*/*"
        "keiro-dsl/test/conformance*/**/*"
      ];
    };

    # Project-specific git hooks (nix/pre-commit.nix wires only treefmt).
    pre-commit.settings.hooks = {
      extension-policy = {
        enable = true;
        name = "global Haskell extension policy";
        entry = "${pkgs.bash}/bin/bash -c 'PATH=${pkgs.git}/bin:${pkgs.ripgrep}/bin:$PATH scripts/check-extension-policy.sh'";
        pass_filenames = false;
      };
      # Extend the managed treefmt hook: pre-commit passes staged paths
      # explicitly, so treefmt's own global excludes are not enough for the
      # create-once / generated conformance fixtures.
      treefmt.excludes = [ "^keiro-dsl/test/conformance" ];
    };
  };
}
