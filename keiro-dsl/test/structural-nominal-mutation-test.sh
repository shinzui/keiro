#!/usr/bin/env bash
# Falsification evidence for structural nominal admission. Exit zero only when
# bypassing the generated-ID parser turns the named negative assertion red.
set -euo pipefail

TARGET="keiro-dsl/test/conformance-structural-nominals/Generated/StructuralNominalLeaves/Structural/NominalLeaves.hs"
BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keiro-structural-nominal-mutation.XXXXXX")"
case "$BACKUP_DIR" in
  *keiro-structural-nominal-mutation.*) ;;
  *) echo "FAIL: unexpected backup path: $BACKUP_DIR"; exit 1 ;;
esac
BACKUP="$BACKUP_DIR/NominalLeaves.hs"
LOG="$BACKUP_DIR/mutation.log"
cp "$TARGET" "$BACKUP"

restore() {
  cp "$BACKUP" "$TARGET"
  rm -f "$BACKUP" "$LOG"
  rmdir "$BACKUP_DIR"
}
trap restore EXIT

run_suite() {
  cabal test keiro-dsl:test:keiro-dsl-conformance-structural-nominals --test-show-details=direct
}

echo "== baseline: structural nominal admission is green =="
run_suite >/dev/null

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = '''parseTemplateIdLeaf :: Value -> Parser Nominals.TemplateId
parseTemplateIdLeaf = withText "TemplateId" (either (fail . T.unpack) pure . Nominals.parseTemplateId)
{-# NOINLINE parseTemplateIdLeaf #-}'''
new = '''parseTemplateIdLeaf :: Value -> Parser Nominals.TemplateId
parseTemplateIdLeaf = withText "TemplateId" (const knownFixture)
  where
    knownFixture = either (fail . T.unpack) pure (Nominals.parseTemplateId Bindings.templateIdText1)
{-# NOINLINE parseTemplateIdLeaf #-}'''
if source.count(old) != 1:
    raise SystemExit("expected exactly one generated TemplateId parser")
path.write_text(source.replace(old, new))
PY

set +e
run_suite >"$LOG" 2>&1
STATUS=$?
set -e
if [[ "$STATUS" -eq 0 ]]; then
  sed -n '1,240p' "$LOG"
  echo "FAIL: bypassing generated TemplateId admission stayed green"
  exit 1
fi
if ! grep -Fq "FAIL  generated TemplateId admission rejects wrong prefix at nested path" "$LOG"; then
  sed -n '1,240p' "$LOG"
  echo "FAIL: admission bypass missed its named negative assertion"
  exit 1
fi
echo "ok: admission bypass turned its named assertion red"

cp "$BACKUP" "$TARGET"
echo "== restored baseline: structural nominal admission is green =="
run_suite >/dev/null
cmp -s "$BACKUP" "$TARGET"
echo "PASS: structural nominal mutation was caught and exact bytes restored"
