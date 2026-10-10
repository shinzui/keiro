# Kiroku hardening cohort adoption

Authoritative implementation owner:
mori://shinzui/kiroku/plans/85-release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption.
The transferred Keiro MasterPlan 20 and plan 126 remain retired. This is source
adoption on master, with no Keiro version bump, tag or package release.

Require published store 0.10.0.0, migrations 0.7.0.0 and adapter 0.6.0.0. The
resolved main-library entries in `published-dependencies.json` prove normal
Hackage index (`repo-tar`) resolution, with no local Kiroku package sources.
An initial normal build failed during index propagation; its raw log is retained.
`index-propagation-bootstrap.project` records the temporary public-archive project
used before propagation completed. It is no longer part of the active project.

`resizeShardCountTx` accepts validated Kiroku size, locks the complete lease set,
refuses every recorded owner (including expired owners) and composes released
public `resizeConsumerGroupTx` with replacement of lease rows. The Eff wrapper
throws typed refusal after a no-write transaction. The result exposes old counts,
new validated size and the full Kiroku resize report. Startup validates batch,
member and buffer constructors, preserves default stop-on-undecodable, treats
`EventDecodeFailed` as deterministic and recognizes the startup-refusal parent.
`ensureShards` now refuses mismatches before inserting any lease row. See ADR-50.

The new resize tests create deliberately skewed progress using real published
subscription workers, inspect only the public checkpoint inventory, and cover
owner refusal, grow/shrink, same-size idempotence, rollback after SQL division by
zero and complete delivery of all 120 seeded event IDs after reassignment. Existing
lease, failover and acknowledgement-coupling tests also pass: 22 shard examples.
The extended command-error test verifies decode failure produces a fatal halt.

Preserve the first fixture failure: it returned `Stop` before recording that event,
but `Stop` acknowledges the current event. Recording the event before either
`Continue` or `Stop` corrects the fixture without changing production delivery.
The first full workspace build also found an exported `ownedBuckets` label clash
in Keiro Ops; the new refusal label is now `resizeOwnedBuckets` and the final build
passes. Constructor/Generic-lens mistakes in the initial new fixture compilation
are retained in build logs; the final fixture uses public record accessors.

`build-final.log` records a successful `cabal build all keiro:keiro-test` against
the normal index. Strict ADR validation (50 concepts), strict user documentation
validation (34 concepts), formatting and native flake treefmt/pre-commit checks
pass. The bounded `verify.py` journal retains final focused and full-suite results.
No remote performance experiment was needed for this maintenance/startup seam;
no append SQL or steady-state checkpoint path changed in Keiro.

The first full Keiro run retained 719 examples with 39 failures. The schema-
versioned/read-model fixtures still inserted `stream_name`, dropped by Kiroku
migration 0014; they now use `target_kind = 'all'`. Two source/probe checks also
required the package working directory rather than the workspace root. The final
controller uses each package directory. Keiro Ops' inventory fixture receives the
same column adaptation and its full suite is included. These failures are retained
in `full-keiro-pre-adoption-fixtures.log` and its journal, not overwritten.

Final acceptance: 719 Keiro examples and 50 Keiro Ops examples pass, with zero
failures. The corrected full suites complete in 173.28 seconds including process
setup. The earlier 22-example focused shard pass is retained separately. Final
build and native formatting/flake checks pass; the downstream maintenance seam
is complete. No Keiro package release is performed.
