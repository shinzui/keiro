# nix-direnv automatically watches flake.nix and flake.lock, but not local
# modules imported by the flake. Watch every managed module plus the optional
# unmanaged extensions so changes refresh the dev shell and installed hooks.
# .envrc.local is watched too so creating it (or editing it) reloads direnv.
watch_file nix/haskell.nix nix/treefmt.nix nix/pre-commit.nix flake.module.nix .envrc.local

# A flake.lock that git does not track is INVISIBLE to Nix inside a git work tree:
# `use flake` below would silently re-resolve every input to its latest upstream, so this
# project would get a different nixpkgs from every other project on the same module
# version — a full toolchain rebuild instead of a cache hit. Fail loudly rather than let
# that happen quietly.
if [ -e flake.lock ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
  ! git ls-files --error-unmatch flake.lock >/dev/null 2>&1; then
  log_error "flake.lock is not tracked by git; Nix ignores it and will re-resolve every input."
  log_error "Fix with: git add flake.lock"
fi

use flake
eval "$shellHook"

# Project-specific direnv extensions live in an unmanaged, gitignored
# .envrc.local that seihou never regenerates, so per-project exports survive
# every template upgrade without a conflict. It is sourced last (after
# `eval "$shellHook"`), so it can read anything the dev-shell shellHook
# exported — e.g. `export MY_URL="${PG_CONNECTION_STRING}"`. Use direnv/bash
# syntax here, not a static KEY=VALUE dotenv file.
source_env_if_exists .envrc.local
