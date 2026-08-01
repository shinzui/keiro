#!/usr/bin/env bash
set -euo pipefail

codec="keiro-dsl/test/conformance-id-domain-migration/Generated/IdDomainMigration/OrderBook/Codec.hs"
backup="$(mktemp /tmp/keiro-id-domain-codec.XXXXXX)"
log="$(mktemp /tmp/keiro-id-domain-mutation.XXXXXX)"

restore() {
  cp "$backup" "$codec"
  rm -f "$backup" "$log"
}
trap restore EXIT

cp "$codec" "$backup"

echo "== baseline: ID-domain migration conformance is green =="
cabal test keiro-dsl-conformance-id-domain-migration >/dev/null

perl -0pi -e 's/OrderId, orderIdText/OrderId, orderIdText, parseOrderId/' "$codec"
perl -0pi -e 's/unsafeOrderIdFromLegacyText <\$> o \.\: "orderId"/o .: "orderId" >>= either (fail . T.unpack) pure . parseOrderId/' "$codec"

echo "== mutation: routing replay through the current parser turns the migration red =="
if cabal test keiro-dsl-conformance-id-domain-migration --test-show-details=direct >"$log" 2>&1; then
  echo "FAIL  mutation unexpectedly passed"
  exit 1
fi

if ! rg -q '^FAIL  historical event replay accepts the legacy malformed text$' "$log"; then
  echo "FAIL  mutation failed for an unexpected reason"
  sed -n '1,200p' "$log"
  exit 1
fi

echo "PASS  legacy replay/current admission boundary is mutation-sensitive"
