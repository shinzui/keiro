#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

failed=0

while IFS= read -r haskell_file; do
  [[ -f "$haskell_file" ]] || continue

  IFS='/' read -r -a path_components <<<"$haskell_file"
  for component in "${path_components[@]}"; do
    if [[ "$component" =~ [A-Za-z0-9]_[A-Za-z0-9] ]]; then
      echo "generated Haskell name policy: $haskell_file has underscore-bearing module component $component" >&2
      failed=1
    fi
  done

  if rg -n '^module[[:space:]]+[A-Za-z0-9_.]*_[A-Za-z0-9_.]*([[:space:]]|$)' "$haskell_file"; then
    echo "generated Haskell name policy: $haskell_file declares an underscore-bearing module" >&2
    failed=1
  fi
done < <(git ls-files 'keiro-dsl/test/conformance*.hs' 'keiro-dsl/test/conformance*/**/*.hs')

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

# This focused suite inventories declarations from a fresh scaffold and proves
# an underscore mutation is rejected before writes. It deliberately leaves
# snake_case strings, comments, and hand-owned function bodies outside the
# repository path/declaration scan above.
cabal test keiro-dsl-test --test-options='--match Haskell.name-audit'

echo "generated Haskell name policy: OK"
