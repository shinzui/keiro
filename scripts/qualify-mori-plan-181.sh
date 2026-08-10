#!/usr/bin/env bash
# Replay mori://shinzui/mori/plans/181-add-dependency-version-constraints-and-upstream-pointers
# against the candidate Keiro DSL without reading from or writing to Mori's moving worktree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BEFORE_REV="6a97469f7132ab5febc950e1da11fdb9e10f90b8"
AFTER_REV="e3f05b3ae461483e61a732a8959dc2a14f181807"
MORI_URI="mori://shinzui/mori"

cd "$ROOT"

MORI_PATH="$(mori path "$MORI_URI" | tail -n 1)"
if [[ ! -d "$MORI_PATH/.git" ]]; then
  echo "FAIL: Mori did not resolve to a Git checkout: $MORI_PATH"
  exit 1
fi
git -C "$MORI_PATH" cat-file -e "$BEFORE_REV^{commit}"
git -C "$MORI_PATH" cat-file -e "$AFTER_REV^{commit}"

SOURCE_DELTA="$(git -C "$MORI_PATH" diff --name-only "$BEFORE_REV" "$AFTER_REV" -- domain)"
EXPECTED_SOURCE_DELTA=$'domain/project-artifact.keiro\ndomain/project.keiro'
if [[ "$SOURCE_DELTA" != "$EXPECTED_SOURCE_DELTA" ]]; then
  echo "FAIL: pinned Mori revisions no longer describe the two-member Plan 181 source delta"
  printf '%s\n' "$SOURCE_DELTA"
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keiro-mori-plan181.XXXXXX")"
case "$WORK_DIR" in
  *keiro-mori-plan181.*) ;;
  *) echo "FAIL: unexpected qualification path: $WORK_DIR"; exit 1 ;;
esac
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

BEFORE_TREE="$WORK_DIR/before"
AFTER_TREE="$WORK_DIR/after"
BEFORE_OUT="$WORK_DIR/before-out"
AFTER_OUT="$WORK_DIR/after-out"
DIFF_TREE="$WORK_DIR/diff"
mkdir -p "$BEFORE_TREE" "$AFTER_TREE" "$DIFF_TREE/domain"

git -C "$MORI_PATH" archive "$BEFORE_REV" domain | tar -xf - -C "$BEFORE_TREE"
git -C "$MORI_PATH" archive "$AFTER_REV" domain | tar -xf - -C "$AFTER_TREE"

DSL_BINARY="$(cabal list-bin keiro-dsl:exe:keiro-dsl)"
"$DSL_BINARY" scaffold "$BEFORE_TREE/domain/mori.keiro-workspace" --out "$BEFORE_OUT" >"$WORK_DIR/before-scaffold.log" 2>&1
"$DSL_BINARY" scaffold "$AFTER_TREE/domain/mori.keiro-workspace" --out "$AFTER_OUT" >"$WORK_DIR/after-scaffold.log" 2>&1

set +e
git diff --no-index --name-only "$BEFORE_OUT" "$AFTER_OUT" >"$WORK_DIR/changed-absolute.txt"
NAME_STATUS=$?
git diff --no-index --numstat "$BEFORE_OUT" "$AFTER_OUT" >"$WORK_DIR/numstat.txt"
NUMSTAT_STATUS=$?
set -e
if [[ "$NAME_STATUS" -ne 1 || "$NUMSTAT_STATUS" -ne 1 ]]; then
  echo "FAIL: expected a non-empty generated-tree delta; git diff statuses were $NAME_STATUS/$NUMSTAT_STATUS"
  exit 1
fi

awk -v prefix="$AFTER_OUT/" '
  index($0, prefix) == 1 { print substr($0, length(prefix) + 1); next }
  { print }
' "$WORK_DIR/changed-absolute.txt" >"$WORK_DIR/changed.txt"

printf '%s\n' \
  'Mori/Modules/Generated/BehaviorSourceMap.hs' \
  'Mori/Modules/Generated/Structural/Shape/DependencyArtifactPayload.hs' \
  'Mori/Modules/Generated/Structural/Shape/ProjectMetadataPayload.hs' \
  'Mori/Modules/Generated/Structural/Shape/RepositoryRefArtifactPayload.hs' \
  'Mori/Modules/Generated/StructuralConformance.hs' \
  'Mori/Modules/Project/Domain/KeiroBindings.hs' \
  'Mori/Modules/Project/Generated/Codec.hs' \
  'Mori/Modules/Project/Generated/Harness.hs' \
  'Mori/Modules/ProjectArtifact/Generated/Codec.hs' \
  'Mori/Modules/ProjectArtifact/Generated/Harness.hs' \
  'keiro-dsl-ledger.workspace.mori.txt' >"$WORK_DIR/expected-changed.txt"

if ! cmp -s "$WORK_DIR/expected-changed.txt" "$WORK_DIR/changed.txt"; then
  echo "FAIL: Mori Plan 181 changed files escaped the exact locality allowlist"
  diff -u "$WORK_DIR/expected-changed.txt" "$WORK_DIR/changed.txt" || true
  exit 1
fi

read -r HASKELL_FILES HASKELL_LINES GENERATED_FILES GENERATED_LINES SEMANTIC_FILES SEMANTIC_LINES SOURCE_MAP_LINES BINDING_LINES < <(
  awk '
    /\.hs$/ {
      haskellFiles += 1; haskellLines += $1 + $2
      if ($0 !~ /\/Domain\/KeiroBindings\.hs$/) {
        generatedFiles += 1; generatedLines += $1 + $2
      }
      if ($0 !~ /\/Domain\/KeiroBindings\.hs$/ && $0 !~ /\/BehaviorSourceMap\.hs$/) {
        semanticFiles += 1; semanticLines += $1 + $2
      }
      if ($0 ~ /\/BehaviorSourceMap\.hs$/) sourceMapLines += $1 + $2
      if ($0 ~ /\/Domain\/KeiroBindings\.hs$/) bindingLines += $1 + $2
    }
    END { print haskellFiles, haskellLines, generatedFiles, generatedLines, semanticFiles, semanticLines, sourceMapLines, bindingLines }
  ' "$WORK_DIR/numstat.txt"
)

if [[ "$HASKELL_FILES/$HASKELL_LINES" != "10/641" ]]; then
  echo "FAIL: total Haskell delta changed: $HASKELL_FILES files / $HASKELL_LINES lines"
  exit 1
fi
if [[ "$GENERATED_FILES/$GENERATED_LINES" != "9/629" ]]; then
  echo "FAIL: generated Haskell delta changed: $GENERATED_FILES files / $GENERATED_LINES lines"
  exit 1
fi
if [[ "$SEMANTIC_FILES/$SEMANTIC_LINES" != "8/27" || "$SOURCE_MAP_LINES" != "602" || "$BINDING_LINES" != "12" ]]; then
  echo "FAIL: semantic/source-map/binding line partitions changed"
  echo "  semantic=$SEMANTIC_FILES/$SEMANTIC_LINES source-map=$SOURCE_MAP_LINES binding=$BINDING_LINES"
  exit 1
fi

# Build an isolated Git history for the public diff command. This does not use
# or alter Mori's index or worktree.
cp -R "$BEFORE_TREE/domain/." "$DIFF_TREE/domain/"
git init -q "$DIFF_TREE"
git -C "$DIFF_TREE" add domain
git -C "$DIFF_TREE" -c user.name=Keiro -c user.email=keiro@example.invalid commit -qm baseline
cp -R "$AFTER_TREE/domain/." "$DIFF_TREE/domain/"
(
  cd "$DIFF_TREE"
  "$DSL_BINARY" diff domain/mori.keiro-workspace --since HEAD --report-out semantic-impact.json >"$WORK_DIR/diff.log" 2>&1
)

jq -e '
  .semanticImpact.declarations == [
    {
      "currentConsumers": ["ProjectArtifact"],
      "declaration": "DependencyArtifactPayload",
      "previousConsumers": ["ProjectArtifact"],
      "serviceConformance": true
    },
    {
      "currentConsumers": ["Project"],
      "declaration": "ProjectMetadataPayload",
      "previousConsumers": ["Project"],
      "serviceConformance": true
    },
    {
      "currentConsumers": ["ProjectArtifact"],
      "declaration": "RepositoryRefArtifactPayload",
      "previousConsumers": ["ProjectArtifact"],
      "serviceConformance": true
    }
  ]
' "$DIFF_TREE/semantic-impact.json" >/dev/null

echo "PASS: pinned Mori Plan 181 replay is semantically local and source-stable"
echo "  generated Haskell: 9 files / 629 changed lines (historical: 22 / 1869)"
echo "  semantic generated delta: 8 files / 27 changed lines"
echo "  isolated source-map delta: 1 file / 602 changed lines"
echo "  create-once binding skeleton: 1 file / 12 changed lines"
echo "  consumers: Project, ProjectArtifact; declarations: 3; service conformance: impacted"
