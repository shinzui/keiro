#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

failed=0

while IFS= read -r cabal_file; do
  # Generated conformance packages are portable outputs governed by ADR 0019,
  # not repository-authored components: their sole shared extension remains
  # OverloadedStrings, and specialized syntax stays local to generated modules.
  case "$cabal_file" in
    */keiro-dsl-conformance.*/*.cabal) continue ;;
  esac
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

while IFS= read -r generated_file; do
  while IFS= read -r line; do
    if [[ "$line" =~ ^\{\-\#\ LANGUAGE\ ([A-Za-z][A-Za-z0-9_]*)\ \#-\}$ ]]; then
      extension="${BASH_REMATCH[1]}"
    else
      break
    fi

    case "$extension" in
      BlockArguments | \
        DeriveAnyClass | \
        DuplicateRecordFields | \
        OverloadedLabels | \
        OverloadedRecordDot | \
        QualifiedDo | \
        TemplateHaskell | \
        TypeFamilies) ;;
      *)
        echo "extension policy: $generated_file declares unsupported generated extension $extension" >&2
        failed=1
        ;;
    esac
  done <"$generated_file"
done < <(git ls-files '*.hs' | rg '(^|/)Generated/')

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "extension policy: OK"
