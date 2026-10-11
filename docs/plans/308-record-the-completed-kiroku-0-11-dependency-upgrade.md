---
id: 308
slug: record-the-completed-kiroku-0-11-dependency-upgrade
title: "Record the completed Kiroku 0.11 dependency upgrade"
kind: exec-plan
created_at: 2026-10-11T23:21:42Z
intention: "intention_01m4pmajbae3x97329y457xdsq"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-11T23:21:42Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-11T23:25:16Z
      mode: "other"
      note: "Record completed Kiroku upgrade and verification retrospectively"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-11T23:37:49Z
      verdict: "approved"
      note: "Verified latest Hackage cohort and release tags, upstream 0.11 API and migration adoption, all 63 historical suite results, and fresh migration/runtime/retention/operator suites (820 examples, zero failures); corrected stale router retry-policy documentation. Release blueprints and persistent rollout remain separate."
---


# Record the completed Kiroku 0.11 dependency upgrade


This ExecPlan is a living document. Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective must stay current. It was created on 2026-10-11 after
the implementation and verification, at the user's request. Completed steps below
are retrospective records, not evidence that a plan preceded the work.

## Purpose / Big Picture


Keiro now builds and runs its enabled tests against the latest released Kiroku
cohort verified on 2026-10-11: `kiroku-store 0.11.0.0`,
`kiroku-store-migrations 0.7.1.0`, and `shibuya-kiroku-adapter 0.6.0.1`.
Kiroku is the event store used by Keiro; its migration package supplies ordered
PostgreSQL schema changes, and its adapter connects subscriptions to Shibuya
streams. A cohort here means these compatible packages adopted together.

This record explains the dependency bounds, compatibility fixes, migration
expectations, and verification so a future contributor can reproduce the result.
Running the migration tests demonstrates that a fresh disposable database receives
all 47 composed migrations, including Kiroku's new stream browsing index. Running
the retention tests demonstrates that subscription acknowledgement paths work
with the validated buffer API and satisfy the existing live-heap gates.

The repository adoption is complete. A Keiro release, persistent database rollout,
and Seihou blueprint changes are separate release preparation still outstanding.

## Progress


- [x] (2026-10-11, recorded retrospectively) Locate upstream source with Mori and verify the released package cohort against Hackage and upstream tags.
- [x] (2026-10-11, recorded retrospectively) Align bounded Cabal dependencies, Mori dependency metadata, and unreleased changelog entries.
- [x] (2026-10-11, recorded retrospectively) Update migration expectations and assert the migration 0015 stream browsing index.
- [x] (2026-10-11, recorded retrospectively) Adapt both retention acknowledgement call sites to validated stream buffer sizes.
- [x] (2026-10-11, recorded retrospectively) Build all packages and obtain passing results for all 63 enabled test suites across the recorded runs; pass extension policy and nine reexport checks.
- [x] (2026-10-11) Review relevant ADRs, finish this retrospective record, and identify release blueprint follow-up without claiming it is complete.

## Surprises & Discoveries


Migration assertions had already lagged the dependency bounds. Before this task,
the working tree required migrations `^>=0.7.0.0`, whose upstream component has
14 entries, but tests still expected 12 Kiroku entries and 44 composed entries.
The new component has 15 entries; with Keiro's unchanged 32 entries the total is
47. Updating stale assertions from 44 to 47 must not be interpreted as three
new migrations introduced by this particular upgrade: migration 0015 is the
addition over the previously selected component.

The initial test run found retention fixtures left behind by the preceding
Kiroku 0.10 adoption. `subscriptionAckStream` now accepts `StreamBufferSize`,
not an unchecked `Natural` or numeric literal. The configurable fixture must
validate its input, and the fixed-size leg can use the upstream default of 256.
A first correction fixed the fixture; a subsequent run exposed the second call
site in `Retention.Legs`, which was also corrected before final verification.

The initial environment lacked Z3, the solver used by symbolic proof tests.
Rerunning remaining suites in `nix develop` supplied Z3 4.16.0 and those tests
passed. Migration tests subsequently exposed stale Codd import outcome counts;
their imported 23-row history remains unchanged, while eight rather than five
Kiroku migrations must be applied after importing the seven historical entries.
Codd is the former migration tool whose historical ledger is imported into the
native migration ledger.

The upstream blueprint contains a 0.10.0.0 to 0.11.0.0 edge but no 0.9 to 0.10
edge. Published Keiro 0.19 still uses Kiroku 0.9; HEAD already contained the
unreleased 0.10 adoption before this work. Release planning therefore needs to
cover both upstream transitions rather than treating HEAD as the released baseline.

## Decision Log


Decision (2026-10-11): Use the released cohort verified through Hackage and Git
tags, rather than choosing versions from the local corpus alone. The three
release tags identify upstream commit `7394055de458bef8f6ec2e68231f3ca7932bb9be`.
Mori located source and documentation; registry and tag checks established release
availability. Preserve the existing `^>=` bound style.

Decision (2026-10-11): Keep the implementation limited to dependency adoption,
metadata, changelogs, and test compatibility. Keiro uses upstream Store
interpreters and does not directly construct the changed Subscriber record, so
no production interpreter or subscriber implementation needed changing.

Decision (2026-10-11): Validate configurable retention buffer sizes using
`mkStreamBufferSize` and fail with its construction error on invalid input.
Use `defaultStreamBufferSize` for the existing fixed 256-item leg. This preserves
its measurement configuration while following the public API.

Decision (2026-10-11): Record the work retrospectively with this ExecPlan and an
Intention-linked commit. Do not invent earlier planning timestamps or mark
release work as completed. The user explicitly requested a durable record and
commit after implementation.

Decision (2026-10-11): Leave package versions and blueprint files unchanged in
this task. No next Keiro release version was selected. A release blueprint must
start from the actual last release, include the upstream transition gap, and
follow the release workflow. This record documents that requirement.

## Outcomes & Retrospective


The repository upgrade is complete. All 63 enabled suites passed across the
initial, remaining-suite, and final targeted runs. This is not a claim that one
uninterrupted `cabal test all` invocation succeeded: early failures led to the
compatibility corrections described above. The disabled legacy Codd tools suite
was not enabled. Some existing examples are pending; their suites passed.

The packages retain their existing 0.19.0.1 versions. No release, push, or
persistent database migration was performed. Full `just verify` and
`nix flake check` were not run; the checks actually run are recorded below.
The plan records completed repository work, with release preparation outside its
completion criteria.

Before the next release, add a Keiro Seihou migration edge from 0.19.0.1 to the
chosen next version. A Seihou edge is a version-to-version upgrade recipe for
consumer source, fixtures, and database state. It must entail the upstream
0.9 to 0.10 and 0.10 to 0.11 recipes, cover Keiro's other unreleased changes,
and document stopping subscription workers for migrations 0013/0014 and a
possible write pause for the transactional index build in 0015. First supply
and publish the missing upstream edge; then update the Keiro blueprint version,
registry metadata, README/cohort map, and validate and preview the migration.
The current local blueprint is `blueprints/keiro-upgrade/blueprint.dhall`.
The upstream blueprint belongs to `mori://shinzui/kiroku`, at project-relative
`blueprints/kiroku-upgrade/blueprint.dhall` (artifact-level URI pending).
No blueprint change is included in this commit.

ADR distillation found no new architectural decision to promote. This change
continues the existing ownership of composed schema verification, guarded native
ledger import, and retention measurement described below. Version-specific
migration counts, API compatibility fixes, and release follow-up remain task
records here. A short plan should have been created before implementation once
the breaking dependency API and database migration became apparent.

## Context and Orientation


Cabal builds this multi-package Haskell repository. The changed dependency bounds
live in `jitsurei/jitsurei.cabal`, `keiro-core/keiro-core.cabal`,
`keiro-dsl/keiro-dsl.cabal`, `keiro-migrations/keiro-migrations.cabal`,
`keiro-ops/keiro-ops.cabal`, `keiro-test-support/keiro-test-support.cabal`,
and `keiro/keiro.cabal`. Existing unbounded conformance dependencies remain
unbounded. `mori.dhall` describes repository dependencies for Mori; its bounded
Kiroku store and migrations references match the Cabal bounds.

User-facing upgrade notes are in `CHANGELOG.md`, `keiro/CHANGELOG.md`,
`keiro-core/CHANGELOG.md`, `keiro-dsl/CHANGELOG.md`,
`keiro-migrations/CHANGELOG.md`, `keiro-ops/CHANGELOG.md`, and
`keiro-test-support/CHANGELOG.md`. Existing unreleased hardening notes are
retained and their cohort is advanced to the current releases.

`keiro-migrations/test/Main.hs` exercises the composed native migration plan,
read-only preflight checks, historical Codd imports, and actual schema objects.
The native ledger is the database record of applied migration identities and
checksums. `keiro/retention/Retention/Fixture.hs` builds the configurable
acknowledgement adapter; `keiro/retention/Retention/Legs.hs` runs isolated
measurement scenarios. Retention gates measure live memory after major garbage
collection to detect sustained growth.

[ADR-9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md)
separates native ledger integrity from live schema verification and keeps
upstream migration ownership intact. This upgrade continues to compose the
upstream component and tests its new index rather than copying upstream SQL.
[ADR-10](../adr/0010-keiro-guards-fresh-native-history-over-codd-ledgers.md)
requires importing historical Codd state before creating fresh native history;
the strict import and rerun tests remain in place.
[ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)
requires isolated legs and post-major-GC live heap gates, using both the
512-byte-per-operation slope and 2 MiB growth limits after warmup. Its default
1500-operation unsnapshotted-router workload remains unchanged. Passing these
gates is evidence for those workloads, not proof of the absence of all leaks.

Upstream dependencies are canonically identified as
`mori://shinzui/kiroku/packages/kiroku-store`,
`mori://shinzui/kiroku/packages/kiroku-store-migrations`, and
`mori://shinzui/kiroku/packages/shibuya-kiroku-adapter`.
The independent future Shibuya/PGMQ work is described in
`docs/plans/307-upgrade-to-the-latest-released-shibuya-and-pgmq-hs.md`;
this task does not implement it.

## Plan of Work


### Milestone 1: Verify and align the released dependencies


Locate Kiroku through Mori, inspect its changelogs and relevant APIs, and verify
the chosen releases against Hackage and upstream tags. In each named Cabal file,
replace bounded `kiroku-store ^>=0.10.0.0` with `^>=0.11.0.0`, migrations
`^>=0.7.0.0` with `^>=0.7.1.0`, and adapter `^>=0.6.0.0` with `^>=0.6.0.1`
where present. Align `mori.dhall` and the unreleased changelogs. Document the five
new Store read operations and the write-blocking potential of migration 0015.
Run `cabal update` and `cabal build all`; acceptance is successful compilation
and a build plan resolving precisely the verified three versions.

### Milestone 2: Repair compatibility and prove database behavior


In `keiro-migrations/test/Main.hs`, expect 15 upstream entries and 47 composed
entries, skip 15 upstream entries when checking the Keiro-only remainder,
and expect 47 already-applied outcomes on rerun. Extend the Codd pending list
through 0015, change both post-import Kiroku `AppliedNow` counts to eight,
and retain 23 imported source rows. Expect the upstream schema comment through
0015 and assert `kiroku.ix_streams_browse_name` exists via `to_regclass`.

In `Retention.Fixture.ackAdapter`, call `mkStreamBufferSize` on the supplied
`Natural`, propagate construction failure with `fail . show`, and pass the
validated size to `subscriptionAckStream`. In `Retention.Legs.kirokuSubscribeAck`,
replace the literal 256 with `defaultStreamBufferSize`. Run the migration and
retention suites; acceptance is successful import/rerun checks, the actual new
index in disposable PostgreSQL, and passing acknowledgement retention legs.

### Milestone 3: Verify the enabled suites and preserve the record


Run the enabled suites in the Nix development shell so Z3 is available. Address
failures, rerun affected suites, and verify that every enabled suite has a final
passing result. Run extension policy and reexport checks. Review the decisions
against the relevant ADRs and capture the release boundary in this plan.
Acceptance is the recorded 63 passing suite results and a commit containing this
plan and the upgrade, associated through both required trailers.

## Concrete Steps


Run these commands from the repository root. Registry output identifies the
source checkout; read there rather than traversing `/nix/store`. Version lookup
is evidence for this dated decision, not an instruction to silently change the
cohort when newer releases appear.

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mori registry list
mori registry search kiroku
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
mori path mori://shinzui/kiroku/packages/kiroku-store
curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json
curl -fsSL https://hackage.haskell.org/package/kiroku-store-migrations/preferred.json
curl -fsSL https://hackage.haskell.org/package/shibuya-kiroku-adapter/preferred.json
```

The verification on 2026-10-11 found the cohort stated above. Inspect upstream
tags using `git ls-remote --tags` with the repository URL returned by Mori;
the matching release tags resolve to commit
`7394055de458bef8f6ec2e68231f3ca7932bb9be`.

For a complete reproduction of verification after the edits:

```bash
cabal update
nix develop -c cabal build all
nix develop -c cabal test all --keep-going
bash scripts/check-extension-policy.sh
python3 -m unittest discover -s scripts/tests -p test_keiro_reexports.py
git diff --check
```

The actual build was `cabal build all`. The initial `cabal test all` had failures;
54 remaining suites were subsequently run using `cabal test --keep-going` with
explicit suite names inside `nix develop`, excluding nine previously passed
suites. After the last fixes, this exact targeted command passed:

```bash
nix develop -c cabal test keiro-migrations-test keiro-retention
```

Recorded evidence, summarized from the runs:

```text
Resolved: kiroku-store 0.11.0.0
Resolved: kiroku-store-migrations 0.7.1.0
Resolved: shibuya-kiroku-adapter 0.6.0.1
cabal build all: exit 0
Final passing results across runs: 63 / 63 enabled suites
keiro-test: 719 examples, 0 failures
keiro-dsl-test: 791 examples, 0 failures
keiro-migrations-test: 36 examples, 0 failures
keiro-retention: 15 examples, 0 failures
Reexport unittest checks: 9 tests, OK
Extension policy: exit 0
git diff --check: exit 0
```

Transient captures were `/tmp/keiro-kiroku-upgrade-build.log`,
`/tmp/keiro-kiroku-upgrade-tests.log`,
`/tmp/keiro-kiroku-upgrade-tests-remaining.log`, and
`/tmp/keiro-kiroku-upgrade-final-tests.log`. They are not required for reproducing
the checks; the durable evidence is summarized here.

The delivery commit must include these trailers. Commit on the current branch
with a Conventional Commit message; no branch or push is part of this task.

```text
ExecPlan: docs/plans/308-record-the-completed-kiroku-0-11-dependency-upgrade.md
Intention: intention_01m4pmajbae3x97329y457xdsq
```

## Validation and Acceptance


Compilation must resolve the exact verified cohort in
`dist-newstyle/cache/plan.json`. All 63 enabled suites must have passing final
results. A fresh test database must accept the 47-entry composed migration plan,
contain `kiroku.ix_streams_browse_name`, and report all entries already applied
on rerun. Codd import tests must preserve 23 historical source rows and produce
a consistent 47-entry native ledger after the remaining migrations.

Retention acknowledgement tests must compile with `StreamBufferSize` and pass
the existing live-heap gates at the default 1500 operations over six blocks.
These database tests use disposable PostgreSQL 18 instances; they do not
validate deployment timing on a large persistent store. Existing extension
policy, nine reexport checks, and whitespace checks must pass. The final commit
must include the plan, dependency/test/changelog changes, and both trailers.

## Idempotence and Recovery


Building and testing can be repeated. Tests use disposable databases; do not
substitute a persistent database connection to reproduce this task. Cabal's
package index update and solver output may change as new releases appear;
check the resolved versions against this dated record before comparing results.
Bound replacements are idempotent when applied only to the stated old bounds.

For a test failure, correct the cause and rerun affected suites before claiming
they passed; preserve other valid suite results. Invalid configurable buffer
sizes fail construction rather than reaching the upstream subscription call.
For a later persistent rollout, follow the separate release migration recipe
and its database recovery procedure. Do not remove migration ledger rows or
attempt to reverse the new index as part of this repository verification.
A repository rollback can revert this delivery commit without changing a
persistent database; that does not roll back an independently deployed schema.

## Interfaces and Dependencies


The final lower bounds are store `^>=0.11.0.0`, migrations `^>=0.7.1.0`, and
adapter `^>=0.6.0.1`. No package release version or unrelated dependency bounds
change. Upstream `Kiroku.Store.Effect.Store` adds `ListStreams`, `ListCategories`,
`GetEvent`, `ListSubscriptionDeadLetters`, and `GetStreamWithHead`. Custom
interpreters must handle them. The upstream Subscriber record adds `subDropped`;
Keiro has no direct constructors requiring adaptation.

`Kiroku.Store.Subscription.Stream` exposes
`mkStreamBufferSize :: Natural -> Either InvalidStreamBufferSize StreamBufferSize`
and `defaultStreamBufferSize :: StreamBufferSize` (capacity 256).
`subscriptionAckStream` takes the validated `StreamBufferSize` as its third
argument. `Retention.Fixture.ackAdapter` keeps its external `Natural` argument
and validates it at the boundary. The composed migration plan contains 15
Kiroku entries and 32 Keiro entries; Keiro's own migration component is unchanged.

Revision note (2026-10-11): Created and completed this retrospective plan after
the upgrade, preserving actual failures and passing verification while recording
the separate Seihou release work. Associated the record with the newly created
Intention at the user's request.
