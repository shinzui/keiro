#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

failed=0

while IFS= read -r cabal_file; do
  # Generated conformance packages are portable outputs governed by ADR 0019,
  # not repository-authored components. Their generated manifest owns the
  # record trio and OverloadedStrings; specialized syntax stays local.
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

for stanza in shared generated-output; do
  stanza_body="$({ sed -n "/^common ${stanza}$/,/^common /p" keiro-dsl/keiro-dsl.cabal || true; } | sed '$d')"
  for extension in DuplicateRecordFields NoFieldSelectors OverloadedRecordDot; do
    if ! rg -q "^[[:space:]]+${extension}[[:space:]]*$" <<<"$stanza_body"; then
      echo "extension policy: keiro-dsl common ${stanza} does not declare $extension" >&2
      failed=1
    fi
  done
done

for extension in DuplicateRecordFields ImportQualifiedPost NoFieldSelectors OverloadedLabels OverloadedRecordDot; do
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

# Components importing keiro-dsl's shared stanza receive the record trio from
# Cabal. Keep product source free of FieldSelectors escape hatches and local
# copies of those defaults.
while IFS= read -r haskell_file; do
  if rg -n '^\{-# LANGUAGE (DuplicateRecordFields|FieldSelectors|NoFieldSelectors|OverloadedRecordDot) #-\}$' "$haskell_file"; then
    echo "extension policy: $haskell_file overrides or duplicates keiro-dsl shared record defaults" >&2
    failed=1
  fi
done < <(
  git ls-files \
    'keiro-dsl/src/*.hs' \
    'keiro-dsl/app/*.hs' \
    'keiro-dsl/test/Main.hs' \
    'keiro-dsl/test/Keiro/*.hs' \
    'keiro-dsl/bench/*.hs'
)

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

# The skeleton corpus is the deliberately frozen idiomatic-v1 consumer. Every
# replayed idiomatic-v2 Generated module inherits its record syntax from the
# generated manifest and must not carry a local record-default pragma.
while IFS= read -r generated_file; do
  case "$generated_file" in
    keiro-dsl/test/conformance-skeletons/*) continue ;;
  esac
  if rg -n '^\{-# LANGUAGE (DuplicateRecordFields|FieldSelectors|NoFieldSelectors|OverloadedRecordDot) #-\}$' "$generated_file"; then
    echo "extension policy: $generated_file overrides or duplicates idiomatic-v2 record defaults" >&2
    failed=1
  fi
done < <(git ls-files '*.hs' | rg '(^|/)Generated/')

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "extension policy: OK"
