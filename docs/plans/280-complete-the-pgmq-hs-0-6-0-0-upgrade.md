---
id: 280
slug: complete-the-pgmq-hs-0-6-0-0-upgrade
title: "Complete the pgmq-hs 0.6.0.0 upgrade"
kind: exec-plan
created_at: 2026-09-14T17:41:10Z
intention: "intention_01m2gfyrp2ekt9k2h480nh5y1x"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T17:41:10Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T17:54:30Z
      mode: "implement"
      note: "Recorded the unresolved adapter release gate"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T18:20:24Z
      mode: "update"
      note: "Verified adapter 0.15.0.0 and cleared the release gate"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T18:23:26Z
      mode: "implement"
      note: "Implemented dependency, regression, documentation, and validation milestones"
---

# Complete the pgmq-hs 0.6.0.0 upgrade

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro's checked-in source already uses the `pgmq-hs` 0.6 API. The dependency
upgrade was initially blocked because the newest published
`shibuya-pgmq-adapter` excluded `pgmq-hs` 0.6; adapter 0.15.0.0 now removes that
external release blocker. After this plan, a user can clone Keiro, refresh
Hackage, and build and test the whole workspace without a source override,
`allow-newer`, or a locally checked-out dependency. The resolved plan will
contain all five `pgmq-hs` packages at 0.6.0.0 and
`shibuya-pgmq-adapter` 0.15.0.0, whose declared bounds accept that family.

The change also makes the upgrade visible and honest. Keiro's package metadata
will describe its real direct PGMQ dependencies, the changelogs and work-queue
reference will explain the source-visible 0.6 changes, and focused tests will pin
Keiro's deliberate choice to retain the server's default partition `premake` and
the new nullable default-partition metric. A human can see the result by running
`just verify` from the repository root and by reading the selected versions from
`dist-newstyle/cache/plan.json`.


## Progress

- [x] (2026-09-14 17:54Z) Verify that Hackage and the upstream tag registry
  contain the complete `pgmq-hs` 0.6.0.0 family. Hackage selects 0.6.0.0 for all
  five packages, and upstream tag `v0.6.0.0` resolves to commit `7269f4de`.
- [x] (2026-09-14 18:17Z) Verify the compatible adapter release. Hackage selects
  `shibuya-pgmq-adapter` 0.15.0.0, upstream tag `v0.15.0.0` resolves to release
  commit `22f5c4da`, and the published library and test-suite bounds accept
  `pgmq-core`, `pgmq-effectful`, `pgmq-hasql`, and `pgmq-migration` 0.6.
- [x] (2026-09-14 18:30Z) Raise the Keiro adapter bounds to `^>=0.15.0.0`,
  reconcile `mori.dhall`, and replace release-candidate wording in the root and
  `keiro-pgmq` changelogs. A refreshed Hackage dry run resolved the published
  adapter at 0.15.0.0 and all five PGMQ packages at 0.6.0.0.
- [x] (2026-09-14 18:30Z) Pin the adopted 0.6 behavior in
  `keiro-pgmq/test/Main.hs` and explain the new partition and metrics fields in
  `docs/user/work-queues.md`, including its OKF bundle log entry. Strict OKF
  validation passed, and `keiro-pgmq-test` passed 58 examples with only its two
  pre-existing pending examples.
- [ ] Prove the focused PGMQ consumers and the complete repository pass with
  only published packages, record the resolved versions and results here, and
  perform the final ADR-distillation review.


## Surprises & Discoveries

The repository is not waiting for the `pgmq-hs` release itself. Hackage's live
preferred-version endpoints and upstream tag registry both report 0.6.0.0 for
`pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, `pgmq-migration`, and `pgmq-config`.
Commit `e4ec781b` already changed every bounded Keiro consumer from the 0.5 family
to `>=0.6 && <0.7`, added `premake = Nothing` to Keiro's `PartitionConfig`, and
described the dependency as a release candidate.

The former problem was the adapter release. At 2026-09-14 17:54Z, Hackage reported
`shibuya-pgmq-adapter` 0.14.0.0 as latest, and its published Cabal file required
`pgmq-core`, `pgmq-effectful`, and `pgmq-hasql` at `^>=0.5` in both the library
and test suite. Fresh implementation-time verification corrected an earlier
assumption about upstream: GitHub `HEAD` is commit `fee9b3a8`, whose Cabal file
also retains `^>=0.5`, and the latest upstream tag remains `v0.14.0.0` at commit
`30165237`. The Mori-located checkout is two commits ahead of `origin/master`;
its local commit `2b67a65d` changes the four adapter PGMQ bounds to `^>=0.6`
without changing the package version. That local commit is compatibility
evidence, not a consumable release or published upstream state.

The repeated release gate at 2026-09-14 17:54Z produced:

```text
pgmq-core 0.6.0.0
pgmq-hasql 0.6.0.0
pgmq-effectful 0.6.0.0
pgmq-migration 0.6.0.0
pgmq-config 0.6.0.0
shibuya-pgmq-adapter 0.14.0.0
```

At 2026-09-14 18:17Z, a refreshed Hackage index and the live preferred-version
endpoint selected `shibuya-pgmq-adapter` 0.15.0.0. Upstream tag `v0.15.0.0`
resolves to commit `22f5c4da`; its annotated tag object is `4a57c030`. The
published Cabal file matches the Mori-located tagged source and declares
`^>=0.6` for `pgmq-core`, `pgmq-effectful`, and `pgmq-hasql` in both the library
and test suite, plus `pgmq-migration ^>=0.6` in the test suite. The release gate
is therefore satisfied.

The adapter release does not require a Keiro production-code compatibility
update. A tagged diff from adapter 0.14.0.0 to 0.15.0.0 contains no Haskell
source-file changes; the adapter package change is its version and PGMQ bounds,
and its changelog explicitly preserves the public function and record
signatures. Keiro commit `e4ec781b` already adopted PGMQ 0.6's production-visible
`PartitionConfig.premake` field. The remaining Haskell edit in this plan is
regression coverage for `premake` and `QueueMetrics.defaultPartitionLength`, not
a production API adaptation.

Before adapter 0.15.0.0 was published, the failure was reproducible before
compilation:

```text
Resolving dependencies...
rejecting: shibuya-pgmq-adapter-0.14.0.0
(conflict: pgmq-core==0.6.0.0,
 shibuya-pgmq-adapter => pgmq-core^>=0.5)
```

`mori.dhall` has a second, independent accuracy gap: it records
`shibuya-pgmq-adapter ^>=0.14.0.0` for `keiro-pgmq`, but does not record that
package's direct `pgmq-config`, `pgmq-core`, `pgmq-effectful`, or `pgmq-hasql`
library dependencies, nor its `pgmq-migration` test dependency. Consequently
Mori does not currently list Keiro as a dependent of `mori://shinzui/pgmq-hs`
even though the Cabal files do.

`okf log add docs/user DOC-25` emitted `concept not found: DOC-25` because the
document is a Markdown file at the bundle root rather than a concept directory,
but it still wrote the correctly dated bundle entry. The immediately following
strict, profile-enforced, log-enforced validation accepted all 25 documents and
the log, so the warning does not indicate missing durable evidence:

```text
log: warning: concept not found: DOC-25
Wrote log.md for 2026-09-14
OK: 25 concepts (okf_version 0.2)
```


## Decision Log

- Decision: Treat `pgmq-hs` 0.6.0.0 as the exact target release and require a
  published compatible adapter before changing Keiro's final adapter bound.
  Rationale: Hackage and upstream tags agree that 0.6.0.0 is the latest released
  five-package family. A dependency update is not complete while the ordinary
  package solver can only satisfy it from unreleased source.
  Date: 2026-09-14

- Decision: Expect `shibuya-pgmq-adapter` 0.15.0.0 as the compatible release,
  but verify its actual published version and Cabal bounds at implementation
  time. If upstream assigns another version, update this living plan before
  editing bounds.
  Rationale: The Mori-located local compatibility commit still says 0.14.0.0
  and has not reached upstream, so its eventual version is not authoritative.
  The dependency rule is deterministic: select the first released adapter newer
  than 0.14.0.0 whose published package accepts the complete PGMQ 0.6 family.
  Date: 2026-09-14

- Decision: Do not use `allow-newer`, a `source-repository-package`, a local
  package path, or relaxed PGMQ bounds as an implementation shortcut.
  Rationale: Those techniques would hide the release incompatibility and leave
  downstream Hackage users unable to solve the same package set.
  Date: 2026-09-14

- Decision: Keep Keiro's existing behavior of passing `premake = Nothing` and
  do not add a public explicit-premake option or adopt new grouped-head behavior
  in this plan.
  Rationale: `Nothing` preserves PGMQ's existing default of four pre-created
  partitions and works on PGMQ 1.12 and 1.13. Explicit premake requires PGMQ
  1.13 and is a feature decision, while FIFO ordering changes remain owned by
  [plan 116](116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md).
  Date: 2026-09-14

- Decision: Reconcile Mori metadata and user-facing documentation as part of the
  dependency completion, while adding no Keiro SQL migration.
  Rationale: The registry must report the dependencies developers actually
  build, and `Keiro.PGMQ.Metrics` publicly re-exports the changed `QueueMetrics`
  record. The PGMQ schema component remains owned by
  `mori://shinzui/pgmq-hs/packages/pgmq-migration`; Keiro merely composes it in
  tests and documented application migration plans.
  Date: 2026-09-14

- Decision: Adopt `shibuya-pgmq-adapter ^>=0.15.0.0` as the compatible adapter
  range for this upgrade.
  Rationale: Hackage 0.15.0.0 and upstream tag `v0.15.0.0` both resolve to the
  release source whose declared bounds accept the complete PGMQ 0.6 family. The
  ordinary Cabal solver can therefore consume the compatibility work after
  Keiro raises its adapter bound, without an override or local checkout.
  Date: 2026-09-14


## Outcomes & Retrospective

Milestones 1 and 2 are complete. The PGMQ 0.6.0.0 family and compatible adapter
0.15.0.0 are published on Hackage with matching upstream tags, Keiro's Cabal and
Mori metadata now select them, and the changelogs and work-queue reference state
the released behavior. Regression assertions pin `premake = Nothing` and the
nullable default-partition metric. `dhall type`, `mori show --full`, strict user
documentation validation, `cabal check`, the refreshed all-package dry run, and
`keiro-pgmq-test` all pass. The focused suite ran 58 examples with zero failures
and its two documented pre-existing pending examples. No production Haskell API
or implementation change was needed. Milestone 3 remains: run all affected
consumer suites and the repository-wide verification gate, record the final
resolved plan, and distill durable ADR context.


## Context and Orientation

`pgmq-hs` is a coordinated family of five Haskell packages for PGMQ, a message
queue implemented in PostgreSQL. `pgmq-core` defines shared types;
`pgmq-hasql` performs database operations; `pgmq-effectful` exposes those
operations as Effectful effects; `pgmq-migration` supplies a native
`pg-migrate` schema component; and `pgmq-config` declaratively creates queues.
Mori locates the family at `mori://shinzui/pgmq-hs`, with package handles
`mori://shinzui/pgmq-hs/packages/pgmq-core`,
`mori://shinzui/pgmq-hs/packages/pgmq-hasql`,
`mori://shinzui/pgmq-hs/packages/pgmq-effectful`,
`mori://shinzui/pgmq-hs/packages/pgmq-migration`, and
`mori://shinzui/pgmq-hs/packages/pgmq-config`.

Release 0.6.0.0 adds PGMQ 1.12 grouped-head reads and PGMQ 1.13 partition
controls and metrics. Its two source-visible record changes matter here.
`Pgmq.Config.Types.PartitionConfig` adds `premake :: Maybe Int32`; `Nothing`
uses the server default and `Just n` requires PGMQ 1.13. The publicly re-exported
`Pgmq.Hasql.Statements.Types.QueueMetrics` adds
`defaultPartitionLength :: Maybe Int64`; `Nothing` means unavailable or
inapplicable and must not be interpreted as zero, while `Just n` is a planner
estimate for rows spilled into a partitioned queue and archive's default
partitions. The native 0.6 migration component installs or upgrades PGMQ to
1.13 while retaining the documented imported-1.11 history contract.

`keiro-pgmq/keiro-pgmq.cabal` is the central consumer. Its library depends on
`pgmq-config`, `pgmq-core`, `pgmq-effectful`, and `pgmq-hasql`; its test suite
also depends on `pgmq-migration`. Both stanzas already require the 0.6 series,
but both still require `shibuya-pgmq-adapter ^>=0.14.0.0`.
`jitsurei/jitsurei.cabal` directly uses `pgmq-effectful` in its library and the
core, effectful, migration, and adapter packages in its test suite.
`keiro-ops/keiro-ops.cabal` directly uses `pgmq-migration` in its test suite.
`keiro-dsl/keiro-dsl.cabal` has unbounded internal conformance-test dependencies
on `pgmq-config` and `pgmq-core`, so the complete DSL test target is part of the
compatibility proof even though no bound changes there.

`keiro-pgmq/src/Keiro/PGMQ/Job.hs` turns Keiro's `PartitionSpec` into the
upstream `PartitionConfig`. It already supplies `premake = Nothing` and already
imports grouped reads from the 0.6 API. No production Haskell edit is expected.
`keiro-pgmq/src/Keiro/PGMQ/Metrics.hs` re-exports `QueueMetrics(..)` and returns
it unchanged from `jobQueueMetrics`, `jobDlqMetrics`, and `allJobMetrics`.
`keiro-pgmq/test/Main.hs` contains the pure partition-configuration test and the
PostgreSQL-backed queue metrics tests to extend. `keiro-ops/test/Main.hs` and
`jitsurei/test/Main.hs` compose PGMQ's migration component and exercise the
adapter across operational and worked-example paths.

`mori.dhall` is the repository's machine-readable project and package manifest.
Its `keiro-pgmq` package entry must mirror the Cabal dependencies and its
project-level `dependencies` and `dependencyRefs` lists must include the five
canonical PGMQ package references. `CHANGELOG.md` currently calls 0.6 a
candidate; `keiro-pgmq/CHANGELOG.md` has an empty Unreleased section.
`docs/user/work-queues.md` documents provisioning and the publicly re-exported
metrics, and belongs to the profiled `docs/user` OKF bundle as `DOC-25`; edits
must be logged in `docs/user/log.md` and pass strict profile validation.

The compatible adapter is a separate project. Mori identifies its package as
`mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter`.
Release 0.15.0.0 publishes the PGMQ 0.6 compatibility work from commit
`2b67a65d` at release commit `22f5c4da`. It changes no Haskell source or adapter
API relative to 0.14.0.0, so Keiro needs the new package bound but no production
adapter-call changes.

[Plan 279](279-harden-process-manager-reaction-apis-before-dsl-generation.md)
records this solver conflict as its M0 prerequisite blocker. Completion of this
plan makes that prerequisite satisfiable but does not implement or mark complete
plan 279's process-reaction milestones. [Plan 116](116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md)
owns future FIFO consumption semantics; this plan only preserves and validates
the dependency/API baseline it will use.

Three local ADRs constrain the upgrade. [ADR 0001](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md)
requires the bounded and continuous job paths to retain their process-span and
settlement behavior even though their implementations differ. [ADR 0028](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
requires `keiro-ops` to call public owner-library operations instead of copying
PGMQ SQL. [ADR 0009](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md)
keeps ledger verification, Keiro live-schema checks, and owner-supplied migration
components separate. No existing ADR chooses a dependency version, and this
plan makes no new durable architectural decision that presently requires a new
ADR.


## Plan of Work

Milestone 1 is a completed release gate. A refreshed Hackage index, Hackage's
preferred-version documents, the published adapter Cabal file, and upstream tags
all identify adapter 0.15.0.0. It constrains `pgmq-core`, `pgmq-effectful`, and
`pgmq-hasql` to `^>=0.6`; its
test component likewise accepts `pgmq-migration ^>=0.6`. Tag `v0.15.0.0`
resolves to release commit `22f5c4da`, so matching Hackage and upstream releases
satisfy this milestone without relying on a local checkout.

Milestone 2 completes the repository representation of the upgrade. In the
library and test-suite stanzas of `keiro-pgmq/keiro-pgmq.cabal` and the test-suite
stanza of `jitsurei/jitsurei.cabal`, raise
`shibuya-pgmq-adapter ^>=0.14.0.0` to the verified compatible release series,
`^>=0.15.0.0`. Keep every direct PGMQ bound at `>=0.6 && <0.7`; do not
widen it speculatively.

In the `keiro-pgmq` package record in `mori.dhall`, update the adapter constraint
and add regular Hackage dependencies for the four PGMQ library packages using
their canonical qualified names and the Cabal range `>=0.6 && <0.7`. Add
`pgmq-migration` with test scope and the same range. Add all five qualified names
to the project-level `dependencies` list and add five typed package Mori
references to `dependencyRefs`. Preserve the surrounding Dhall structure and
ordering conventions. Afterward `mori show --full` must report those package
dependencies and `mori registry dependents shinzui/pgmq-hs --packages` must list
Keiro after the local registry observes the working tree; a registry refresh is
not required to prove the checked-in Dhall itself.

Replace the root `CHANGELOG.md` candidate wording with the exact released
versions and state that the compatible adapter release completes normal solver
support. Add a Breaking Changes entry to `keiro-pgmq/CHANGELOG.md` explaining
the new PGMQ 0.6 family requirement, the compatible adapter requirement, the
new re-exported `QueueMetrics.defaultPartitionLength` field, and the deliberate
default-premake behavior. This is source-breaking for callers that construct or
positionally match `QueueMetrics`, even though Keiro's job API is unchanged.

Extend the partitioned configuration example in `keiro-pgmq/test/Main.hs` to
assert `pc.premake == Nothing`. Extend the standard queue metrics example to
assert `mainMetrics.defaultPartitionLength == Nothing`; this proves Keiro passes
through the new nullable field without converting absence to zero. In
`docs/user/work-queues.md`, explain that Keiro's partitioned provisioner retains
the server default premake and document `defaultPartitionLength` as a nullable,
lagging planner estimate. Do not promise that it is an exact count. Record the
`DOC-25` edit with `okf log add`.

Milestone 2 is accepted when Dhall and the user-documentation bundle validate,
`cabal check` accepts `keiro-pgmq`, the package solver succeeds without an
override, and `keiro-pgmq-test` passes its existing two documented pending
examples plus the strengthened assertions.

Milestone 3 validates every affected consumption path and closes the living
plan. Run the `keiro-pgmq`, `keiro-ops`, `jitsurei`, and complete `keiro-dsl`
test targets, followed by the repository's canonical `just verify` gate. Inspect
`dist-newstyle/cache/plan.json` and record the exact selected PGMQ and adapter
versions in this plan. Update Progress, add any new evidence or decisions, fill
Outcomes & Retrospective, and perform the ADR distillation pass. Update an
existing ADR only if implementation revealed a durable ownership or behavioral
decision; do not create an ADR merely to record package versions. Note that
plan 279's dependency prerequisite is now satisfiable, but leave its independent
implementation state to the session that implements that plan.


## Concrete Steps

All Keiro commands run from `/Users/shinzui/Keikaku/bokuno/keiro`. First verify
the releases from authoritative registries:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal update
for package in pgmq-core pgmq-hasql pgmq-effectful pgmq-migration pgmq-config; do
  printf '%s ' "$package"
  curl -fsSL "https://hackage.haskell.org/package/$package/preferred.json" |
    jq -r '."normal-version"[0]'
done
curl -fsSL https://hackage.haskell.org/package/shibuya-pgmq-adapter/preferred.json |
  jq -r '."normal-version"[0]'
git ls-remote --tags https://github.com/shinzui/pgmq-hs.git
git ls-remote --tags https://github.com/shinzui/shibuya-pgmq-adapter.git
```

The five loop lines must end in `0.6.0.0`. At plan creation the adapter query
printed `0.14.0.0`; after the 2026-09-14 release it prints `0.15.0.0`, and the
adapter tag output contains `v0.15.0.0` at release commit `22f5c4da`. Inspect the
package actually uploaded to Hackage:

```bash
curl -fsSL \
  https://hackage.haskell.org/package/shibuya-pgmq-adapter-0.15.0.0/shibuya-pgmq-adapter.cabal |
  rg '^(version:|library|test-suite)|pgmq-(core|effectful|hasql|migration)'
```

The dependency lines contain `^>=0.6`. A future rerun still requires both the
Git tag and matching Hackage upload; a tag without an upload, or an upload whose
Cabal file says `^>=0.5`, would not satisfy this gate.

Apply the Milestone 2 edits with `apply_patch`. Format and validate the metadata
and documentation:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
nix fmt
dhall type --file mori.dhall
mori show --full
okf log add docs/user DOC-25 --kind Update \
  --message "Document pgmq-hs 0.6 partition premake and default-partition metrics"
okf validate docs/user --strict \
  --profile mori/user-documentation-profile.dhall \
  --profile-enforce --log-enforce
(cd keiro-pgmq && cabal check)
git diff --check
```

Run the release-only solver check and the focused suite:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal build all --dry-run --enable-tests
cabal test keiro-pgmq-test --test-show-details=direct
```

The dry run must exit zero with no `source-repository-package` or `allow-newer`
addition in `cabal.project`. The test output must report zero failures. Its two
existing pending examples are the transient-poll fault-injection placeholder and
the live `pg_partman` partitioned-queue placeholder; no new pending example is
acceptable for this upgrade.

Run the affected and repository-wide validation for Milestone 3:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal test keiro-ops-test --test-show-details=direct
cabal test jitsurei-test --test-show-details=direct
cabal test keiro-dsl:tests --test-show-details=direct
just verify
jq -r '
  .["install-plan"][]
  | select(.["pkg-name"] | test("^(pgmq-(core|hasql|effectful|migration|config)|shibuya-pgmq-adapter)$"))
  | "\(.["pkg-name"]) \(.["pkg-version"])"
' dist-newstyle/cache/plan.json | sort -u
```

The version report must list the five PGMQ packages at 0.6.0.0 and
`shibuya-pgmq-adapter` at 0.15.0.0. Preserve the actual report and validation
summary in Outcomes & Retrospective.

Use Conventional Commits and include both active trailers on every commit made
for this plan. A suitable implementation commit is:

```text
chore(deps): complete pgmq-hs 0.6 adoption

ExecPlan: docs/plans/280-complete-the-pgmq-hs-0-6-0-0-upgrade.md
Intention: intention_01m2gfyrp2ekt9k2h480nh5y1x
```


## Validation and Acceptance

The plan is complete only when a clean, refreshed Hackage solver selects a
published dependency set. `cabal build all --dry-run --enable-tests` and
`cabal build all` must exit zero without a repository or command-line override.
The generated Cabal plan must show `pgmq-core`, `pgmq-hasql`,
`pgmq-effectful`, `pgmq-migration`, and `pgmq-config` 0.6.0.0 plus the released
compatible adapter. Merely compiling against the sibling checkout does not
satisfy this outcome.

`cabal test keiro-pgmq-test --test-show-details=direct` must run the existing
partition and metrics examples and report zero failures. The partition example
must fail if `Config.premake = Nothing` is removed or changed, and the standard
metrics example must observe `defaultPartitionLength == Nothing`, not zero.
Exactly the two pre-existing environment/fault-injection examples may remain
pending.

`cabal test keiro-ops-test`, `cabal test jitsurei-test`, and
`cabal test keiro-dsl:tests` must each run a nonzero number of examples and
report zero failures. These prove, respectively, that the public PGMQ operations
still back the operator commands, that the composed PGMQ 1.13 migration and
adapter work in the guide-backed integration, and that every generated queue
conformance component resolves the same package family.

`mori show --full` must show all five direct PGMQ dependencies under the
`keiro-pgmq` package and the adapter's new bound. Strict validation of
`docs/user` must accept the `DOC-25` content and log entry. `just verify` must
finish successfully, preserving ADR 0001's telemetry regressions and all other
repository gates.

Finally, `CHANGELOG.md`, `keiro-pgmq/CHANGELOG.md`, and
`docs/user/work-queues.md` must call 0.6.0.0 a release, state the nullable metric
semantics, and avoid claiming that Keiro exposes explicit premake or implements
new FIFO behavior. Plan 279's previously recorded solver command should succeed
after this plan even though its reaction API work remains unimplemented.


## Idempotence and Recovery

Release discovery, `cabal update`, Cabal dry runs, test commands, Dhall checks,
Mori inspection, and OKF validation are safe to repeat. `okf log add` should be
run once after the documentation edit; before retrying it, inspect
`docs/user/log.md` for the `DOC-25` message so the same update is not duplicated.

There is no Keiro database migration and no production data mutation in this
plan. The PostgreSQL-backed tests create disposable fixture databases and use
the released `pgmq-migration` component. An application upgrading its own
database must still follow the PGMQ component's rule to apply all pending
migrations before admitting queue-creation traffic, but that rollout is owned by
the application and `mori://shinzui/pgmq-hs/packages/pgmq-migration`, not by a
new file under `keiro-migrations/`.

If the adapter release is absent or its published bounds are wrong, leave the
working tree unchanged and record the exact Hackage/tag evidence in this plan.
Do not make the workspace appear green with `allow-newer` or a source override.
When a corrected release appears, rerun Milestone 1 from the start.

If a focused test fails after the bound change, keep the published dependency
set selected and diagnose the incompatibility against the Mori-located source.
Add the minimum Keiro compatibility change and regression test, documenting it
in Surprises & Discoveries and the Decision Log. Reverting the bound and code
edits is safe because no Keiro migration was added; do not delete Cabal's global
package cache or any PostgreSQL data as a recovery step.


## Interfaces and Dependencies

No new Keiro function or data type is introduced. The existing public functions
in `keiro-pgmq/src/Keiro/PGMQ/Job.hs` and
`keiro-pgmq/src/Keiro/PGMQ/Metrics.hs` keep their signatures. In particular:

```haskell
queueProvisionConfigs :: QueueProvision -> Job p -> [Pgmq.Config.Types.QueueConfig]

jobQueueMetrics :: Pgmq :> es => Job p -> Eff es QueueMetrics
jobDlqMetrics :: Pgmq :> es => Job p -> Eff es QueueMetrics
allJobMetrics :: Pgmq :> es => Eff es [QueueMetrics]
```

The selected `pgmq-config` 0.6.0.0 interface includes:

```haskell
data PartitionConfig = PartitionConfig
  { partitionInterval :: Text
  , retentionInterval :: Text
  , premake :: Maybe Int32
  }
```

Keiro always constructs that third field as `Nothing` in this plan. The selected
`pgmq-hasql`/`pgmq-effectful` 0.6.0.0 interface includes the existing seven
metrics fields plus:

```haskell
defaultPartitionLength :: Maybe Int64
```

`Keiro.PGMQ.Metrics` continues to re-export `QueueMetrics(..)` without wrapping
or normalizing it. The compatible
`mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter` 0.15.0.0
release retains the adapter API used by `Keiro.PGMQ.Job` while declaring PGMQ
0.6 bounds.

Final Cabal ranges are the five PGMQ packages at `>=0.6 && <0.7` and the
adapter at `^>=0.15.0.0`. Hackage is the authoritative registry for released
versions; GitHub upstream tags verify
release provenance; Mori supplies canonical identities, source locations, and
documentation. The project must not acquire a local path override, a source pin,
or an `allow-newer` exception.


Revision note (2026-09-14): Recorded the failed implementation-time release
gate, split the first Progress item into completed PGMQ-family verification and
the outstanding adapter release, and corrected the plan's earlier claim that the
PGMQ 0.6 adapter bounds were already present upstream. Authoritative GitHub
`HEAD` and Hackage still carry PGMQ 0.5 bounds; only the Mori-located local
checkout contains compatibility commit `2b67a65d`.


Revision note (2026-09-14): Verified the newly published
`shibuya-pgmq-adapter` 0.15.0.0 package and matching `v0.15.0.0` tag, marked the
release gate complete, replaced provisional adapter-version language with the
released version and commits, and cleared the stopped outcome. The 0.14.0.0 to
0.15.0.0 tagged diff contains no Haskell source changes, so the plan requires no
additional Keiro production-code compatibility update beyond its existing
Milestone 2 scope.


Revision note (2026-09-14): Completed Milestone 2 by raising the adapter bounds,
reconciling direct PGMQ metadata, documenting the released source-visible
behavior, and adding regression assertions. Recorded the successful refreshed
solver, metadata/document checks, and 58-example focused-suite evidence, plus
the non-fatal root-document warning emitted while adding the accepted DOC-25
bundle log entry.
