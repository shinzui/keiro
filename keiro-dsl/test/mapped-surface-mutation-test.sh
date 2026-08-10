#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

bindings="keiro-dsl/test/conformance-projection-catalog/CatalogDemo/MappedBindings.hs"
queue="keiro-dsl/test/conformance-projection-catalog/Generated/CatalogDemo/QualificationJobs/Queue.hs"
query_contract="keiro-dsl/test/conformance-projection-catalog/Generated/CatalogDemo/OrderInline/QueryContract.hs"
projection_catalog="keiro-dsl/test/conformance-projection-catalog/Generated/CatalogDemo/ProjectionCatalog.hs"
semantic_impact="keiro-dsl/src/Keiro/Dsl/SemanticImpact.hs"
service_harness="keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs"
targets=(
  "$bindings"
  "$queue"
  "$query_contract"
  "$projection_catalog"
  "$semantic_impact"
  "$service_harness"
)

backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/keiro-mapped-surface-mutation.XXXXXX")"
case "$backup_dir" in
  *keiro-mapped-surface-mutation.*) ;;
  *) echo "FAIL: unexpected backup path: $backup_dir"; exit 1 ;;
esac

for target in "${targets[@]}"; do
  cp "$target" "$backup_dir/$(basename "$target").$(printf '%s' "$target" | shasum -a 256 | cut -c1-12)"
done

digest_targets() {
  shasum -a 256 "${targets[@]}"
}

baseline_digest="$(digest_targets)"

restore_all() {
  local target backup
  for target in "${targets[@]}"; do
    backup="$backup_dir/$(basename "$target").$(printf '%s' "$target" | shasum -a 256 | cut -c1-12)"
    cp "$backup" "$target"
  done
}

cleanup() {
  restore_all
  rm -f "$backup_dir"/*
  rmdir "$backup_dir"
}
trap cleanup EXIT

run_integrated() {
  cabal test -v0 keiro-dsl:keiro-dsl-conformance-projection-catalog
}

run_qualification() {
  cabal test -v0 keiro-dsl:keiro-dsl-test \
    --test-options='--match "mapped surface qualification"'
}

expect_red() {
  local label="$1"
  shift
  set +e
  "$@" >"$backup_dir/mutation.log" 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    sed -n '1,240p' "$backup_dir/mutation.log"
    echo "FAIL: mutation stayed green: $label"
    exit 1
  fi
  echo "PASS: mutation turned its named gate red: $label"
  restore_all
}

echo "== baseline: integrated mapped surface is green =="
run_integrated >/dev/null
run_qualification >/dev/null

perl -0pi -e 's/import CatalogDemo\.MappedDomain\n/import CatalogDemo.MappedDomain\nimport CatalogDemo.MappedDomain qualified as Domain\n/' "$bindings"
perl -0pi -e 's/import Generated\.CatalogDemo\.Structural\.Shape\.QualificationPayload \(QualificationPayloadShape\)/import Generated.CatalogDemo.Structural.Shape.QualificationPayload (QualificationPayloadShape)\nimport Generated.CatalogDemo.Structural.Shape.QualificationPayload qualified as Shape/' "$bindings"
perl -0pi -e 's/Keiro\.Codec\.Structural \(FixtureCases \(\.\.\), StructuralBinding\)/Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))/' "$bindings"
perl -0pi -e 's/qualificationPayloadBinding = genericStructuralBinding/qualificationPayloadBinding = StructuralBinding { bindingToShape = \\value -> Shape.QualificationPayload (Domain.qualificationId value <> "-mutated") (Domain.note value), bindingFromShape = \\shape -> Domain.QualificationPayload (Shape.qualificationId shape) (Shape.note shape) }/' "$bindings"
expect_red "transpose the structural binding authority" run_integrated

perl -0pi -e 's/, "payload" \.= encodeQualificationPayloadMapped payload\.qualification/, "payload_mutated" .= encodeQualificationPayloadMapped payload.qualification/' "$queue"
expect_red "remove the queue encoder arm from its canonical key" run_integrated

perl -0pi -e 's/explicitParseField \(parseQualificationPayloadMapped\) objectValue "payload"/explicitParseField (parseQualificationPayloadMapped) objectValue "payload_mutated"/' "$queue"
expect_red "remove the queue decoder arm from its canonical key" run_integrated

perl -0pi -e 's/explicitParseField \(\\value -> case value of Null -> pure Nothing; other -> Just <\$> parseJSON other\) objectValue "maybe_metadata"/explicitParseField (fmap Just . parseJSON) objectValue "maybe_metadata"/' "$queue"
expect_red "reject the declared queue null policy" run_integrated

perl -0pi -e 's/type OrderInlineQueryInput = QueryCriteria/type OrderInlineQueryInput = QualificationResult/' "$query_contract"
expect_red "stale the generated query input signature" run_integrated

perl -0pi -e 's/aggregate:Orders\/generated-codec\/v1\/mapped-132056a8f2ee095d/aggregate:Orders\/generated-codec\/v1\/stale-fingerprint/' "$projection_catalog"
expect_red "stale the aggregate projection source fingerprint" run_integrated

perl -0pi -e 's/mappedRootConsumer = WorkqueueConsumer workqueue/mappedRootConsumer = AggregateConsumer workqueue/' "$semantic_impact"
expect_red "misattribute a queue semantic consumer" run_qualification

perl -0pi -e 's/MappedWorkqueueHistory workqueue -> "workqueue-history:" <> workqueue/MappedWorkqueueHistory workqueue -> "private-event-history:" <> workqueue/' "$semantic_impact"
expect_red "misreport a queued-job consequence" run_qualification

perl -0pi -e 's/surfaceFactValues service <> concatMap valuesForNode/surfaceFactValues service <> surfaceFactValues service <> concatMap valuesForNode/' "$service_harness"
expect_red "duplicate a generated service conformance law" run_qualification

perl -0pi -e 's/parseMappedRootKind "workqueue-payload"/parseMappedRootKind "corrupt-workqueue-payload"/' "$semantic_impact"
expect_red "corrupt a known semantic-impact ledger tag" run_qualification

restore_all
if [[ "$(digest_targets)" != "$baseline_digest" ]]; then
  echo "FAIL: mapped surface mutation targets were not restored byte-for-byte"
  exit 1
fi

run_integrated >/dev/null
run_qualification >/dev/null
echo "PASS: all mapped surface mutations were caught and exact bytes restored"
