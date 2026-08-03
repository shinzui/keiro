#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

failed=0

while IFS= read -r cabal_file; do
  for extension in ImportQualifiedPost OverloadedLabels; do
    if ! rg -q "^[[:space:]]+${extension}[[:space:]]*$" "$cabal_file"; then
      echo "extension policy: $cabal_file does not declare $extension in shared Cabal defaults" >&2
      failed=1
    fi
  done
done < <(git ls-files '*.cabal')

for extension in ImportQualifiedPost OverloadedLabels; do
  if ! rg -q "\"${extension}\"" nix/treefmt.nix; then
    echo "extension policy: nix/treefmt.nix does not configure Fourmolu with $extension" >&2
    failed=1
  fi
done

while IFS= read -r haskell_file; do
  case "$haskell_file" in
    Generated/* | */Generated/*) continue ;;
    keiro-dsl/test/conformance-aggregate-scalars/Main.hs | \
      keiro-dsl/test/conformance-nominal-scalars/Main.hs | \
      keiro-dsl/test/conformance-scalar-expressions/Main.hs | \
      keiro-dsl/test/conformance-structural/Main.hs)
      disallowed_extensions='ImportQualifiedPost'
      ;;
    *) disallowed_extensions='ImportQualifiedPost|OverloadedLabels' ;;
  esac
  if rg -n "^\\{-# LANGUAGE (${disallowed_extensions}) #-\\}$" "$haskell_file"; then
    echo "extension policy: $haskell_file duplicates a globally configured extension" >&2
    failed=1
  fi
done < <(git ls-files '*.hs')

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "extension policy: OK"
